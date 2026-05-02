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


async def go(hostname: str, host_conf_path: str) -> None:
    dsn = os.environ["BBL_MONITOR_DSN"].replace("/bbl2022", NODEBBLCLEAN_DSN_OVERRIDE)
    conf = parse_host_conf(Path(host_conf_path))
    print(f"==> Unregistering {hostname}")

    test_did = conf.get("BBL_TEST_DID")
    bridge_id = conf.get("BBL_TEST_BRIDGE_ID")
    fs_setup_id = conf.get("BBL_TEST_FS_SETUP_ID")
    connection_id = conf.get("BBL_TELNYX_CONNECTION_ID")
    pool_name = conf.get("BBL_TEST_DID_POOL_NAME")

    db = await asyncpg.connect(dsn)
    try:
        if test_did:
            n = await db.execute("DELETE FROM bridges_did WHERE number = $1", test_did)
            print(f"  bridges_did delete: {n}")
        if bridge_id:
            n = await db.execute(
                "UPDATE bridges_bridge SET deleted = TRUE, date_deleted = $1 WHERE id = $2",
                datetime.now(timezone.utc), int(bridge_id))
            print(f"  bridges_bridge soft-delete: {n}")
        if fs_setup_id:
            n = await db.execute(
                "DELETE FROM bridges_freeswitchsetup WHERE id = $1", int(fs_setup_id))
            print(f"  bridges_freeswitchsetup delete: {n}")

        # Pool release — clear assignment regardless of whether host.conf had pool_name
        if pool_name:
            n = await db.execute(
                "UPDATE bbl_test_did_pool SET assigned_to = NULL, assigned_at = NULL "
                "WHERE pool_name = $1", pool_name)
            print(f"  pool release {pool_name}: {n}")
        else:
            # Fallback: clear by hostname
            n = await db.execute(
                "UPDATE bbl_test_did_pool SET assigned_to = NULL, assigned_at = NULL "
                "WHERE assigned_to = $1", hostname)
            print(f"  pool release by hostname: {n}")
    finally:
        await db.close()

    # Telnyx side
    if test_did:
        n_resp = telnyx("GET", f"/phone_numbers?filter[phone_number]={test_did}")
        if n_resp and n_resp.get("data"):
            number_id = n_resp["data"][0]["id"]
            print(f"  Telnyx unassign {test_did}")
            telnyx("PATCH", f"/phone_numbers/{number_id}/voice",
                   json={"connection_id": None})
    if connection_id:
        print(f"  Telnyx delete connection {connection_id}")
        telnyx("DELETE", f"/ip_connections/{connection_id}")

    print("==> Unregister complete")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    p.add_argument("--host-conf", required=True,
                   help="Path to operator-side host.conf with persisted register IDs")
    a = p.parse_args()
    asyncio.run(go(a.hostname, a.host_conf))
