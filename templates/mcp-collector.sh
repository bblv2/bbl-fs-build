#!/bin/bash
# MCP Server Metrics Collector — FreeSWITCH variant (includes calls_in_progress)
# Deploy to each monitored FS host, run every 5 min via cron:
# */5 * * * * MONITOR_TOKEN=mcp-monitor-2026 /usr/local/bin/mcp-collector.sh
#
# `calls_in_progress` is what bbl-monitor's /load page charts as the
# "Calls in Progress" line per host. Without it the line stays flat-NULL
# for the host even though the cron is firing every 5 min (cf. fs-test-11
# first build on 2026-05-03).

ENDPOINT="http://crawl.rgs.mx:8765/monitor/ingest"
MONITOR_TOKEN="${MONITOR_TOKEN:-REPLACE_ME}"

HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)

# CPU count
CPU_COUNT=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

# Load averages
read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

# Memory (MB)
MEM_LINE=$(free -m 2>/dev/null | awk '/^Mem:/{print $2,$3,$7}')
MEM_TOTAL=$(echo $MEM_LINE | awk '{print $1}')
MEM_USED=$(echo $MEM_LINE | awk '{print $2}')
MEM_FREE=$(echo $MEM_LINE | awk '{print $3}')
if [ -z "$MEM_TOTAL" ] || [ "$MEM_TOTAL" -eq 0 ] 2>/dev/null; then MEM_PCT="0"; else
  MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}")
fi

# Primary network interface
NET_IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
[ -z "$NET_IFACE" ] && NET_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)
[ -z "$NET_IFACE" ] && NET_IFACE="eth0"

NET_RX=0; NET_TX=0
if [ -f /proc/net/dev ]; then
  NET_LINE=$(awk -v iface="$NET_IFACE:" '$1==iface{print $2,$10}' /proc/net/dev)
  NET_RX=$(echo $NET_LINE | awk '{print $1}')
  NET_TX=$(echo $NET_LINE | awk '{print $2}')
  [ -z "$NET_RX" ] && NET_RX=0
  [ -z "$NET_TX" ] && NET_TX=0
fi

# Disk usage — build JSON array, skip tmpfs/devtmpfs/udev/loop
DISKS_JSON=$(df -BM 2>/dev/null | tail -n +2 | grep -v -E '^(tmpfs|devtmpfs|udev|/dev/loop)' | awk '
{
  gsub(/M/, "", $2); gsub(/M/, "", $3)
  pct = ($2 > 0) ? int($3/$2*100) : 0
  printf "{\"mount\":\"%s\",\"total_mb\":%s,\"used_mb\":%s,\"pct\":%d},", $6, $2, $3, pct
}' | sed 's/,$//')
DISKS_JSON="[$DISKS_JSON]"

# FreeSWITCH active call count via fs_cli. Counts CONFERENCE MEMBERS
# (BBL is conference-based; member count is the true 'live' number)
# rather than 'show calls count' which leaves zombie entries until FS
# restart. 'conference list count' returns one line per member; +OK
# lines are conference headers and skipped.
CALLS_IN_PROGRESS=0
if command -v fs_cli >/dev/null 2>&1; then
  OUT=$(fs_cli -x 'conference list count' 2>/dev/null)
  if ! echo "$OUT" | grep -q 'No active conferences'; then
    CALLS_IN_PROGRESS=$(echo "$OUT" | grep -cvE '^(\+OK|\s*$)')
  fi
fi

PAYLOAD=$(cat <<JSONEOF
{
  "hostname": "$HOSTNAME_VAL",
  "cpu_count": $CPU_COUNT,
  "load_1m": $LOAD1,
  "load_5m": $LOAD5,
  "load_15m": $LOAD15,
  "mem_total_mb": ${MEM_TOTAL:-0},
  "mem_used_mb": ${MEM_USED:-0},
  "mem_free_mb": ${MEM_FREE:-0},
  "mem_pct": ${MEM_PCT:-0},
  "net_iface": "$NET_IFACE",
  "net_rx_bytes": $NET_RX,
  "net_tx_bytes": $NET_TX,
  "disks": $DISKS_JSON,
  "calls_in_progress": $CALLS_IN_PROGRESS
}
JSONEOF
)

curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MONITOR_TOKEN" \
  -d "$PAYLOAD" \
  --max-time 10 \
  > /dev/null 2>&1
