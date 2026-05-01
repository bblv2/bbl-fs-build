#!/bin/bash
# bbl-fs-build orchestrator. Runs steps/*.sh in numeric order.
#
# Usage:  setup.sh role=<beta|prod> size=<small|medium|large|xlarge> hostname=<fqdn>
#
# Each step:
#   - Reads its own knobs from env (set by this orchestrator)
#   - Is idempotent: safe to re-run after a partial failure
#   - Logs to stdout/stderr (we tee to /var/log/bbl-fs-build.log via bootstrap.sh)
#
# This script does NOT do any heavy lifting — it just dispatches. If
# you find yourself adding more than a handful of lines here that
# aren't argument parsing, write a step instead.
set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]=large [hostname]= )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done

for required in role hostname; do
    if [[ -z "${ARGS[$required]}" ]]; then
        echo "$0: $required is required" >&2
        echo "usage: $0 role=<beta|prod> size=<small|medium|large|xlarge> hostname=<fqdn>" >&2
        exit 2
    fi
done

case "${ARGS[role]}" in beta|prod) ;; *) echo "role must be beta|prod" >&2; exit 2;; esac
case "${ARGS[size]}" in small|medium|large|xlarge) ;; *) echo "unknown size: ${ARGS[size]}" >&2; exit 2;; esac

export BBL_ROLE="${ARGS[role]}"
export BBL_SIZE="${ARGS[size]}"
export BBL_HOSTNAME="${ARGS[hostname]}"
export BBL_BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
export BBL_HOST_CONF=/etc/bbl-fs-host.conf

# ── Environment sanity ───────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "$0: must run as root" >&2
    exit 1
fi

if ! grep -q '^ID=debian' /etc/os-release || ! grep -q '^VERSION_ID="12"' /etc/os-release; then
    echo "$0: only tested on Debian 12 (Bookworm); refusing to proceed" >&2
    exit 1
fi

# ── Hostname ─────────────────────────────────────────────────────────
echo "==> Setting hostname to $BBL_HOSTNAME"
hostnamectl set-hostname "$BBL_HOSTNAME"
# /etc/hosts entry so name resolves locally even before DNS propagates
short="${BBL_HOSTNAME%%.*}"
if ! grep -q "$BBL_HOSTNAME" /etc/hosts; then
    sed -i "1i 127.0.1.1 $BBL_HOSTNAME $short" /etc/hosts
fi

# ── Run steps in order ───────────────────────────────────────────────
echo "==> bbl-fs-build starting: role=$BBL_ROLE size=$BBL_SIZE hostname=$BBL_HOSTNAME"
echo "==> $(date -u)"

cd "$BBL_BUILD_DIR"
for step in steps/[0-9]*.sh; do
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "==> $step"
    echo "════════════════════════════════════════════════════════════════"
    bash "$step"
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "==> bbl-fs-build complete  $(date -u)"
echo "════════════════════════════════════════════════════════════════"
