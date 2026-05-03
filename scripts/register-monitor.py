#!/usr/bin/env python3
"""
register-monitor.py — register a freshly-built FS box in bbl-monitor's
monitor_hosts table so it appears in https://monitor.rpt.bblapp.io/servers
and is candidate for diagnostic sampling.

Idempotent: if a row with this hostname already exists, sets enabled=True
and updates cpu_count/display_name/role. Safe to re-run after re-provisions.

The --role value (prod | beta | infra) determines which tab on /load the
box appears in — bbl-monitor's page_load() queries by role, so getting
this right at provision time is what makes new boxes auto-appear without
editing server.py.

Run on rpt. Reads BBL_MONITOR_DSN from env (bbl-call-tests/.env on rpt).
"""
from __future__ import annotations
import argparse
import os
import sys
import asyncpg
import asyncio


async def go(hostname: str, cpu_count: int, display_name: str | None,
             role: str | None) -> None:
    dsn = os.environ.get("BBL_MONITOR_DSN")
    if not dsn:
        sys.exit("BBL_MONITOR_DSN unset — source /opt/bbl-call-tests/.env first")

    if not display_name:
        display_name = hostname.split(".", 1)[0]

    conn = await asyncpg.connect(dsn)
    try:
        existing = await conn.fetchrow(
            "SELECT id, enabled FROM monitor_hosts WHERE hostname = $1", hostname)
        if existing:
            await conn.execute(
                "UPDATE monitor_hosts SET enabled = TRUE, cpu_count = $1, "
                "display_name = $2, role = COALESCE($3, role) "
                "WHERE id = $4",
                cpu_count, display_name, role, existing["id"])
            print(f"updated existing monitor_hosts row id={existing['id']} for {hostname} (role={role or 'unchanged'})")
        else:
            new_id = await conn.fetchval(
                "INSERT INTO monitor_hosts(hostname, display_name, cpu_count, role, enabled, created_at) "
                "VALUES($1, $2, $3, $4, TRUE, NOW()) RETURNING id",
                hostname, display_name, cpu_count, role)
            print(f"inserted monitor_hosts row id={new_id} for {hostname} (role={role or 'unset'})")
    finally:
        await conn.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    p.add_argument("--cpu-count", type=int, required=True)
    p.add_argument("--display-name", default=None)
    p.add_argument("--role", default=None,
                   help="prod | beta | infra. Drives which /load tab the host appears in.")
    a = p.parse_args()
    asyncio.run(go(a.hostname, a.cpu_count, a.display_name, a.role))
