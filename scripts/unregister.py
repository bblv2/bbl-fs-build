#!/usr/bin/env python3
"""
unregister.py — reverse register.py for a beta FS box.

Reads IDs from the operator's host.conf to know what to remove (since
some IDs aren't derivable from hostname alone).

Steps (best-effort, continues on individual failures):
  1. nodebblclean: DELETE bridges_did row
  2. nodebblclean: soft-delete bridges_bridge (deleted=TRUE, date_deleted=NOW)
  3. nodebblclean: DELETE bridges_freeswitchsetup row
  4. Telnyx: unassign DID (set voice.connection_id = null) → DID returns to pool semantically
  5. Telnyx: DELETE the per-box IP connection
  6. Pool: clear assigned_to / assigned_at on the pool row
"""
from __future__ import annotations
import argparse
import asyncio
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import asyncpg
import requests


TELNYX = "https://api.telnyx.com/v2"
NODEBBLCLEAN_DSN_OVERRIDE = "/nodebblclean"


def telnyx(method: str, path: str, **kwargs) -> dict | None:
    token = os.environ["TELNYX_API_KEY"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    r = requests.request(method, f"{TELNYX}{path}", headers=headers, timeout=20, **kwargs)
    if r.status_code == 404:
        print(f"  Telnyx {method} {path} → 404 (already gone)")
        return None
    if r.status_code >= 400:
        print(f"  WARN: Telnyx {method} {path} → {r.status_code}: {r.text[:200]}", file=sys.stderr)
        return None
    return r.json() if r.text else None


def parse_host_conf(path: Path) -> dict:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _close_lbb_ufw(ip: str, hostname: str) -> None:
    """Remove the lbb-atl ufw rule provision.sh added for this beta FS box.
    Best-effort: missing rule (already removed, never added) isn't fatal —
    print and continue. Unregister is intentionally tolerant of partial state.
    """
    if not ip or ip in ("0.0.0.0", "127.0.0.1"):
        return
    import subprocess
    lbb_host = os.environ.get("BBL_LBB_HOST", "lbb-atl.bblapp.io")
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=accept-new",
           lbb_host,
           # `ufw delete allow from X to any port Y proto tcp` exits 0 when
           # the rule existed (any comment) and was removed; non-zero on no
           # match. Either is fine — we just want the box's IP off the list.
           f"ufw delete allow from {ip} to any port 8085 proto tcp"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        first = ((r.stdout or r.stderr or "").splitlines() or [""])[0].strip()
        if r.returncode == 0:
            print(f"  lbb-atl ufw removed allow from {ip}: {first}")
        else:
            print(f"  lbb-atl ufw delete from {ip} → rc={r.returncode}: {first}")
    except Exception as e:
        print(f"  lbb-atl ufw delete attempt raised: {e} (continuing)")


async def go(hostname: str, host_conf_path: str) -> None:
    dsn = os.environ["BBL_MONITOR_DSN"].replace("/bbl2022", NODEBBLCLEAN_DSN_OVERRIDE)
    conf = parse_host_conf(Path(host_conf_path))
    print(f"==> Unregistering {hostname}")

    primary_did = conf.get("BBL_TEST_DID")
    primary_bridge_id = conf.get("BBL_TEST_BRIDGE_ID")
    primary_pool_name = conf.get("BBL_TEST_DID_POOL_NAME")
    adjacent_did = conf.get("BBL_TEST_ADJ_DID")
    adjacent_bridge_id = conf.get("BBL_TEST_ADJ_BRIDGE_ID")
    adjacent_pool_name = conf.get("BBL_TEST_DID_POOL_NAME_ADJ")
    fs_setup_id = conf.get("BBL_TEST_FS_SETUP_ID")
    connection_id = conf.get("BBL_TELNYX_CONNECTION_ID")

    # Pairs of (label, did, bridge_id, pool_name) — adjacent fields are
    # missing on boxes registered before the dual-DID model landed; the
    # filter below skips them gracefully.
    legs = [
        ("primary",  primary_did,  primary_bridge_id,  primary_pool_name),
        ("adjacent", adjacent_did, adjacent_bridge_id, adjacent_pool_name),
    ]

    fs_ip_for_ufw_cleanup = None  # populated below if fs_setup row found
    db = await asyncpg.connect(dsn)
    try:
        for label, did, b_id, _pool in legs:
            if did:
                n = await db.execute("DELETE FROM bridges_did WHERE number = $1", did)
                print(f"  bridges_did ({label}) delete: {n}")
            if b_id:
                # Soft-delete: bridges_conferencefreeswitch / bridges_conferencecall
                # / bridges_cdr / bridges_recording etc. all FK back to
                # bridges_bridge once any call has been placed against it.
                # Hard-delete fails on the FK web. Also NULL the freeswitch_setup_id
                # so the fs_setup row can be neutralized below.
                n = await db.execute(
                    "UPDATE bridges_bridge SET deleted = TRUE, date_deleted = NOW(), "
                    "freeswitch_setup_id = NULL WHERE id = $1",
                    int(b_id))
                print(f"  bridges_bridge ({label}) soft-delete + FK null: {n}")
        if fs_setup_id:
            # Capture the IP BEFORE neutralizing — needed to remove the
            # matching lbb-atl ufw allow that provision.sh added.
            row = await db.fetchrow(
                "SELECT ip_address FROM bridges_freeswitchsetup WHERE id = $1",
                int(fs_setup_id))
            if row and row["ip_address"]:
                fs_ip_for_ufw_cleanup = row["ip_address"]

            # Don't DELETE — bridges_conferencefreeswitch FKs to fs_setup too,
            # blocking any delete on rows that ever hosted a conference.
            # Instead, NEUTRALIZE: rename + zero the IP so the row is preserved
            # for FK integrity but won't match any future routing lookup
            # (Plivo/lb-atl find FS host by ip_address, never by id).
            short = hostname.split(".", 1)[0][:8]   # nickname is varchar(15)
            new_nick = f"del-{short}"[:15]
            n = await db.execute(
                "UPDATE bridges_freeswitchsetup SET nickname = $1, ip_address = $2, "
                "dns_name = $3, jfb_url = $4 WHERE id = $5",
                new_nick, "0.0.0.0", "", "", int(fs_setup_id))
            print(f"  bridges_freeswitchsetup neutralize: {n}")

        # Pool release — clear assignments regardless of whether host.conf
        # had pool_name(s). The hostname-based fallback catches both
        # primary + adjacent rows even if the per-host conf lost track.
        any_pool = primary_pool_name or adjacent_pool_name
        if any_pool:
            for label, name in (("primary", primary_pool_name),
                                ("adjacent", adjacent_pool_name)):
                if name:
                    n = await db.execute(
                        "UPDATE bbl_test_did_pool "
                        "SET assigned_to = NULL, assigned_at = NULL, role = NULL "
                        "WHERE pool_name = $1", name)
                    print(f"  pool release {label} {name}: {n}")
        # Always run the hostname sweep too — covers boxes registered
        # before the per-host conf knew about adjacent slots.
        n = await db.execute(
            "UPDATE bbl_test_did_pool "
            "SET assigned_to = NULL, assigned_at = NULL, role = NULL "
            "WHERE assigned_to = $1", hostname)
        print(f"  pool sweep by hostname: {n}")
    finally:
        await db.close()

    # Telnyx side
    for label, did, _b_id, _pool in legs:
        if not did:
            continue
        n_resp = telnyx("GET", f"/phone_numbers?filter[phone_number]={did}")
        if n_resp and n_resp.get("data"):
            number_id = n_resp["data"][0]["id"]
            print(f"  Telnyx unassign {did} ({label})")
            telnyx("PATCH", f"/phone_numbers/{number_id}/voice",
                   json={"connection_id": None})
    if connection_id:
        print(f"  Telnyx delete connection {connection_id}")
        telnyx("DELETE", f"/ip_connections/{connection_id}")

    # lbb-atl ufw cleanup — provision.sh added an allow for this box's IP
    # on port 8085 (beta ESL outbound). Remove it now that the box is gone.
    _close_lbb_ufw(fs_ip_for_ufw_cleanup, hostname)

    print("==> Unregister complete")


def _auto_env() -> None:
    """If BBL_MONITOR_DSN / TELNYX_API_KEY aren't already set, source
    /opt/bbl-call-tests/.env (operator side). Same convention as
    teardown.sh — keeps unregister.py runnable with just --hostname.
    """
    if os.environ.get("BBL_MONITOR_DSN") and os.environ.get("TELNYX_API_KEY"):
        return
    env_path = Path(os.environ.get("BBL_OPERATOR_ENV", "/opt/bbl-call-tests/.env"))
    if not env_path.is_file():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _resolve_host_conf(hostname: str) -> str | None:
    """Find the operator-side per-host conf for `hostname`. Tries the
    canonical `/etc/bbl-fs-<short>.host.conf` path first (current
    convention), then falls back to globbing /etc/bbl-fs-*.host.conf
    and matching by `BBL_DOMAIN=<hostname>` — the only field guaranteed
    to be present and unambiguous, regardless of which prefix style
    the file was named with (fs-test-1/2/3 used a single-prefix
    convention; fs-test-9 onward uses the doubled prefix).
    """
    import glob
    short = hostname.split(".", 1)[0]
    # Fast path: canonical naming.
    for candidate in (f"/etc/bbl-fs-{short}.host.conf",
                      f"/etc/bbl-fs-{hostname}.host.conf"):
        if Path(candidate).is_file():
            return candidate
    # Slow path: scan all per-host confs for matching BBL_DOMAIN.
    # Excludes /etc/bbl-fs.host.conf (shared secrets, no BBL_DOMAIN).
    for path in glob.glob("/etc/bbl-fs-*.host.conf"):
        try:
            conf = parse_host_conf(Path(path))
        except Exception:
            continue
        if conf.get("BBL_DOMAIN") == hostname:
            return path
    return None


if __name__ == "__main__":
    p = argparse.ArgumentParser(
        description="Release a beta FS box's DIDs/bridges and tear down "
                    "its Telnyx connection. Run teardown.sh instead if you "
                    "also want to delete the Linode + DNS record.")
    p.add_argument("--hostname", required=True,
                   help="Short hostname (e.g. fs-test-3) or FQDN. Short "
                        "hostnames auto-append .bblapp.io.")
    p.add_argument("--host-conf",
                   help="Path to operator-side host.conf with persisted "
                        "register IDs. Auto-derived from --hostname if "
                        "omitted.")
    a = p.parse_args()

    _auto_env()
    if not os.environ.get("BBL_MONITOR_DSN"):
        sys.exit("BBL_MONITOR_DSN is not set and could not be sourced from "
                 "/opt/bbl-call-tests/.env — set it explicitly or export "
                 "BBL_OPERATOR_ENV=<path>")

    fqdn = a.hostname if "." in a.hostname else f"{a.hostname}.bblapp.io"
    host_conf = a.host_conf or _resolve_host_conf(fqdn)
    if not host_conf:
        sys.exit(f"could not auto-find host.conf for {fqdn}; "
                 f"pass --host-conf <path> explicitly")

    asyncio.run(go(fqdn, host_conf))
