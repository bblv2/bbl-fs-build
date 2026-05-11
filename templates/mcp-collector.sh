#!/bin/bash
# MCP Server Metrics Collector — v3 (adds per-conference detail)
# Deploy to each monitored host, run every 5 min via cron:
# */5 * * * * MONITOR_TOKEN=mcp-monitor-2026 /usr/local/bin/mcp-collector.sh
#
# v2 added the `components` field — auto-detected per-host inventory of
# installed git repos (HEAD/branch/dirty count), supervisor/systemd
# services, and version strings (python/django/freeswitch/nginx).
#
# v3 adds `conferences` — per-active-conference member roster from FS
# (name, uuid, run_time, per-member id/uuid/cid/join_age/is_moderator/
# talking/hold/has_floor). Drives the /dashboard active-conferences
# grid in bbl-monitor without the monitor host having to ssh into FS.
# Empty array on non-FS hosts; the ingest endpoint REPLACEs FS-conf
# rows for this host each push, so confs that end disappear within
# one collector tick.

ENDPOINT="http://crawl.rgs.mx:8765/monitor/ingest"
MONITOR_TOKEN="${MONITOR_TOKEN:-REPLACE_ME}"

HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)

# CPU count
CPU_COUNT=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

# Load averages
read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

# Memory (MB)
MEM_LINE=$(free -m 2>/dev/null | awk '/^Mem:/{print $2,$3,$7}')
MEM_TOTAL=$(echo $MEM_LINE | awk '{print $1}')
MEM_USED=$(echo $MEM_LINE | awk '{print $2}')
MEM_FREE=$(echo $MEM_LINE | awk '{print $3}')
if [ -z "$MEM_TOTAL" ] || [ "$MEM_TOTAL" -eq 0 ] 2>/dev/null; then MEM_PCT="0"; else
  MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}")
fi

# Primary network interface
NET_IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
[ -z "$NET_IFACE" ] && NET_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)
[ -z "$NET_IFACE" ] && NET_IFACE="eth0"

NET_RX=0; NET_TX=0
if [ -f /proc/net/dev ]; then
  NET_LINE=$(awk -v iface="$NET_IFACE:" '$1==iface{print $2,$10}' /proc/net/dev)
  NET_RX=$(echo $NET_LINE | awk '{print $1}')
  NET_TX=$(echo $NET_LINE | awk '{print $2}')
  [ -z "$NET_RX" ] && NET_RX=0
  [ -z "$NET_TX" ] && NET_TX=0
fi

# Disk usage — build JSON array, skip tmpfs/devtmpfs/udev/loop
DISKS_JSON=$(df -BM 2>/dev/null | tail -n +2 | grep -v -E '^(tmpfs|devtmpfs|udev|/dev/loop)' | awk '
{
  gsub(/M/, "", $2); gsub(/M/, "", $3)
  pct = ($2 > 0) ? int($3/$2*100) : 0
  printf "{\"mount\":\"%s\",\"total_mb\":%s,\"used_mb\":%s,\"pct\":%d},", $6, $2, $3, pct
}' | sed 's/,$//')
DISKS_JSON="[$DISKS_JSON]"


# Calls in progress (FreeSwitch only — fs_cli must be available).
# fs_cli is at one of two paths depending on FS build. Try common names
# first, fall back to the versioned path.
CALLS_IN_PROGRESS="null"
FS_CLI=$(command -v fs_cli 2>/dev/null)
[ -z "$FS_CLI" ] && [ -x /usr/local/freeswitch/bin/fs_cli ] && FS_CLI=/usr/local/freeswitch/bin/fs_cli
[ -z "$FS_CLI" ] && [ -x /usr/local/freeswitch-1.10.5.-release/bin/fs_cli ] && FS_CLI=/usr/local/freeswitch-1.10.5.-release/bin/fs_cli
if [ -n "$FS_CLI" ] && [ -x "$FS_CLI" ]; then
  _count=$($FS_CLI -x "show calls" 2>/dev/null | grep -E "^[0-9]+ total" | grep -oE "^[0-9]+")
  [ -n "$_count" ] && CALLS_IN_PROGRESS=$_count
fi

# Per-conference detail (FreeSwitch only). Enumerate active conferences
# via `conference list count`, then dump each one's XML and parse to a
# JSON array. Each entry: { name, uuid, member_count, run_time_s,
# members: [...] } where each member has {member_id, uuid,
# caller_id_number, caller_id_name, join_age_s, is_moderator, talking,
# hold, has_floor}. Empty array if fs_cli missing or no active confs.
# Bridge id is embedded in conf name ("Room-<bridge>" or "Room-<b>-<r>")
# — the server-side mapping happens in bbl-mcp ingest, not here.
CONFERENCES_JSON="[]"
if [ -n "$FS_CLI" ] && [ -x "$FS_CLI" ] && command -v python3 >/dev/null 2>&1; then
  CONF_NAMES=$($FS_CLI -x "conference list count" 2>/dev/null \
              | grep -oE "^\+OK Conference [^ ]+" | awk '{print $3}')
  if [ -n "$CONF_NAMES" ]; then
    CONF_XML_TMP=$(mktemp)
    for _cn in $CONF_NAMES; do
      $FS_CLI -x "conference $_cn xml_list" 2>/dev/null >> "$CONF_XML_TMP"
    done
    _parsed=$(python3 - "$CONF_XML_TMP" <<'PYEOF'
import sys, json, re
import xml.etree.ElementTree as ET
with open(sys.argv[1]) as f:
    raw = f.read()
out = []
for blob in re.findall(r"<conferences>.*?</conferences>", raw, re.DOTALL):
    try:
        root = ET.fromstring(blob)
    except ET.ParseError:
        continue
    for conf in root.findall("conference"):
        members = []
        for m in conf.findall("members/member"):
            if (m.get("type") or "") != "caller":
                continue
            flags = {}
            fl = m.find("flags")
            if fl is not None:
                for f in list(fl):
                    flags[f.tag] = (f.text == "true")
            def gv(tag, default=""):
                el = m.find(tag)
                return el.text if el is not None and el.text is not None else default
            try: ja = int(gv("join_time", "0") or 0)
            except: ja = 0
            members.append({
                "member_id":        gv("id"),
                "uuid":             gv("uuid"),
                "caller_id_number": gv("caller_id_number"),
                "caller_id_name":   gv("caller_id_name"),
                "join_age_s":       ja,
                "is_moderator":     bool(flags.get("is_moderator")),
                "talking":          bool(flags.get("talking")),
                "hold":             bool(flags.get("hold")),
                "has_floor":        bool(flags.get("has_floor")),
            })
        try: rt = int(conf.get("run_time", "0") or 0)
        except: rt = 0
        try: mc = int(conf.get("member-count", "0") or 0)
        except: mc = 0
        # Conference-level boolean flags. mod_conference's xml_list_conferences
        # only emits attributes when set, so an absent "wait_mod" means false.
        # Picking up: wait_mod, locked, recording, running, answered, etc.
        # Drives the [HOLD MUSIC] pill in the dashboard expand panel — when
        # wait_mod is active, every non-moderator hears MOH until a moderator
        # joins.
        conf_flags = {}
        for k, v in conf.attrib.items():
            if v == "true":  conf_flags[k] = True
            elif v == "false": conf_flags[k] = False
        out.append({
            "name":         conf.get("name", ""),
            "uuid":         conf.get("uuid", ""),
            "member_count": mc,
            "run_time_s":   rt,
            "flags":        conf_flags,
            "members":      members,
        })
print(json.dumps(out))
PYEOF
)
    rm -f "$CONF_XML_TMP"
    [ -n "$_parsed" ] && CONFERENCES_JSON="$_parsed"
  fi
fi

# ── Components inventory (auto-detected by path/binary presence) ─────────
# Three sub-maps:
#   git_repos: working copies under known paths (HEAD short SHA, branch,
#              uncommitted file count after filtering noise, last-commit subject)
#   services:  supervisor + systemd units that exist (RUNNING/STOPPED/active)
#   versions:  binary version strings (python/freeswitch/nginx/django)
# All best-effort: missing tools / missing paths just don't show up.
# Output shape: COMPONENTS_JSON = {"git_repos": [...], "services": [...], "versions": {...}}

# Git repos
GIT_REPOS_JSON=""
GIT_PATHS=(
    "/projects/bbl-django:bbl-django"
    "/opt/bblfrontend:bblfrontend"
    "/opt/bbl-esl:bbl-esl"
    "/opt/bbl-monitor:bbl-monitor"
    "/opt/bbl-fs/bbl-fs-build:bbl-fs-build"
    "/opt/bbl-fs/bbl-fs-config:bbl-fs-config"
    "/opt/bbl-fs/bbl-ch-build:bbl-ch-build"
    "/home/gstreet/bbl-mcp:bbl-mcp"
)
for spec in "${GIT_PATHS[@]}"; do
    path="${spec%:*}"
    name="${spec#*:}"
    [ -d "$path/.git" ] || continue
    # safe.directory shim — postgres/freeswitch user dirs may have ownership
    # that would otherwise trip git's dubious-ownership refusal.
    head=$(git -C "$path" -c safe.directory="$path" rev-parse --short HEAD 2>/dev/null)
    branch=$(git -C "$path" -c safe.directory="$path" branch --show-current 2>/dev/null)
    # "Real drift" count: modified tracked files only, excluding common
    # per-host regenerated paths. Untracked files (^??) are usually
    # runtime artifacts (logs, DB caches, etc.) — NOT drift. staticfiles/
    # is regenerated by Django's collectstatic on each host. .bak/.tmp/
    # __pycache__ are workshop debris.
    drift_lines=$(git -C "$path" -c safe.directory="$path" status --porcelain 2>/dev/null \
        | grep -v '^??' \
        | grep -v -E 'staticfiles/|\.bak|__pycache__|\.pyc|\.tmp')
    uncommitted=$(echo "$drift_lines" | grep -c .)
    # Capture up to 20 filenames so the detail page can show "what changed"
    # without exploding the JSON payload size.
    changed_files_json="[]"
    if [ "$uncommitted" -gt 0 ]; then
        files=$(echo "$drift_lines" | head -20 | awk '{
            # git status --porcelain format: 2 status chars + space + filename
            # (renames append " -> newname"). Strip the first 3 chars then
            # take the post-arrow filename if present. Posix awk safe.
            line = substr($0, 4)
            n = index(line, " -> ")
            if (n > 0) line = substr(line, n + 4)
            gsub(/"/, "\\\"", line)
            printf "\"%s\",", line
        }' | sed 's/,$//')
        changed_files_json="[$files]"
    fi
    subject=$(git -C "$path" -c safe.directory="$path" log -1 --format=%s 2>/dev/null \
        | head -c 60 | sed 's/[\\"]/\\&/g')
    behind=0
    if [ -n "$branch" ]; then
        behind=$(git -C "$path" -c safe.directory="$path" rev-list --count "HEAD..origin/$branch" 2>/dev/null)
        [ -z "$behind" ] && behind=0
    fi
    obj="{\"name\":\"$name\",\"path\":\"$path\",\"head\":\"$head\",\"branch\":\"$branch\",\"uncommitted\":$uncommitted,\"behind\":$behind,\"subject\":\"$subject\",\"changed_files\":$changed_files_json}"
    GIT_REPOS_JSON="${GIT_REPOS_JSON}${obj},"
done
GIT_REPOS_JSON="[${GIT_REPOS_JSON%,}]"

# Services (supervisor + systemd)
SERVICES_JSON=""
# supervisor units
if command -v supervisorctl >/dev/null 2>&1; then
    while IFS= read -r line; do
        sv_name=$(echo "$line" | awk '{print $1}')
        sv_status=$(echo "$line" | awk '{print $2}')
        [ -z "$sv_name" ] && continue
        # Filter to BBL-relevant supervisor units
        case "$sv_name" in
            bbl|celery:*|bbl-esl-outbound|bbl-esl-relay)
                obj="{\"name\":\"$sv_name\",\"type\":\"supervisor\",\"status\":\"$sv_status\"}"
                SERVICES_JSON="${SERVICES_JSON}${obj},"
                ;;
        esac
    done < <(supervisorctl status 2>/dev/null)
fi
# systemd units (only check ones we care about)
KNOWN_SYSTEMD=(bbl-monitor bbl-mcp freeswitch nginx postgresql redis-server)
for sv_name in "${KNOWN_SYSTEMD[@]}"; do
    if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^${sv_name}\.service"; then
        sv_status=$(systemctl is-active "$sv_name" 2>/dev/null)
        obj="{\"name\":\"$sv_name\",\"type\":\"systemd\",\"status\":\"$sv_status\"}"
        SERVICES_JSON="${SERVICES_JSON}${obj},"
    fi
done
SERVICES_JSON="[${SERVICES_JSON%,}]"

# ── TLS certs (ACME-managed) ─────────────────────────────────────────────
# Enumerate all certs we can find at canonical paths and emit subject CN +
# notAfter for each. Used by /servers to surface upcoming expiries before
# they fire. Skips FS internal certs (dtls-srtp/wss/tls/cacert) — those
# aren't ACME-managed and don't need expiry tracking.
CERTS_PARTS=""
for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -e "$cert" ] || continue
    cn=$(basename "$(dirname "$cert")")
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -z "$end" ] && continue
    end_iso=$(date -u -d "$end" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    days=$(( ($(date -u -d "$end" +%s) - $(date -u +%s)) / 86400 ))
    obj="{\"cn\":\"$cn\",\"path\":\"$cert\",\"expires\":\"$end_iso\",\"days_left\":$days}"
    CERTS_PARTS="${CERTS_PARTS}${obj},"
done
# acme.sh path used by bbl-fs-build for FS hosts (host's own cert in FS tls dir)
for cert in /etc/freeswitch/tls/*.fullchain.pem; do
    [ -e "$cert" ] || continue
    cn=$(basename "$cert" .fullchain.pem)
    # Skip the FS-internal cert that uses non-FQDN names
    case "$cn" in tls|wss|dtls-srtp|cacert) continue ;; esac
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -z "$end" ] && continue
    end_iso=$(date -u -d "$end" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    days=$(( ($(date -u -d "$end" +%s) - $(date -u +%s)) / 86400 ))
    obj="{\"cn\":\"$cn\",\"path\":\"$cert\",\"expires\":\"$end_iso\",\"days_left\":$days}"
    CERTS_PARTS="${CERTS_PARTS}${obj},"
done
CERTS_JSON="[${CERTS_PARTS%,}]"

# Versions
VERS_PARTS=""
PY_VER=$(python3 --version 2>&1 | awk '{print $2}')
[ -n "$PY_VER" ] && VERS_PARTS="${VERS_PARTS}\"python\":\"$PY_VER\","

if [ -x "$FS_CLI" ]; then
    FS_VER=$($FS_CLI -x "version" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    [ -n "$FS_VER" ] && VERS_PARTS="${VERS_PARTS}\"freeswitch\":\"$FS_VER\","
fi

if command -v nginx >/dev/null 2>&1; then
    NGX_VER=$(nginx -v 2>&1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    [ -n "$NGX_VER" ] && VERS_PARTS="${VERS_PARTS}\"nginx\":\"$NGX_VER\","
fi

# Django (only if a CH-style bbl-django checkout exists)
if [ -d /projects/bbl-django ] && [ -x /projects/bbl_env_py3/bin/python ]; then
    DJ_VER=$(/projects/bbl_env_py3/bin/python -c "import django; print(django.__version__)" 2>/dev/null)
    [ -n "$DJ_VER" ] && VERS_PARTS="${VERS_PARTS}\"django\":\"$DJ_VER\","
fi

VERSIONS_JSON="{${VERS_PARTS%,}}"

COMPONENTS_JSON="{\"git_repos\":$GIT_REPOS_JSON,\"services\":$SERVICES_JSON,\"versions\":$VERSIONS_JSON,\"certs\":$CERTS_JSON}"

PAYLOAD=$(cat <<JSONEOF
{
  "hostname": "$HOSTNAME_VAL",
  "cpu_count": $CPU_COUNT,
  "load_1m": $LOAD1,
  "load_5m": $LOAD5,
  "load_15m": $LOAD15,
  "mem_total_mb": ${MEM_TOTAL:-0},
  "mem_used_mb": ${MEM_USED:-0},
  "mem_free_mb": ${MEM_FREE:-0},
  "mem_pct": ${MEM_PCT:-0},
  "net_iface": "$NET_IFACE",
  "net_rx_bytes": $NET_RX,
  "net_tx_bytes": $NET_TX,
  "disks": $DISKS_JSON,
  "calls_in_progress": $CALLS_IN_PROGRESS,
  "conferences": $CONFERENCES_JSON,
  "components": $COMPONENTS_JSON
}
JSONEOF
)

curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MONITOR_TOKEN" \
  -d "$PAYLOAD" \
  --max-time 10 \
  > /dev/null 2>&1
