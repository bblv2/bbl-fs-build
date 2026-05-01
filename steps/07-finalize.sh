#!/bin/bash
# 07-finalize.sh — version stamp, motd, sanity checks, leave the box clean.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"
: "${BBL_REC_PATH:=/opt/fs-qc-recordings}"

echo "==> Writing /etc/bbl-fs-build (version stamp)"
FS_VERSION="$(dpkg-query -W -f='${Version}\n' freeswitch 2>/dev/null || echo unknown)"
CONFIG_COMMIT="$(git -C /usr/src/bbl-fs-config rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_COMMIT="$(git -C "$BBL_BUILD_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > /etc/bbl-fs-build <<EOF
hostname=${BBL_HOSTNAME}
role=${BBL_ROLE}
size=${BBL_SIZE}
built_at=${BUILT_AT}
fs_version=${FS_VERSION}
debian_version=$(cat /etc/debian_version)
kernel=$(uname -r)
build_repo_commit=${BUILD_COMMIT}
config_repo_commit=${CONFIG_COMMIT}
external_ip=${BBL_EXTERNAL_IP}
recording_path=${BBL_REC_PATH}
EOF
chmod 644 /etc/bbl-fs-build

echo "==> Writing /etc/motd"
sed -e "s|__BBL_HOSTNAME__|${BBL_HOSTNAME}|g" \
    -e "s|__BBL_ROLE__|${BBL_ROLE}|g" \
    -e "s|__BBL_SIZE__|${BBL_SIZE}|g" \
    -e "s|__BBL_BUILT_AT__|${BUILT_AT}|g" \
    -e "s|__BBL_FS_VERSION__|${FS_VERSION:0:30}|g" \
    -e "s|__BBL_CONFIG_COMMIT__|${CONFIG_COMMIT}|g" \
    -e "s|__BBL_REC_PATH__|${BBL_REC_PATH}|g" \
    "$BBL_BUILD_DIR/templates/motd" > /etc/motd

# Wipe the dynamic motd debian sometimes adds — ours is the source of truth
rm -f /etc/update-motd.d/[0-9]*-* 2>/dev/null || true

echo "==> Final sanity checks"
echo "--- FreeSWITCH status ---"
fs_cli -x 'status' | head -8
echo
echo "--- listening sockets ---"
ss -tlnp 2>/dev/null | grep -E '5060|5061|5080|5081|7443|22' || true
echo
echo "--- ufw status ---"
ufw status | head -15
echo
echo "--- bbl-fs-build version stamp ---"
cat /etc/bbl-fs-build

echo
echo "==> 07-finalize.sh complete"
echo "==> Box is ready: $BBL_HOSTNAME ($BBL_ROLE / $BBL_SIZE)"
