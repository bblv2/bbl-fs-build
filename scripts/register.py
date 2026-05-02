#!/usr/bin/env python3
"""
register.py role=beta — wire up a freshly-built BETA FS box for end-to-end
test calls.

Steps:
  1. Resolve box IP from DNS (hostname → A record)
  2. Telnyx: create per-box IP-typed SIP connection, dest=<box_ip>:5060
  3. Pool: pick lowest unassigned pool-did-* from bbl_test_did_pool
  4. Telnyx: assign that DID to the new connection
  5. nodebblclean: INSERT bridges_freeswitchsetup row for the box
  6. nodebblclean: INSERT bridges_bridge (company=1 test123, defaults,
     welcome_option='D' to avoid missing-upload silence, moderator_PIN
     auto-generated)
  7. nodebblclean: INSERT bridges_did linking DID → new bridge
  8. Mark pool DID as assigned_to=<hostname>
  9. Print: dial <DID>, mod PIN <PIN>, plus IDs to persist into host.conf

Env required:
  BBL_MONITOR_DSN              postgres://... (for nodebblclean access via repo)
  TELNYX_API_KEY               Telnyx Mission Control API token
  TELNYX_OUTBOUND_PROFILE_ID   (optional) outbound voice profile to attach
"""
from __future__ import annotations
import argparse
import asyncio
import os
import random
import socket
import string
import sys
from typing import Any

import asyncpg
import requests


TELNYX = "https://api.telnyx.com/v2"
NODEBBLCLEAN_DSN_OVERRIDE = "/nodebblclean"
TEST_COMPANY_ID = 1   # test123 (diego@rgs.mx)


def telnyx(method: str, path: str, **kwargs: Any) -> dict:
    token = os.environ["TELNYX_API_KEY"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    r = requests.request(method, f"{TELNYX}{path}", headers=headers, timeout=20, **kwargs)
    if r.status_code >= 400:
        sys.exit(f"Telnyx {method} {path} → {r.status_code}: {r.text[:300]}")
    return r.json()


def resolve_ip(hostname: str) -> str:
    return socket.gethostbyname(hostname)


def gen_pin(length: int = 4) -> str:
    return "".join(random.choices(string.digits, k=length))


async def go(hostname: str) -> None:
    dsn = os.environ["BBL_MONITOR_DSN"].replace("/bbl2022", NODEBBLCLEAN_DSN_OVERRIDE)
    box_ip = resolve_ip(hostname)
    short = hostname.split(".", 1)[0]
    print(f"==> Registering {hostname} ({box_ip}) for beta testing")

    # 1. Telnyx: create per-box IP-typed SIP connection
    print("==> Telnyx: creating IP connection")
    conn_body = {
        "connection_name": f"bbl-fs-build-{short}",
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

    # 2. Pool: pick a DID
    print(f"==> Pool: selecting unassigned DID")
    pool_conn = await asyncpg.connect(dsn)
    try:
        async with pool_conn.transaction():
            row = await pool_conn.fetchrow(
                "SELECT pool_name, did FROM bbl_test_did_pool "
                "WHERE assigned_to IS NULL ORDER BY pool_name LIMIT 1 FOR UPDATE")
            if not row:
                sys.exit("Pool exhausted — all DIDs assigned. Add more or unregister stale boxes.")
            pool_name, did = row["pool_name"], row["did"]
            await pool_conn.execute(
                "UPDATE bbl_test_did_pool SET assigned_to = $1, assigned_at = NOW() "
                "WHERE pool_name = $2", hostname, pool_name)
        print(f"    selected {pool_name} = {did}")
    finally:
        await pool_conn.close()

    # 3. Telnyx: find that DID, point it at the new connection
    print(f"==> Telnyx: assigning {did} to connection")
    n_resp = telnyx("GET", f"/phone_numbers?filter[phone_number]={did}")
    if not n_resp.get("data"):
        sys.exit(f"DID {did} not found in Telnyx — check pool table matches Telnyx state")
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
                "jfb_url = $3, plivo_server_url = $4 WHERE id = $5",
                short, hostname, f"https://{hostname}",
                "http://lb-atl.bblapp.io:8084/", fs_id)
            print(f"==> nodebblclean: updated bridges_freeswitchsetup id={fs_id}")
        else:
            fs_id = await db.fetchval(
                "INSERT INTO bridges_freeswitchsetup "
                "(nickname, ip_address, dns_name, jfb_url, plivo_server_url, \"default\") "
                "VALUES ($1, $2, $3, $4, $5, FALSE) RETURNING id",
                short, box_ip, hostname, f"https://{hostname}",
                "http://lb-atl.bblapp.io:8084/")
            print(f"==> nodebblclean: inserted bridges_freeswitchsetup id={fs_id}")

        # bridges_bridge — full NOT-NULL coverage. welcome_option='U'
        # (uploaded) — even with no active welcome file (we add an inactive
        # placeholder row below), chb-atl falls back to default audio URLs
        # that DO play (default_welcome.mp3 + friendly_moderator_enjoy_music.mp3).
        # welcome_option='D' would skip the welcome+music IVR entirely
        # (verified empirically — caller hears only the PIN prompt).
        pin = gen_pin(4)
        bridge_id = await db.fetchval(
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
                deleted
            ) VALUES (
                $1, $2, $3,
                'U', '', 'man',
                'M', 'Please stand by.',
                TRUE, $4, 'R',
                FALSE, '',
                FALSE, 'beep', 'beep',
                TRUE,
                FALSE, 2,
                'normal', 'fs', 'com.twilio.music.soft-rock',
                FALSE, FALSE, FALSE,
                FALSE, FALSE,
                FALSE
            ) RETURNING id""",
            TEST_COMPANY_ID, fs_id, short, pin)
        print(f"==> nodebblclean: inserted bridges_bridge id={bridge_id} (PIN={pin})")

        # Inactive welcome-file placeholder. chb-atl looks for a 'W' file
        # row to know it should fall back to default URLs (the inactive
        # rows mark "use default audio" for the IVR layer).
        await db.execute(
            """INSERT INTO bridges_bridgefile
               (bridge_id, file_type, file, active, "order", created)
               VALUES ($1, 'W', 'files/default/default_welcome.mp3', FALSE, 0, NOW())""",
            bridge_id)

        # bridges_did — DID → bridge ('primary' is a postgres reserved word, quote it)
        did_id = await db.fetchval(
            'INSERT INTO bridges_did '
            '(number, country_dial_code, country_iso_code, service_provider, '
            'route_to_id, "primary", billing_provider, deleted, delete_protection, '
            'toll_free, created) '
            "VALUES ($1, '1', 'US', 'fs', $2, TRUE, 'telnyx', FALSE, FALSE, FALSE, NOW()) "
            'RETURNING id',
            did, bridge_id)
        print(f"==> nodebblclean: inserted bridges_did id={did_id}")

    finally:
        await db.close()

    # 7. Print summary + machine-parseable lines for host.conf persistence
    print()
    print("─" * 60)
    print("✓ Beta box registered. Test ready.")
    print(f"  Dial:        {did}")
    print(f"  Mod PIN:     {pin}")
    print(f"  Connection:  {connection_id}")
    print(f"  FS setup id: {fs_id}")
    print(f"  Bridge id:   {bridge_id}")
    print(f"  Pool slot:   {pool_name}")
    print()
    print("# Append to /etc/bbl-fs-host.conf (operator side):")
    print(f"BBL_TELNYX_CONNECTION_ID={connection_id}")
    print(f"BBL_TEST_DID={did}")
    print(f"BBL_TEST_PIN={pin}")
    print(f"BBL_TEST_BRIDGE_ID={bridge_id}")
    print(f"BBL_TEST_FS_SETUP_ID={fs_id}")
    print(f"BBL_TEST_DID_POOL_NAME={pool_name}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    asyncio.run(go(p.parse_args().hostname))
