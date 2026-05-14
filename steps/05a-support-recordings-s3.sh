#!/bin/bash
# 05a-support-recordings-s3.sh — wire up nightly S3 push of support
# IVR recordings.
#
# Sibling to 05-recordings-cron.sh (which handles QC recordings to
# B2). Two separate jobs because:
#   - support recordings have different retention/compliance needs
#   - we want to keep the working B2 pipeline untouched until
#     support is proven stable
#
# Appends an [s3] remote to rclone.conf (idempotent), installs the
# push script + cron, and creates a logrotate rule.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"
: "${BBL_REC_PATH:=/opt/fs-qc-recordings}"
: "${BBL_S3_BUCKET:=bbl1}"
: "${BBL_S3_REGION:=us-east-1}"
: "${BBL_S3_SUPPORT_PREFIX:=support-recordings}"

if [[ -z "${BBL_S3_ACCESS_KEY_ID:-}" || -z "${BBL_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "WARN: BBL_S3_ACCESS_KEY_ID / BBL_S3_SECRET_ACCESS_KEY unset — skipping S3 push setup."
    echo "      Support recordings will continue accumulating locally;"
    echo "      add the keys to /etc/bbl-fs-secrets.conf and rerun setup.sh."
    exit 0
fi

echo "==> Append [s3] remote to /root/.config/rclone/rclone.conf"
install -d -m 700 /root/.config/rclone
touch /root/.config/rclone/rclone.conf
chmod 600 /root/.config/rclone/rclone.conf

# Idempotent: drop any prior [s3] block, re-render fresh. Awk reads
# the file and emits everything except the [s3] section.
TMP="$(mktemp)"
awk '
    /^\[s3\]/        { in_s3=1; next }
    /^\[/ && in_s3   { in_s3=0 }
    !in_s3
' /root/.config/rclone/rclone.conf > "$TMP"
cat > /root/.config/rclone/rclone.conf <<EOF
$(cat "$TMP")

[s3]
type = s3
provider = AWS
access_key_id = ${BBL_S3_ACCESS_KEY_ID}
secret_access_key = ${BBL_S3_SECRET_ACCESS_KEY}
region = ${BBL_S3_REGION}
EOF
rm -f "$TMP"
chmod 600 /root/.config/rclone/rclone.conf

echo "==> Verify S3 access to bucket: $BBL_S3_BUCKET"
if ! rclone --config /root/.config/rclone/rclone.conf lsd "s3:${BBL_S3_BUCKET}" >/dev/null 2>&1; then
    echo "$0: cannot access bucket '$BBL_S3_BUCKET' with provided keys — check IAM policy" >&2
    exit 1
fi

echo "==> Install support-recordings push script + cron"
install -d -m 755 /usr/local/sbin
sed -e "s|__BBL_REC_PATH__|${BBL_REC_PATH}|g" \
    -e "s|__BBL_S3_BUCKET__|${BBL_S3_BUCKET}|g" \
    -e "s|__BBL_S3_SUPPORT_PREFIX__|${BBL_S3_SUPPORT_PREFIX}|g" \
    "$BBL_BUILD_DIR/templates/bbl-fs-support-recordings-push.sh" \
    > /usr/local/sbin/bbl-fs-support-recordings-push.sh
chmod 755 /usr/local/sbin/bbl-fs-support-recordings-push.sh

install -m 644 \
    "$BBL_BUILD_DIR/templates/bbl-fs-support-recordings.cron" \
    /etc/cron.d/bbl-fs-support-recordings

cat > /etc/logrotate.d/bbl-fs-support-recordings <<'EOF'
/var/log/bbl-fs-support-recordings.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

echo "==> 05a-support-recordings-s3.sh complete (push runs nightly at 04:28 UTC)"
