#!/bin/bash
# 05-recordings-cron.sh — wire up nightly B2 push of QC recordings.
#
# Renders rclone.conf with the operator's B2 creds (from host.conf),
# installs a /etc/cron.d entry, and creates a logrotate rule for the
# push log.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"
: "${BBL_REC_PATH:=/opt/fs-qc-recordings}"
: "${BBL_B2_BUCKET:=bbl-fs-recordings}"

if [[ -z "${BBL_B2_KEY_ID:-}" || -z "${BBL_B2_APP_KEY:-}" ]]; then
    echo "WARN: BBL_B2_KEY_ID / BBL_B2_APP_KEY unset — skipping B2 push setup."
    echo "      Local recording continues; archive cron NOT installed."
    exit 0
fi

echo "==> Render rclone.conf for B2 access"
install -d -m 700 /root/.config/rclone
sed -e "s|__BBL_B2_KEY_ID__|${BBL_B2_KEY_ID}|" \
    -e "s|__BBL_B2_APP_KEY__|${BBL_B2_APP_KEY}|" \
    "$BBL_BUILD_DIR/templates/rclone.conf" \
    > /root/.config/rclone/rclone.conf
chmod 600 /root/.config/rclone/rclone.conf

# Smoke-test creds + bucket access. Scoped keys (recommended) often
# can't list all buckets — but they CAN list inside their bucket.
# So we test bucket access directly rather than listing all.
echo "==> Verify B2 access to bucket: $BBL_B2_BUCKET"
if ! rclone --config /root/.config/rclone/rclone.conf lsd "b2:${BBL_B2_BUCKET}" >/dev/null 2>&1; then
    # Bucket doesn't exist OR key can't see it. Try create — succeeds for
    # master-scoped keys, fails clearly for bucket-scoped keys.
    echo "==> Bucket $BBL_B2_BUCKET inaccessible; attempting create"
    rclone --config /root/.config/rclone/rclone.conf mkdir "b2:${BBL_B2_BUCKET}" \
        || { echo "$0: cannot access or create bucket '$BBL_B2_BUCKET' — check key scope or create bucket on B2 console first" >&2; exit 1; }
fi

echo "==> Install push script + cron"
install -d -m 755 /usr/local/sbin
sed -e "s|__BBL_REC_PATH__|${BBL_REC_PATH}|g" \
    -e "s|__BBL_B2_BUCKET__|${BBL_B2_BUCKET}|g" \
    "$BBL_BUILD_DIR/templates/bbl-fs-recordings-push.sh" \
    > /usr/local/sbin/bbl-fs-recordings-push.sh
chmod 755 /usr/local/sbin/bbl-fs-recordings-push.sh

install -m 644 \
    "$BBL_BUILD_DIR/templates/bbl-fs-recordings.cron" \
    /etc/cron.d/bbl-fs-recordings

# logrotate
cat > /etc/logrotate.d/bbl-fs-recordings <<'EOF'
/var/log/bbl-fs-recordings.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# Also rotate FreeSWITCH's own log — apt-shipped one doesn't include this
cat > /etc/logrotate.d/bbl-freeswitch <<'EOF'
/var/log/freeswitch/freeswitch.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /usr/bin/fs_cli -x 'fsctl send_sighup' >/dev/null 2>&1 || true
    endscript
}
EOF

echo "==> 05-recordings-cron.sh complete (push runs nightly at 04:17 UTC)"
