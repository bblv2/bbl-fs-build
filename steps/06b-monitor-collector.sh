#!/bin/bash
# 06b-monitor-collector.sh — install bbl-monitor metrics collector.
#
# Box posts host metrics every 5 min to bbl-monitor's ingest endpoint
# and shows up at https://monitor.rpt.bblapp.io/servers within ~5 min
# of cron firing for the first time.
#
# Idempotent: re-run replaces the script and the cron file in place.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"
: "${BBL_MONITOR_TOKEN:=mcp-monitor-2026}"

echo "==> Installing /usr/local/bin/mcp-collector.sh"
install -m 0755 -o root -g root \
    "$BBL_BUILD_DIR/templates/mcp-collector.sh" \
    /usr/local/bin/mcp-collector.sh

echo "==> Installing /etc/cron.d/bbl-monitor-collector"
cat > /etc/cron.d/bbl-monitor-collector <<EOF
# bbl-monitor metrics collector — installed by bbl-fs-build step 06b.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root MONITOR_TOKEN=$BBL_MONITOR_TOKEN /usr/local/bin/mcp-collector.sh
EOF
chmod 0644 /etc/cron.d/bbl-monitor-collector

echo "==> Priming the collector (one synchronous post so the box appears immediately)"
if MONITOR_TOKEN="$BBL_MONITOR_TOKEN" /usr/local/bin/mcp-collector.sh; then
    echo "    OK — host should appear on monitor.rpt.bblapp.io/servers within ~1 min"
else
    rc=$?
    echo "WARN: priming run exited $rc; cron will retry every 5 min" >&2
fi

echo "==> 06b-monitor-collector.sh complete"
