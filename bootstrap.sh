#!/bin/bash
# Linode user_data bootstrap. Runs ONCE at first boot via cloud-init.
#
# Substantive work lives in this repo's setup.sh, not here. This file
# only: installs git, clones the build repo, runs setup.sh with args
# passed via the metadata service. Keep this short and boring.
set -euo pipefail

# Provisioning args come from /etc/bbl-fs-bootstrap.env that the
# linode-cli wrapper writes via user_data. If absent, fall back to
# defaults so manual SSH-and-rerun works too.
ENV_FILE=/etc/bbl-fs-bootstrap.env
if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

: "${BBL_BUILD_REPO:=git@github.com:bblv2/bbl-fs-build.git}"
: "${BBL_BUILD_BRANCH:=main}"
: "${BBL_ROLE:=beta}"
: "${BBL_SIZE:=large}"
: "${BBL_HOSTNAME:=$(hostname -f)}"

apt-get update
apt-get install -y git ca-certificates

mkdir -p /usr/src
git clone --branch "$BBL_BUILD_BRANCH" "$BBL_BUILD_REPO" /usr/src/bbl-fs-build

exec /usr/src/bbl-fs-build/setup.sh \
    role="$BBL_ROLE" \
    size="$BBL_SIZE" \
    hostname="$BBL_HOSTNAME" \
    2>&1 | tee /var/log/bbl-fs-build.log
