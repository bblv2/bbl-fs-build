#!/bin/bash
# provision.sh — create a new FreeSWITCH Linode using bbl-fs-build.
#
# Usage:
#   scripts/provision.sh role=beta size=medium hostname=fs-test-4.bblapp.io
#   scripts/provision.sh role=prod size=large  hostname=fs-atl-2.bblapp.io
#
# host-conf= is optional and now only used as an escape hatch. Default
# flow: provision.sh assembles the new box's host.conf from four overlays
# (later overrides earlier):
#   1. seeds/defaults.conf                       (this repo, VCS)
#   2. seeds/hosts/<short>.conf                  (this repo, VCS, optional)
#   3. /etc/bbl-fs-secrets.conf                  (loose on rpt, required)
#   4. /etc/bbl-fs-secrets.d/<short>.conf        (loose on rpt, optional)
# BBL_DOMAIN is appended last from hostname=.
#
# register.py IDs (BBL_TELNYX_CONNECTION_ID, BBL_TEST_DID, etc.) are still
# written to /etc/bbl-fs-host.conf on the running box after Telnyx
# registration — they're runtime state, not seed.
#
# Prerequisites:
#   - linode-cli installed and authenticated (`linode-cli configure`)
#   - /etc/bbl-fs-secrets.conf populated once with BBL_SIGNALWIRE_TOKEN,
#     BBL_B2_KEY_ID, BBL_B2_APP_KEY. See seeds/secrets.example.conf.
set -euo pipefail

# Source operator-side env (BBL_MONITOR_DSN, TELNYX_API_KEY) needed by
# register*.py. On rpt this lives at /opt/bbl-call-tests/.env. Override
# via BBL_OPERATOR_ENV=/path/to/env if running from elsewhere.
OPERATOR_ENV="${BBL_OPERATOR_ENV:-/opt/bbl-call-tests/.env}"
if [[ -r "$OPERATOR_ENV" ]]; then
    set -a; . "$OPERATOR_ENV"; set +a
fi

# ── Parse args ───────────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]= [hostname]= [host-conf]= [region]=us-southeast )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done
for required in role size hostname; do
    [[ -n "${ARGS[$required]}" ]] || { echo "$0: $required is required" >&2; exit 2; }
done

# Hostname format precheck. Must be FQDN with at least one dot, and
# the part before the first dot must be non-empty. Rejects shorthand
# like 'fs-test-5' that would otherwise propagate as BBL_DOMAIN and
# fail later at DNS / TLS time.
if [[ "${ARGS[hostname]}" != *.*  || "${ARGS[hostname]%%.*}" == "" ]]; then
    echo "$0: hostname='${ARGS[hostname]}' must be a fully-qualified domain (e.g. fs-test-5.bblapp.io)" >&2
    exit 2
fi

# ── Resolve size → SKU ───────────────────────────────────────────────
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIZES_FILE="$BUILD_DIR/conf/linode-sizes.conf"
SKU="$(awk -v size="${ARGS[size]}" '$1 == size {print $2}' "$SIZES_FILE")"
[[ -n "$SKU" ]] || { echo "$0: unknown size '${ARGS[size]}' — see $SIZES_FILE" >&2; exit 2; }

LABEL="${ARGS[hostname]//./-}"
ROOT_PASS="$(openssl rand -base64 24)"

echo "==> Provisioning ${ARGS[hostname]} as Linode $SKU in ${ARGS[region]}"

# ── DNS: find the Linode-managed zone for this hostname ─────────────
# Resolve BEFORE writing any per-host conf, so a typo'd hostname can't
# leave an orphan /etc/bbl-fs-<bad>.host.conf behind.
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

# ── Assemble host.conf from VCS seeds + loose secrets ────────────────
# Layered overlay (later overrides earlier):
#   1. seeds/defaults.conf                       — VCS, required
#   2. seeds/hosts/<short>.conf                  — VCS, optional
#   3. /etc/bbl-fs-secrets.conf                  — loose on rpt, required
#   4. /etc/bbl-fs-secrets.d/<short>.conf        — loose on rpt, optional
# BBL_DOMAIN is appended last from hostname=.
#
# host-conf= remains as an escape hatch for one-off boxes that need an
# entirely custom file. When supplied it short-circuits the overlay.
SHORT_HOST="${ARGS[hostname]%%.*}"
SEEDS_DIR="$BUILD_DIR/seeds"
DEFAULTS="$SEEDS_DIR/defaults.conf"
PER_HOST_DEFAULTS="$SEEDS_DIR/hosts/${SHORT_HOST}.conf"
SECRETS="${BBL_FS_SECRETS:-/etc/bbl-fs-secrets.conf}"
PER_HOST_SECRETS="/etc/bbl-fs-secrets.d/${SHORT_HOST}.conf"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ -n "${ARGS[host-conf]}" ]]; then
    HOST_CONF="${ARGS[host-conf]}"
    [[ -r "$HOST_CONF" ]] || { echo "$0: cannot read $HOST_CONF" >&2; exit 2; }
    echo "==> Using operator-supplied host.conf: $HOST_CONF (skipping overlay assembly)"
else
    [[ -r "$DEFAULTS" ]] || { echo "$0: missing $DEFAULTS (VCS-tracked)" >&2; exit 2; }
    [[ -r "$SECRETS" ]]  || { echo "$0: missing $SECRETS — copy from $SEEDS_DIR/secrets.example.conf and fill in real values" >&2; exit 2; }
    HOST_CONF="$TMPDIR/host.conf"
    {
        echo "# Assembled by bbl-fs-build/scripts/provision.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Layers:"
        echo "#   1. $DEFAULTS"
        [[ -r "$PER_HOST_DEFAULTS" ]] && echo "#   2. $PER_HOST_DEFAULTS"
        echo "#   3. $SECRETS"
        [[ -r "$PER_HOST_SECRETS" ]] && echo "#   4. $PER_HOST_SECRETS"
        echo "#   5. BBL_DOMAIN appended from hostname="
        echo
        cat "$DEFAULTS"
        if [[ -r "$PER_HOST_DEFAULTS" ]]; then
            echo
            echo "# ── overlay: seeds/hosts/${SHORT_HOST}.conf ─────────────────────"
            cat "$PER_HOST_DEFAULTS"
        fi
        echo
        echo "# ── overlay: $SECRETS (secrets, loose on rpt) ──────────────"
        cat "$SECRETS"
        if [[ -r "$PER_HOST_SECRETS" ]]; then
            echo
            echo "# ── overlay: /etc/bbl-fs-secrets.d/${SHORT_HOST}.conf ───────────"
            cat "$PER_HOST_SECRETS"
        fi
        echo
        echo "# ── derived ─────────────────────────────────────────────────────"
        echo "BBL_DOMAIN=${ARGS[hostname]}"
    } > "$HOST_CONF"
    chmod 0600 "$HOST_CONF"
    echo "==> Assembled host.conf at $HOST_CONF"
fi


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
$(sed 's/^/      /' "$HOST_CONF")
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

# ── Push bbl-fs-config to the new box BEFORE cloud-init's setup.sh
#    needs it. The repo is private and the new box has no GitHub SSH
#    key, so step 03-fs-config.sh would fail trying to clone it from
#    GitHub. Wait for SSH to come up, then rsync from operators clone.
LOCAL_CONFIG=${BBL_LOCAL_CONFIG_DIR:-/opt/bbl-fs/bbl-fs-config}
echo "==> Waiting for SSH to come up on $LINODE_IP, then pushing bbl-fs-config"
echo -n "    "
for _ in $(seq 1 30); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@$LINODE_IP" 'test -d /usr/src' 2>/dev/null; then
        echo " up"
        break
    fi
    echo -n "."
    sleep 5
done
if [[ -d "$LOCAL_CONFIG" ]]; then
    # Pull latest first, then push to box. Use tar-over-ssh instead of
    # rsync because rsync isn't installed on the freshly-booted box yet
    # (it comes in step 01). Tar-over-ssh works with just ssh + tar
    # (both present in stock debian12). Step 03 detects the existing
    # checkout and skips its git-fetch when GitHub SSH isn't available.
    (cd "$LOCAL_CONFIG" && git pull --quiet 2>/dev/null || true)
    ssh -o BatchMode=yes "root@$LINODE_IP" "mkdir -p /usr/src/bbl-fs-config && rm -rf /usr/src/bbl-fs-config/*"
    tar -C "$LOCAL_CONFIG" -cf - . | \
        ssh -o BatchMode=yes "root@$LINODE_IP" "tar -C /usr/src/bbl-fs-config -xf -" || \
            echo "    WARN: bbl-fs-config tar push failed; setup.sh step 03 may also fail"
else
    echo "    WARN: $LOCAL_CONFIG not on operator host; step 03 will try GitHub clone"
fi

# ── Don't proceed until /etc/bbl-fs-build appears (setup.sh has finished)
echo
echo "==> Waiting for setup.sh to finish (~5-8 min). Live tail:"
echo "        ssh root@$LINODE_IP tail -f /var/log/bbl-fs-build.log"
echo -n "    "
for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@$LINODE_IP" 'test -f /etc/bbl-fs-build' 2>/dev/null; then
        echo " done"
        break
    fi
    # Show the most recent step header from the build log so the operator
    # knows what's actually running, not just "still waiting".
    last_step=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "root@$LINODE_IP" \
        'grep -E "^==> steps/" /var/log/bbl-fs-build.log 2>/dev/null | tail -1' 2>/dev/null \
        | sed 's|.*steps/||;s|\.sh.*||')
    if [[ -n "$last_step" ]]; then
        printf " [%s]" "$last_step"
    else
        echo -n "."
    fi
    sleep 10
done

echo "==> Done. Build summary:"
ssh -o BatchMode=yes "root@$LINODE_IP" 'cat /etc/bbl-fs-build' || true

# ── post-build registration steps (operator-side) ──────────────────
PY=/opt/bbl-call-tests/.venv/bin/python
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# 1. Always: register in bbl-monitor (every linode goes here)
echo
echo "==> Registering ${ARGS[hostname]} in bbl-monitor"
CPU_COUNT=$(ssh -o BatchMode=yes "root@$LINODE_IP" 'nproc' 2>/dev/null || echo 1)
"$PY" "$SCRIPTS/register-monitor.py" \
    --hostname "${ARGS[hostname]}" \
    --cpu-count "$CPU_COUNT" \
    --role "${ARGS[role]}"

# 2. role-specific registration
if [[ "${ARGS[role]}" == "beta" ]]; then
    echo
    echo "==> Registering ${ARGS[hostname]} for beta testing (Telnyx + bridge + DID)"
    REGOUT=$(mktemp)
    "$PY" "$SCRIPTS/register.py" --hostname "${ARGS[hostname]}" | tee "$REGOUT"
    # Append the persisted-IDs lines (they look like BBL_*=... after the
    # printed "# Append to ..." marker) onto the operator's host.conf
    if grep -q '^# Append to' "$REGOUT"; then
        echo "" >> "$HOST_CONF"
        echo "# bbl-fs-build register.py — written $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HOST_CONF"
        sed -n '/^# Append to/,$p' "$REGOUT" | grep -E '^BBL_' >> "$HOST_CONF"
        echo "==> Persisted register IDs to $HOST_CONF"
    fi
    rm -f "$REGOUT"

    # ── Open lbb-atl ufw for the new FS box's ESL outbound socket ──────
    # FS dialplan dispatches every inbound PSTN call to the beta ESL relay
    # via `socket(50.116.45.69:8085 async full)`. lbb-atl's firewall is
    # explicit-allow on 8085 (denies anything else), so each new beta FS
    # IP must be whitelisted. Without this, calls reach FS, FS tries to
    # connect to the relay, the SYN is dropped, and the caller eventually
    # gets 480 Temporarily Unavailable. Idempotent: ufw skips dupes.
    LBB_HOST="${BBL_LBB_HOST:-lbb-atl.bblapp.io}"
    echo
    echo "==> Allow $LINODE_IP on $LBB_HOST:8085 (beta ESL outbound)"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "$LBB_HOST" \
            "ufw allow from $LINODE_IP to any port 8085 proto tcp comment '${ARGS[hostname]}-esl-outbound'" \
            2>&1 | sed 's/^/    /'; then
        echo "    ufw rule added (or already present)"
    else
        echo "    WARNING: failed to add ufw rule on $LBB_HOST — calls will hit 480 until fixed manually:"
        echo "      ssh $LBB_HOST 'ufw allow from $LINODE_IP to any port 8085 proto tcp comment ${ARGS[hostname]}-esl-outbound'"
    fi
elif [[ "${ARGS[role]}" == "prod" ]]; then
    echo
    echo "==> Role=prod: minimal registration only (bbl2022 freeswitch_setup)"
    echo "    (register-prod.sh not yet implemented — add manually for now)"
fi

echo
echo "==> Provision complete."
echo "    Next: dial the Test DID printed above to verify end-to-end."
