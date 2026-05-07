#!/bin/bash
# 08-verify.sh — final assertions before declaring this FS host healthy.
#
# Each check exits non-zero on failure with a clear message, so the build
# log makes it obvious WHICH thing isn't right. Without this, silent
# regressions (e.g. a step that "completed" but didn't actually do its
# job) ship to ops as a "ready" host.
#
# Add new assertions here whenever a manual repair gets done — that
# repair is now silently de-facto required for new hosts and should be
# encoded as a check.

set -euo pipefail

ASSERT_PASS=()
ASSERT_FAIL=()

assert() {
    local label="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        ASSERT_PASS+=("$label")
    else
        ASSERT_FAIL+=("$label")
    fi
}

echo "==> Running post-provision verifications"

# ── FS process up ──────────────────────────────────────────────────
assert "FreeSWITCH process running" \
    "systemctl is-active freeswitch | grep -q active"
assert "fs_cli responsive" \
    "fs_cli -x 'status' | grep -q ready"

# ── Modules loaded ─────────────────────────────────────────────────
for mod in mod_local_stream mod_flite mod_say_en mod_conference mod_sofia \
           mod_dptools mod_lua mod_format_cdr mod_event_socket; do
    assert "module $mod loaded" \
        "fs_cli -x 'module_exists $mod' | grep -q true"
done

# ── Hold-music streams visible ─────────────────────────────────────
for g in ambient beatles classical coldplay electronica floyd guitars \
         moodbuster mpb rock sergiomendes softrock; do
    assert "local_stream $g visible" \
        "fs_cli -x 'local_stream show $g' | grep -q location"
done

# ── ESL ACL allows the LBs and rpt ─────────────────────────────────
for ip in 50.116.36.14 50.116.45.69 66.228.60.230; do
    assert "esl_in ACL allows $ip" \
        "grep -q 'cidr=\"$ip/32\"' /etc/freeswitch/autoload_configs/acl.conf.xml"
done

# ── Firewall (ufw) opens 8021 to the same set ──────────────────────
assert "ufw allows lbb-atl → 8021" \
    "ufw status | grep -q '8021/tcp.*ALLOW.*50.116.45.69'"

# ── External SIP listener (5060) up ────────────────────────────────
assert "sofia external profile listening on 5060" \
    "ss -lntu 2>/dev/null | grep -q ':5060\b'"

# ── TLS cert exists ────────────────────────────────────────────────
assert "TLS cert installed for FS in /etc/freeswitch/tls/" \
    "find /etc/freeswitch/tls -maxdepth 1 -name '*.pem' -size +1k 2>/dev/null | head -1 | grep -q pem"

# ── Lua hook script present (event-answer.lua) ─────────────────────
assert "event-answer.lua present" \
    "test -f /etc/freeswitch/scripts/event-answer.lua"

# ── Recordings dir writable by freeswitch user ─────────────────────
assert "recordings dir writable" \
    "sudo -u freeswitch test -w /opt/fs-qc-recordings"

# ── Report ─────────────────────────────────────────────────────────
echo
echo "  PASS: ${#ASSERT_PASS[@]}"
echo "  FAIL: ${#ASSERT_FAIL[@]}"
if [[ ${#ASSERT_FAIL[@]} -gt 0 ]]; then
    echo
    echo "  Failed checks:"
    for f in "${ASSERT_FAIL[@]}"; do
        echo "    ✗ $f"
    done
    exit 1
fi
echo "==> All verifications passed."
