#!/usr/bin/env python3
"""
register-monitor.py — register a freshly-built FS box in bbl-monitor's
monitor_hosts table so it appears in https://monitor.rpt.bblapp.io/servers
and is candidate for diagnostic sampling.

Idempotent: if a row with this hostname already exists, sets enabled=True
and updates cpu_count/display_name. Safe to re-run after re-provisions.

Run on rpt. Reads BBL_MONITOR_DSN from env (bbl-call-tests/.env on rpt).
"""
from __future__ import annotations
import argparse
import os
import sys
import asyncpg
import asyncio


async def go(hostname: str, cpu_count: int, display_name: str | None) -> None:
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
                "UPDATE monitor_hosts SET enabled = TRUE, cpu_count = $1, display_name = $2 "
                "WHERE id = $3",
                cpu_count, display_name, existing["id"])
            print(f"updated existing monitor_hosts row id={existing['id']} for {hostname}")
        else:
            new_id = await conn.fetchval(
                "INSERT INTO monitor_hosts(hostname, display_name, cpu_count, enabled, created_at) "
                "VALUES($1, $2, $3, TRUE, NOW()) RETURNING id",
                hostname, display_name, cpu_count)
            print(f"inserted monitor_hosts row id={new_id} for {hostname}")
    finally:
        await conn.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    p.add_argument("--cpu-count", type=int, required=True)
    p.add_argument("--display-name", default=None)
    a = p.parse_args()
    asyncio.run(go(a.hostname, a.cpu_count, a.display_name))
