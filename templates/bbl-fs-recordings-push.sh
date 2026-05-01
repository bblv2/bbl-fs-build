#!/bin/bash
# bbl-fs-build managed — DO NOT EDIT
# Push QC recordings older than 1d to B2, partitioned by hostname/date.
# Local retention: 7 days. Bucket: bbl-fs-recordings (one bucket
# shared across all FS hosts; partitioned by ${HOSTNAME}/ prefix).
set -euo pipefail

REC_DIR="__BBL_REC_PATH__"
BUCKET="bbl-fs-recordings"
HOST="$(hostname -f)"
DATE_PARTITION="$(date -u -d 'yesterday' +%Y-%m-%d)"
LOG_TAG="bbl-fs-recordings"

logger -t "$LOG_TAG" "Push starting: ${REC_DIR} → b2:${BUCKET}/${HOST}/${DATE_PARTITION}/"

# Push only files whose mtime is more than 24h old (yesterday and older).
# Skip in-progress files (mtime within last hour) so we never upload a
# partial recording.
rclone copy \
    --config /root/.config/rclone/rclone.conf \
    --min-age 1d \
    --include '*.PCMU' \
    --include '*.L16' \
    --include '*.WAV' \
    "$REC_DIR" \
    "b2:${BUCKET}/${HOST}/${DATE_PARTITION}/" \
    --log-level INFO

# Local cleanup: 7-day retention. find -delete is per-file; safer than
# rm -rf so we never blow away the dir itself.
find "$REC_DIR" -type f \( -name '*.PCMU' -o -name '*.L16' -o -name '*.WAV' \) \
    -mtime +7 -delete

logger -t "$LOG_TAG" "Push complete"
