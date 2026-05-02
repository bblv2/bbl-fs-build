#!/usr/bin/env python3
"""
unregister-monitor.py — mark a torn-down FS box as disabled in bbl-monitor.

Sets enabled=FALSE rather than DELETE so historical metric rows that
reference the host_id remain queryable. If you ever want hard removal,
do it manually after auditing dependent data.
"""
from __future__ import annotations
import argparse
import asyncio
import os
import sys
import asyncpg


async def go(hostname: str) -> None:
    dsn = os.environ.get("BBL_MONITOR_DSN")
    if not dsn:
        sys.exit("BBL_MONITOR_DSN unset")
    conn = await asyncpg.connect(dsn)
    try:
        n = await conn.execute(
            "UPDATE monitor_hosts SET enabled = FALSE WHERE hostname = $1", hostname)
        print(f"monitor_hosts disable: {n} for {hostname}")
    finally:
        await conn.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--hostname", required=True)
    asyncio.run(go(p.parse_args().hostname))
