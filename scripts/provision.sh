#!/bin/bash
# provision.sh — create a new FreeSWITCH Linode using bbl-fs-build.
#
# Usage:
#   scripts/provision.sh role=beta  size=small  hostname=fs-beta-1.bblapp.io
#   scripts/provision.sh role=prod  size=large  hostname=fs-atl-2.bblapp.io
#
# Prerequisites:
#   - linode-cli installed and authenticated (`linode-cli configure`)
#   - host.conf prepared with secrets (BBL_B2_KEY_ID, BBL_B2_APP_KEY,
#     BBL_SIGNALWIRE_TOKEN). Pass via --host-conf=/path/to/host.conf
#
# Workflow:
#   1. Resolve size → Linode SKU
#   2. Reserve a Floating IP (so we can re-provision without DNS dance)
#   3. linode-cli linodes create … --metadata.user_data=$(base64 bootstrap.sh + env)
#   4. Wait for cloud-init to finish; tail /var/log/bbl-fs-build.log
#   5. Print a summary including SSH command to attach
set -euo pipefail

# ── Parse args ───────────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]= [hostname]= [host-conf]= [region]=us-southeast )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done
for required in role size hostname host-conf; do
    [[ -n "${ARGS[$required]}" ]] || { echo "$0: $required is required" >&2; exit 2; }
done
[[ -r "${ARGS[host-conf]}" ]] || { echo "$0: cannot read ${ARGS[host-conf]}" >&2; exit 2; }

# ── Resolve size → SKU ───────────────────────────────────────────────
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIZES_FILE="$BUILD_DIR/conf/linode-sizes.conf"
SKU="$(awk -v size="${ARGS[size]}" '$1 == size {print $2}' "$SIZES_FILE")"
[[ -n "$SKU" ]] || { echo "$0: unknown size '${ARGS[size]}' — see $SIZES_FILE" >&2; exit 2; }

LABEL="${ARGS[hostname]//./-}"
ROOT_PASS="$(openssl rand -base64 24)"

echo "==> Provisioning ${ARGS[hostname]} as Linode $SKU in ${ARGS[region]}"

# ── DNS: find the Linode-managed zone for this hostname ─────────────
ROOT_DOMAIN=
ZONE_ID=
while read -r line; do
    [[ -z "$line" ]] && continue
    z_id="$(echo "$line" | jq -r '.id')"
    z_dom="$(echo "$line" | jq -r '.domain')"
    if [[ "${ARGS[hostname]}" == *".$z_dom" ]]; then
        # Take longest match (e.g., a.b.example.com prefers example.com over com)
        if (( ${#z_dom} > ${#ROOT_DOMAIN} )); then
            ROOT_DOMAIN="$z_dom"
            ZONE_ID="$z_id"
        fi
    fi
done < <(linode-cli domains list --json | jq -c '.[]')

if [[ -z "$ZONE_ID" ]]; then
    echo "$0: no Linode-managed zone matches '${ARGS[hostname]}' — add the zone in Linode DNS Manager first" >&2
    exit 1
fi
SUBDOMAIN="${ARGS[hostname]%.$ROOT_DOMAIN}"
echo "    DNS zone:    $ROOT_DOMAIN (ID $ZONE_ID), subdomain '$SUBDOMAIN'"

# ── Build user_data: bootstrap.sh + the operator's host.conf ─────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Construct cloud-init user_data combining:
#   - /etc/bbl-fs-host.conf  (operator-supplied host knobs + secrets)
#   - /etc/bbl-fs-bootstrap.env (build args for bootstrap.sh)
#   - bootstrap.sh runs as the cloud-init script
cat > "$TMPDIR/user_data.yaml" <<EOF
#cloud-config
write_files:
  - path: /etc/bbl-fs-host.conf
    permissions: '0600'
    owner: root:root
    content: |
$(sed 's/^/      /' "${ARGS[host-conf]}")
  - path: /etc/bbl-fs-bootstrap.env
    permissions: '0644'
    content: |
      BBL_ROLE=${ARGS[role]}
      BBL_SIZE=${ARGS[size]}
      BBL_HOSTNAME=${ARGS[hostname]}
runcmd:
  - bash -c 'curl -fsSL https://raw.githubusercontent.com/bblv2/bbl-fs-build/main/bootstrap.sh | bash >>/var/log/bbl-fs-build.log 2>&1'
EOF

# ── Create the Linode ────────────────────────────────────────────────
SSH_KEY="${SSH_PUBLIC_KEY:-$(cat ~/.ssh/st_github.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)}"

linode-cli linodes create \
    --type "$SKU" \
    --region "${ARGS[region]}" \
    --image linode/debian12 \
    --label "$LABEL" \
    --root_pass "$ROOT_PASS" \
    --authorized_keys "$SSH_KEY" \
    --metadata.user_data "$(base64 < "$TMPDIR/user_data.yaml" | tr -d '\n')" \
    --tags "bbl-fs,bbl-fs-${ARGS[role]},bbl-fs-${ARGS[size]}" \
    --no-defaults \
    --json > "$TMPDIR/linode.json"

LINODE_ID="$(jq -r '.[0].id' "$TMPDIR/linode.json")"
LINODE_IP="$(jq -r '.[0].ipv4[0]' "$TMPDIR/linode.json")"

echo
echo "  Linode ID:   $LINODE_ID"
echo "  Public IPv4: $LINODE_IP"
echo "  Root pass:   $ROOT_PASS  (write this down — Linode does not store it)"

# ── Create DNS A record + wait for propagation ───────────────────────
# Idempotent: if a record for this subdomain already exists, update it
# instead of failing.
echo "==> Setting DNS: $SUBDOMAIN.$ROOT_DOMAIN → $LINODE_IP (TTL 300)"
EXISTING_RECORD_ID="$(linode-cli domains records-list "$ZONE_ID" --json \
    | jq -r ".[] | select(.type == \"A\" and .name == \"$SUBDOMAIN\") | .id" | head -1)"
if [[ -n "$EXISTING_RECORD_ID" ]]; then
    echo "    A record exists (ID $EXISTING_RECORD_ID); updating target"
    linode-cli domains records-update "$ZONE_ID" "$EXISTING_RECORD_ID" \
        --target "$LINODE_IP" --ttl_sec 300 >/dev/null
else
    linode-cli domains records-create "$ZONE_ID" \
        --type A --name "$SUBDOMAIN" --target "$LINODE_IP" --ttl_sec 300 >/dev/null
fi

# Wait for the auth NS to serve the new record. Linode publishes
# changes within ~30s; we cap at 5 min.
echo "==> Waiting for DNS propagation on ns1.linode.com..."
for _ in $(seq 1 30); do
    actual="$(dig +short @ns1.linode.com "${ARGS[hostname]}" 2>/dev/null | tail -1)"
    if [[ "$actual" == "$LINODE_IP" ]]; then
        echo "    DNS propagated: ${ARGS[hostname]} → $LINODE_IP"
        break
    fi
    sleep 10
done
[[ "$(dig +short @ns1.linode.com "${ARGS[hostname]}" 2>/dev/null | tail -1)" == "$LINODE_IP" ]] \
    || { echo "WARN: DNS hasn't propagated after 5 min; cert step may fail. Continuing." >&2; }

echo
echo "==> Waiting for cloud-init to finish bbl-fs-build (~5 min)..."
echo "    Tail with:  ssh root@$LINODE_IP tail -f /var/log/bbl-fs-build.log"

# ── Don't proceed until we can SSH in ────────────────────────────────
for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@$LINODE_IP" 'test -f /etc/bbl-fs-build' 2>/dev/null; then
        break
    fi
    sleep 10
done

echo "==> Done. Build summary:"
ssh -o BatchMode=yes "root@$LINODE_IP" 'cat /etc/bbl-fs-build' || true
echo
echo "==> Next:"
echo "    1. Point DNS: ${ARGS[hostname]}  A  $LINODE_IP"
echo "    2. Set up Floating IP (optional, for future re-provisions)"
echo "    3. Register host in bbl-monitor: monitor_hosts table"
echo "    4. Add to bbl-call-tests targets.py if running regression"
