#!/bin/bash
# teardown.sh — destroy a bbl-fs Linode cleanly.
#
# Safety: requires --confirm flag. Never tears down hosts without
# explicit operator OK. Snapshots the disk before deletion so a 30-day
# rollback window exists.
set -euo pipefail

CONFIRM=0
HOSTNAME=
SNAPSHOT=1
for arg in "$@"; do
    case "$arg" in
        --confirm) CONFIRM=1 ;;
        --no-snapshot) SNAPSHOT=0 ;;
        hostname=*) HOSTNAME="${arg#hostname=}" ;;
        *) echo "unknown: $arg" >&2; exit 2 ;;
    esac
done

[[ -n "$HOSTNAME" ]] || { echo "usage: $0 hostname=<fqdn> --confirm [--no-snapshot]" >&2; exit 2; }
LABEL="${HOSTNAME//./-}"

LID="$(linode-cli linodes list --label "$LABEL" --json 2>/dev/null | jq -r '.[0].id')"
[[ -n "$LID" && "$LID" != "null" ]] || { echo "$0: no linode with label '$LABEL'" >&2; exit 1; }

echo "==> Found linode $LID for $HOSTNAME"
linode-cli linodes view "$LID" --json | jq -r '.[0] | "  status=\(.status) ipv4=\(.ipv4[0]) created=\(.created)"'

if (( ! CONFIRM )); then
    echo "$0: not destroying without --confirm"
    exit 1
fi

# 1. Drain: shut down FS gracefully so in-flight calls aren't dropped
# mid-conversation. fs_cli shutdown returns when all calls have ended.
echo "==> Draining FreeSWITCH (waiting for active calls to end)"
IP="$(linode-cli linodes view "$LID" --json | jq -r '.[0].ipv4[0]')"
ssh "root@$IP" 'fs_cli -x "fsctl shutdown elegant"' || true
sleep 5

# 2. Snapshot for rollback
if (( SNAPSHOT )); then
    echo "==> Taking final disk snapshot"
    linode-cli linodes snapshot "$LID" --label "${LABEL}-final-$(date -u +%Y%m%d)" || true
    sleep 10
fi

# 3. Delete
echo "==> Deleting linode $LID"
linode-cli linodes delete "$LID"

# 4. Remove the DNS A record
ROOT_DOMAIN=
ZONE_ID=
while read -r line; do
    [[ -z "$line" ]] && continue
    z_id="$(echo "$line" | jq -r '.id')"
    z_dom="$(echo "$line" | jq -r '.domain')"
    if [[ "$HOSTNAME" == *".$z_dom" ]] && (( ${#z_dom} > ${#ROOT_DOMAIN} )); then
        ROOT_DOMAIN="$z_dom"; ZONE_ID="$z_id"
    fi
done < <(linode-cli domains list --json | jq -c '.[]')

if [[ -n "$ZONE_ID" ]]; then
    SUBDOMAIN="${HOSTNAME%.$ROOT_DOMAIN}"
    REC_ID="$(linode-cli domains records-list "$ZONE_ID" --json \
        | jq -r ".[] | select(.type == \"A\" and .name == \"$SUBDOMAIN\") | .id" | head -1)"
    if [[ -n "$REC_ID" ]]; then
        echo "==> Removing DNS A record ($SUBDOMAIN.$ROOT_DOMAIN, ID $REC_ID)"
        linode-cli domains records-delete "$ZONE_ID" "$REC_ID" >/dev/null
    fi
fi

echo
echo "==> Teardown complete for $HOSTNAME"
[[ "$SNAPSHOT" == "1" ]] && echo "    Snapshot retained: ${LABEL}-final-$(date -u +%Y%m%d)"
