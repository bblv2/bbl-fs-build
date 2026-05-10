#!/usr/bin/env python3
"""
register.py role=beta — wire up a freshly-built BETA FS box for end-to-end
test calls.

Allocates TWO DIDs from bbl_test_did_pool:
  - role='primary'   for the main test bridge (load callers + moderator)
  - role='adjacent'  for the cross-bridge audio-quality check in
                      load_with_quality (a second mod_conference on the
                      same FS host so we can verify a load on bridge A
                      doesn't degrade audio on adjacent bridge B)

Both DIDs are pointed at the same Telnyx IP connection AND attached to
bridges with the same freeswitch_setup_id, so both calls land on the
new FS host.

Steps:
  1. Resolve box IP from DNS (hostname → A record)
  2. Telnyx: create per-box IP-typed SIP connection, dest=<box_ip>:5060
  3. Pool: atomically pick TWO lowest unassigned pool-did-* slots,
     mark roles primary + adjacent
  4. Telnyx: PATCH each DID → connection_id
  5. nodebblclean: INSERT bridges_freeswitchsetup row for the box (once)
  6. nodebblclean: INSERT bridges_bridge × 2 (titles `<short>` and
     `<short>-adj`), both sharing freeswitch_setup_id
  7. nodebblclean: INSERT bridges_bridgefile placeholders × 2
  8. nodebblclean: INSERT bridges_did × 2 linking each DID → its bridge
  9. Print: dial <DID>, mod PIN <PIN>, plus IDs to persist into host.conf

Env required:
  BBL_BETA_DSN                 postgres://...db-atl/bbl_beta — destination for
                               bbl_test_did_pool, bridges_freeswitchsetup,
                               bridges_bridge, bridges_did writes (post
                               2026-05-09 PG migration; pre-migration this
                               was derived from BBL_MONITOR_DSN by swapping
                               /bbl2022 → /nodebblclean).
  TELNYX_API_KEY               Telnyx Mission Control API token
  TELNYX_OUTBOUND_PROFILE_ID   (optional) outbound voice profile to attach

Pool capacity: needs 2 unassigned rows in bbl_test_did_pool. Mint more
Telnyx numbers in the same range when this gets tight.
"""
from __future__ import annotations
import argparse
import asyncio
import os
import socket
import sys
from typing import Any

import asyncpg
import requests


TELNYX = "https://api.telnyx.com/v2"
TEST_COMPANY_ID = 1   # test123 (diego@rgs.mx)
DEFAULT_PROMPT_SET_ID = 3   # 'drew' — has full prompt set including moderator_welcome


def telnyx(method: str, path: str, **kwargs: Any) -> dict:
    token = os.environ["TELNYX_API_KEY"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    r = requests.request(method, f"{TELNYX}{path}", headers=headers, timeout=20, **kwargs)
    if r.status_code >= 400:
        sys.exit(f"Telnyx {method} {path} → {r.status_code}: {r.text[:300]}")
    return r.json()


def resolve_ip(hostname: str) -> str:
    return socket.gethostbyname(hostname)


async def _insert_bridge(db, fs_id: int, title: str) -> int:
    """Insert a bridges_bridge row and return its id.

    Settings match the `base` fixture profile in bbl-call-tests's
    fixtures.yaml (moderated=FALSE, no PIN, beep on join/leave, no
    name announcement). load_with_quality and most other regression
    scenarios use profile_name='base' and would otherwise hit
    fixture_matches_profile drift on a freshly-registered box.

    For scenarios that need other profiles (mod_pin, lecture, etc.),
    PATCH the bridge to match before running, or stand up additional
    bridges per profile.
    """
    return await db.fetchval(
        """INSERT INTO bridges_bridge (
            company_id, freeswitch_setup_id, title,
            welcome_option, welcome_text, robo_voice,
            hold_option, hold_text,
            moderated, "moderator_PIN", roundup_option,
            attended, "attendee_PIN",
            recording, on_participant_join, on_participant_leave,
            beep_on_participant_join,
            announce_names, announce_names_settings,
            initial_mute_state, service_provider, music_choice,
            seminar, playback_only_line, disable_unmuting_star_six,
            enable_multiple_moderators, prompt_mod_for_billing_code,
            deleted, prompt_set_id
        ) VALUES (
            $1, $2, $3,
            'U', '', 'man',
            'M', 'Please stand by.',
            FALSE, '', 'R',
            FALSE, '',
            FALSE, 'beep', 'beep',
            TRUE,
            FALSE, 2,
            'normal', 'fs', 'com.twilio.music.soft-rock',
            FALSE, FALSE, FALSE,
            FALSE, FALSE,
            FALSE, $4
        ) RETURNING id""",
        TEST_COMPANY_ID, fs_id, title, DEFAULT_PROMPT_SET_ID)


async def _insert_bridges_did(db, did: str, bridge_id: int) -> int:
    """Insert a bridges_did row routing `did` → `bridge_id`. Returns the
    new row id. ('primary' is a postgres reserved word; quote it.)"""
    return await db.fetchval(
        'INSERT INTO bridges_did '
        '(number, country_dial_code, country_iso_code, service_provider, '
        'route_to_id, "primary", billing_provider, deleted, delete_protection, '
        'toll_free, created) '
        "VALUES ($1, '1', 'US', 'fs', $2, TRUE, 'telnyx', FALSE, FALSE, FALSE, NOW()) "
        'RETURNING id',
        did, bridge_id)


async def go(hostname: str) -> None:
    dsn = os.environ.get("BBL_BETA_DSN")
    if not dsn:
        sys.exit("BBL_BETA_DSN unset — source /opt/bbl-call-tests/.env first")
    box_ip = resolve_ip(hostname)
    short = hostname.split(".", 1)[0]
    print(f"==> Registering {hostname} ({box_ip}) for beta testing")

    # 1. Telnyx: create per-box IP-typed SIP connection (idempotent —
    #    reuse existing if a connection with this name already exists,
    #    so re-running register.py for the same hostname doesn't orphan
    #    a duplicate connection in Telnyx).
    conn_name = f"bbl-fs-build-{short}"
    # Client-side exact-name filter — Telnyx's filter[connection_name] does
    # prefix/substring matching, so a search for "bbl-fs-build-fsb-atl11"
    # will match an existing "bbl-fs-build-fsb-atl1". Don't trust the API
    # filter alone; require connection_name == conn_name exactly.
    existing = telnyx("GET", f"/connections?filter[connection_name]={conn_name}")
    exact_matches = [c for c in (existing.get("data") or [])
                     if c.get("connection_name") == conn_name]
    if len(exact_matches) > 1:
        sys.exit(f"Telnyx returned multiple connections named exactly "
                 f"'{conn_name}' — operator must reconcile manually")
    if exact_matches:
        connection_id = exact_matches[0]["id"]
        print(f"==> Telnyx: reusing existing connection {connection_id} ({conn_name})")
        # Verify the box's IP is attached; attach it if not.
        ips_resp = telnyx("GET", f"/ips?filter[connection_id]={connection_id}")
        attached = {ip.get("ip_address") for ip in (ips_resp.get("data") or [])}
        if box_ip in attached:
            print(f"    IP {box_ip}:5060 already attached")
        else:
            print(f"    attaching {box_ip}:5060 to existing connection")
            telnyx("POST", "/ips", json={
                "connection_id": connection_id,
                "ip_address": box_ip,
                "port": 5060,
            })
    else:
        print("==> Telnyx: creating IP connection")
        conn_body = {
            "connection_name": conn_name,
            "active": True,
            "anchorsite_override": "Latency",
            "default_on_hold_comfort_noise_enabled": True,
            "dtmf_type": "RFC 2833",
            "encode_contact_header_enabled": False,
            "onnet_t38_passthrough_enabled": False,
            "inbound": {
                "ani_number_format": "+E.164",
                "dnis_number_format": "+e164",
                "sip_subdomain_receive_settings": "from_anyone",
            },
        }
        conn_resp = telnyx("POST", "/ip_connections", json=conn_body)
        connection_id = conn_resp["data"]["id"]
        print(f"    connection_id={connection_id}")

        # Attach the IP destination (FS host:5060)
        print("==> Telnyx: attaching IP destination")
        ip_body = {"connection_id": connection_id, "ip_address": box_ip, "port": 5060}
        telnyx("POST", "/ips", json=ip_body)

    # 2. Pool: atomically allocate primary + adjacent DIDs.
    # Both succeed or both roll back — partial assignment would leave
    # an orphan pool row that humans would have to clean up.
    print(f"==> Pool: allocating primary + adjacent DIDs")
    pool_conn = await asyncpg.connect(dsn)
    try:
        async with pool_conn.transaction():
            primary_row = await pool_conn.fetchrow(
                "SELECT pool_name, did FROM bbl_test_did_pool "
                "WHERE assigned_to IS NULL ORDER BY pool_name LIMIT 1 FOR UPDATE")
            if not primary_row:
                sys.exit("Pool exhausted — no unassigned DIDs for primary. "
                         "Mint more Telnyx DIDs or unregister stale boxes.")
            primary_pool_name = primary_row["pool_name"]
            primary_did = primary_row["did"]
            await pool_conn.execute(
                "UPDATE bbl_test_did_pool "
                "SET assigned_to = $1, assigned_at = NOW(), role = 'primary' "
                "WHERE pool_name = $2", hostname, primary_pool_name)

            adjacent_row = await pool_conn.fetchrow(
                "SELECT pool_name, did FROM bbl_test_did_pool "
                "WHERE assigned_to IS NULL ORDER BY pool_name LIMIT 1 FOR UPDATE")
            if not adjacent_row:
                sys.exit("Pool exhausted — only one unassigned DID, need two "
                         "(primary + adjacent). Mint more Telnyx DIDs.")
            adjacent_pool_name = adjacent_row["pool_name"]
            adjacent_did = adjacent_row["did"]
            await pool_conn.execute(
                "UPDATE bbl_test_did_pool "
                "SET assigned_to = $1, assigned_at = NOW(), role = 'adjacent' "
                "WHERE pool_name = $2", hostname, adjacent_pool_name)
        print(f"    primary:  {primary_pool_name} = {primary_did}")
        print(f"    adjacent: {adjacent_pool_name} = {adjacent_did}")
    finally:
        await pool_conn.close()

    # 3. Telnyx: point each DID at the new connection. Failure here
    # leaves the pool rows allocated; operator would need to release
    # them via unregister.py if the build aborts.
    for label, did_value in (("primary", primary_did), ("adjacent", adjacent_did)):
        print(f"==> Telnyx: assigning {did_value} ({label}) to connection")
        n_resp = telnyx("GET", f"/phone_numbers?filter[phone_number]={did_value}")
        if not n_resp.get("data"):
            sys.exit(f"DID {did_value} ({label}) not found in Telnyx — "
                     f"check pool table matches Telnyx state")
        number_id = n_resp["data"][0]["id"]
        telnyx("PATCH", f"/phone_numbers/{number_id}/voice",
               json={"connection_id": connection_id})

    # 4-6. nodebblclean: freeswitch_setup + bridge + did
    db = await asyncpg.connect(dsn)
    try:
        # bridges_freeswitchsetup (idempotent — UPDATE if exists)
        existing_fs = await db.fetchrow(
            "SELECT id FROM bridges_freeswitchsetup WHERE ip_address = $1", box_ip)
        if existing_fs:
            fs_id = existing_fs["id"]
            await db.execute(
                "UPDATE bridges_freeswitchsetup SET nickname = $1, dns_name = $2, "
                "jfb_url = $3, plivo_server_url = $4, django_url = $5 WHERE id = $6",
                short, hostname, f"https://{hostname}",
                "http://lbb-atl.bblapp.io:8084/",      # beta LB (was lb-atl, prod typo)
                "https://beta.bblapp.io",              # per-FS callback routing
                fs_id)
            print(f"==> nodebblclean: updated bridges_freeswitchsetup id={fs_id}")
        else:
            fs_id = await db.fetchval(
                "INSERT INTO bridges_freeswitchsetup "
                "(nickname, ip_address, dns_name, jfb_url, plivo_server_url, django_url, \"default\") "
                "VALUES ($1, $2, $3, $4, $5, $6, false) RETURNING id",
                short, box_ip, hostname, f"https://{hostname}",
                "http://lbb-atl.bblapp.io:8084/",      # beta LB
                "https://beta.bblapp.io")              # per-FS callback routing
            print(f"==> nodebblclean: inserted bridges_freeswitchsetup id={fs_id}")

        # bridges_bridge × 2 — same freeswitch_setup_id so both bridges
        # land on this FS host. Title `<short>-adj` distinguishes the
        # adjacent bridge in the Django admin / monitor UIs.
        # welcome_option='U' (uploaded) — even with no active welcome file
        # (we add an inactive placeholder row below), chb-atl falls back
        # to default audio URLs that DO play. welcome_option='D' would
        # skip the welcome+music IVR entirely (verified empirically —
        # caller hears only the PIN prompt).
        primary_bridge_id = await _insert_bridge(db, fs_id, short)
        print(f"==> nodebblclean: inserted bridges_bridge id={primary_bridge_id} "
              f"(primary, base profile — no PIN, no moderation)")
        adjacent_bridge_id = await _insert_bridge(db, fs_id, f"{short}-adj")
        print(f"==> nodebblclean: inserted bridges_bridge id={adjacent_bridge_id} "
              f"(adjacent, base profile — no PIN, no moderation)")

        # Inactive welcome-file placeholder for both bridges. chb-atl
        # looks for a 'W' file row to know it should fall back to default
        # URLs (inactive rows mark "use default audio" for the IVR layer).
        for b_id in (primary_bridge_id, adjacent_bridge_id):
            await db.execute(
                """INSERT INTO bridges_bridgefile
                   (bridge_id, file_type, file, active, "order", created)
                   VALUES ($1, 'W', 'files/default/default_welcome.mp3', FALSE, 0, NOW())""",
                b_id)

        # bridges_did × 2 — each DID → its own bridge.
        # ('primary' is a postgres reserved word in the column name; quote it.)
        primary_did_row_id = await _insert_bridges_did(db, primary_did, primary_bridge_id)
        print(f"==> nodebblclean: inserted bridges_did id={primary_did_row_id} (primary)")
        adjacent_did_row_id = await _insert_bridges_did(db, adjacent_did, adjacent_bridge_id)
        print(f"==> nodebblclean: inserted bridges_did id={adjacent_did_row_id} (adjacent)")

    finally:
        await db.close()

    # 7. Print summary + machine-parseable lines for host.conf persistence
    print()
    print("─" * 60)
    print("✓ Beta box registered. Test ready.")
    print(f"  Dial (primary):  {primary_did}")
    print(f"  Adjacent DID:    {adjacent_did}   (load_with_quality cross-bridge)")
    print(f"  Bridge profile:  base (no PIN, no moderation)")
    print(f"  Connection:      {connection_id}")
    print(f"  FS setup id:     {fs_id}")
    print(f"  Primary bridge:  id={primary_bridge_id}  pool={primary_pool_name}")
    print(f"  Adjacent bridge: id={adjacent_bridge_id}  pool={adjacent_pool_name}")
    print()
    print("# Append to /etc/bbl-fs-host.conf (operator side):")
    print(f"BBL_TELNYX_CONNECTION_ID={connection_id}")
    print(f"BBL_TEST_DID={primary_did}")
    print(f"BBL_TEST_BRIDGE_ID={primary_bridge_id}")
    print(f"BBL_TEST_FS_SETUP_ID={fs_id}")
    print(f"BBL_TEST_DID_POOL_NAME={primary_pool_name}")
    print(f"BBL_TEST_ADJ_DID={adjacent_did}")
    print(f"BBL_TEST_ADJ_BRIDGE_ID={adjacent_bridge_id}")
    print(f"BBL_TEST_DID_POOL_NAME_ADJ={adjacent_pool_name}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    asyncio.run(go(p.parse_args().hostname))
