#!/bin/bash
# 06c-loadtest-access.sh — provision SSH access for the bbl-call-tests
# harness running on rpt.
#
# After this step, the load-test diag sampler can SSH the new FS host
# as user 'bblcalltests' (read-only /proc/loadavg + nproc), and the
# WAN-egress pcap can scp its tcpdump output from the host. Without
# this, a freshly-built fs-test-N still works for load tests but the
# load_tests row will have empty diag.host_loadavg and no wan summary
# — which is what bit fs-test-9's first run on 2026-05-03.
#
# Root SSH from rpt is already in place via the cloud-init key, so
# this step only adds the bblcalltests user.
#
# Idempotent: replaces authorized_keys with the canonical pubkey on
# every run. The template lives in templates/bblcalltests.pub.
set -euo pipefail

echo '==> Creating bblcalltests user (if missing)'
if ! id bblcalltests >/dev/null 2>&1; then
    useradd -m -s /bin/bash bblcalltests
fi

echo '==> Installing bbl-call-tests harness pubkey'
install -m 700 -o bblcalltests -g bblcalltests -d /home/bblcalltests/.ssh
install -m 600 -o bblcalltests -g bblcalltests \
    "$BBL_BUILD_DIR/templates/bblcalltests.pub" \
    /home/bblcalltests/.ssh/authorized_keys

echo '==> 06c-loadtest-access.sh complete'
