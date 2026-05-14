#!/bin/bash
# bbl-fs-build managed — DO NOT EDIT
# Push support-IVR recordings older than 1d to AWS S3, partitioned
# by hostname/date.
#
# Scope is intentionally narrow: only files under
# ${REC_DIR}/support/*.WAV. The legacy QC-recording push
# (bbl-fs-recordings-push.sh → B2) still pushes everything else.
# Two separate jobs avoids touching the working B2 pipeline.
#
# Local retention: 7 days (same as the B2 pipeline). Bucket layout:
#   s3:${BUCKET}/support-recordings/${HOSTNAME}/${YYYY-MM-DD}/<uuid>.WAV
set -euo pipefail

REC_DIR="__BBL_REC_PATH__"
BUCKET="__BBL_S3_BUCKET__"
PREFIX="__BBL_S3_SUPPORT_PREFIX__"
HOST="$(hostname -f)"
DATE_PARTITION="$(date -u -d 'yesterday' +%Y-%m-%d)"
LOG_TAG="bbl-fs-support-recordings"

SRC="${REC_DIR}/support"
DST="s3:${BUCKET}/${PREFIX}/${HOST}/${DATE_PARTITION}/"

logger -t "$LOG_TAG" "Push starting: ${SRC} → ${DST}"

# Only files whose mtime is more than 24h old. Skip in-progress files
# (mtime within last hour) so we never upload a partial recording.
rclone copy \
    --config /root/.config/rclone/rclone.conf \
    --min-age 1d \
    --include '*.WAV' \
    "$SRC" \
    "$DST" \
    --log-level INFO

# Local cleanup: 7-day retention. find -delete is per-file; safer
# than rm -rf so we never blow away the support/ dir itself.
find "$SRC" -type f -name '*.WAV' -mtime +7 -delete

logger -t "$LOG_TAG" "Push complete"
