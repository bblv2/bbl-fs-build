#!/bin/bash
# 02-fs-install.sh — apt-install the curated FreeSWITCH module set.
#
# Reads conf/fs-packages.conf line-by-line, ignores comments/blanks,
# and apt-installs the result. Substantially smaller than meta-all
# (~16 modules vs 60+), and easier to audit when something changes.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

PKGS_FILE="$BBL_BUILD_DIR/conf/fs-packages.conf"
[[ -r "$PKGS_FILE" ]] || { echo "missing: $PKGS_FILE" >&2; exit 1; }

# Parse: strip comments, blanks, surrounding whitespace
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKGS_FILE" | awk '{print $1}')

if (( ${#PKGS[@]} == 0 )); then
    echo "no packages listed — refusing to proceed" >&2
    exit 1
fi

echo "==> Installing ${#PKGS[@]} FreeSWITCH packages:"
printf '    - %s\n' "${PKGS[@]}"
apt-get install -y -q "${PKGS[@]}"

# The freeswitch package starts FS automatically. Stop it now — we'll
# start it after step 03 has laid down our config. Otherwise FS comes
# up with the apt-shipped vanilla config for a few seconds and might
# bind to ports we want our config to own.
echo "==> Stopping FreeSWITCH (will restart after config is laid down)"
systemctl stop freeswitch || true

# Verify the freeswitch user/group exist (created by apt postinst)
id freeswitch >/dev/null || { echo "freeswitch user not created by apt — abort" >&2; exit 1; }

echo "==> Installed FreeSWITCH version:"
fs_cli=/usr/bin/fs_cli
if command -v freeswitch >/dev/null; then
    dpkg-query -W -f='${Package} ${Version}\n' freeswitch
fi

echo "==> 02-fs-install.sh complete"
