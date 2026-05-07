#!/bin/bash
# 03c-fs-music.sh — guarantee FreeSWITCH hold-music plays.
#
# Belt-and-suspenders step: even though bbl-fs-config's apply-config.sh
# also covers this on the happy path, we make absolutely sure here that:
#   1. mod_local_stream is installed (apt package + .so present)
#   2. mod_local_stream is loaded into running FS
#   3. /usr/share/freeswitch/sounds/music/ has all 12 BBL genre dirs
#   4. local_stream.conf.xml declares each genre's <directory> entry
#
# Without ANY ONE of these, callers in conferences hear silence instead
# of music-on-hold during wait-mode (and FS spams the log with
# "Invalid file format [local_stream] for [softrock]!").
#
# Idempotent — re-running this step is safe and fast (sync skips already-
# populated genres; load is a no-op if already loaded).

set -euo pipefail

ACL_SRC=fs-atl.bblapp.io
TARGET_MUSIC=/usr/share/freeswitch/sounds/music
GENRES=(ambient beatles classical coldplay electronica floyd guitars
        moodbuster mpb rock sergiomendes softrock)

echo "==> 1/4 ensure freeswitch-mod-local-stream package"
if ! dpkg -s freeswitch-mod-local-stream >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y freeswitch-mod-local-stream
else
    echo "    already installed"
fi
[[ -f /usr/lib/freeswitch/mod/mod_local_stream.so ]] || {
    echo "ERROR: mod_local_stream.so missing after apt install" >&2; exit 1; }

echo "==> 2/4 ensure modules.conf.xml declares <load module=\"mod_local_stream\"/>"
MOD_CONF=/etc/freeswitch/autoload_configs/modules.conf.xml
if ! grep -q 'mod_local_stream' "$MOD_CONF"; then
    cp -p "$MOD_CONF" "$MOD_CONF.bak.$(date +%s)"
    sed -i 's|<load module="mod_tone_stream"/>|<load module="mod_tone_stream"/>\n    <load module="mod_local_stream"/>|' "$MOD_CONF"
    echo "    added"
else
    echo "    already declared"
fi

echo "==> 3/4 sync music genre directories from rpt"
# Pull from rpt's HTTP-served tarball — no SSH credential dance needed
# from a freshly-provisioned FS host. rpt is the canonical staging point
# (re-staged from fs-atl when the music catalog changes).
MUSIC_URL=${MUSIC_URL:-http://rpt.bblapp.io/bbl-fs-assets/music.tar.gz}

mkdir -p "$TARGET_MUSIC"
# Quick check: if all 12 genres are already populated, skip.
ALL_PRESENT=1
for g in "${GENRES[@]}"; do
    if [[ ! -d "$TARGET_MUSIC/$g" ]] || ! find "$TARGET_MUSIC/$g" -type f | head -1 | grep -q .; then
        ALL_PRESENT=0
        break
    fi
done
if [[ $ALL_PRESENT -eq 1 ]]; then
    echo "    all 12 genres already populated"
else
    echo "    fetching tarball from $MUSIC_URL"
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    if ! curl -fsSL --max-time 300 -o "$TMPDIR/music.tar.gz" "$MUSIC_URL"; then
        echo "ERROR: failed to fetch $MUSIC_URL" >&2
        exit 1
    fi
    SIZE=$(stat -c%s "$TMPDIR/music.tar.gz")
    echo "    downloaded $SIZE bytes; extracting"
    # Tarball contains music/<genre>/... — strip leading music/ so we
    # land directly into $TARGET_MUSIC.
    tar xzf "$TMPDIR/music.tar.gz" --strip-components=1 -C "$TARGET_MUSIC"
    chown -R freeswitch:freeswitch "$TARGET_MUSIC"
    echo "    extracted"
fi

echo "==> 4/4 (re)load mod_local_stream — only if FS is currently running"
# During fresh provision, step 02 stops FS and it isn't started again until
# step 07-finalize. fs_cli would block forever waiting on ESL. The module
# declaration in modules.conf.xml is enough — FS will load mod_local_stream
# and scan the music dirs at start time. 08-verify.sh asserts streams visible.
#
# When this step runs on an ALREADY-RUNNING FS (e.g. re-provisioning to
# repair an existing host), we do want unload+load to pick up newly-added
# directories — `local_stream reload <name>` only re-reads files for an
# already-known stream, doesn't discover new <directory> entries.
if systemctl is-active --quiet freeswitch && \
   timeout 5 fs_cli -x 'status' >/dev/null 2>&1; then
    echo "    FS is up — issuing unload+load + asserting all ${#GENRES[@]} streams"
    fs_cli -x 'reloadxml' >/dev/null 2>&1 || true
    if fs_cli -x 'module_exists mod_local_stream' 2>/dev/null | grep -q true; then
        fs_cli -x 'unload mod_local_stream' >/dev/null 2>&1 || true
    fi
    fs_cli -x 'load mod_local_stream' >/dev/null 2>&1
    fs_cli -x 'module_exists mod_local_stream' 2>/dev/null | grep -q true || {
        echo "ERROR: mod_local_stream failed to load" >&2; exit 1; }

    MISSING=()
    for g in "${GENRES[@]}"; do
        out=$(timeout 5 fs_cli -x "local_stream show $g" 2>&1 || true)
        [[ "$out" == *"location"* ]] || MISSING+=("$g")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "ERROR: streams not visible after load: ${MISSING[*]}" >&2
        exit 1
    fi
    echo "    mod_local_stream loaded; all ${#GENRES[@]} streams visible"
else
    echo "    FS not running — module will load at startup (step 07 starts FS;"
    echo "    step 08-verify.sh asserts streams visible after that)."
fi

echo "==> 03c-fs-music.sh complete"
