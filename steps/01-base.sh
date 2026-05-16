#!/bin/bash
# 01-base.sh — OS-level setup before any FreeSWITCH stuff.
#
# - APT keyring + signalwire repo
# - Common packages (debug tools, time/entropy daemons, certbot prereqs)
# - Locale + timezone (UTC)
# - Sysctls for high-RTP load
# - fail2ban with FreeSWITCH-aware jails
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + base packages"
apt-get update -q
apt-get install -y -q \
    curl gnupg lsb-release ca-certificates apt-transport-https \
    git rsync \
    chrony haveged \
    fail2ban ufw \
    rclone \
    sngrep tcpdump dnsutils net-tools jq \
    cron logrotate

echo "==> Locale + timezone"
timedatectl set-timezone UTC
sed -i '/^# en_US.UTF-8/s/^# //' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8

echo "==> Entropy + NTP"
systemctl enable --now haveged
systemctl enable --now chrony

echo "==> SignalWire FreeSWITCH apt repo (deb12 / bookworm)"
# SignalWire requires a Personal Access Token (free) to access their
# bookworm repos. The "open" files.freeswitch.org repo no longer
# serves Debian 12 — they consolidated everything behind auth ~2022.
# Get a token at https://signalwire.com/ → Personal Access Tokens.
if [[ -r /etc/bbl-fs-host.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/bbl-fs-host.conf
fi
if [[ -z "${BBL_SIGNALWIRE_TOKEN:-}" ]]; then
    echo "FATAL: BBL_SIGNALWIRE_TOKEN unset" >&2
    echo "       Required for FreeSWITCH apt access on Debian 12." >&2
    echo "       Get one at https://signalwire.com → Personal Access Tokens" >&2
    echo "       Then add BBL_SIGNALWIRE_TOKEN=pat_... to host.conf" >&2
    exit 1
fi
install -d -m 755 /etc/apt/auth.conf.d
cat > /etc/apt/auth.conf.d/freeswitch.conf <<EOF
machine freeswitch.signalwire.com
login signalwire
password ${BBL_SIGNALWIRE_TOKEN}
EOF
chmod 600 /etc/apt/auth.conf.d/freeswitch.conf
curl -fsSL --user "signalwire:${BBL_SIGNALWIRE_TOKEN}" \
    https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg \
    | gpg --dearmor > /etc/apt/keyrings/signalwire.gpg
echo "deb [signed-by=/etc/apt/keyrings/signalwire.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ bookworm main" \
    > /etc/apt/sources.list.d/freeswitch.list
apt-get update -q

echo "==> Kernel sysctls for high-RTP load"
cat > /etc/sysctl.d/99-bbl-fs.conf <<'EOF'
# Larger UDP receive/send buffers for RTP under load
net.core.rmem_max     = 33554432
net.core.wmem_max     = 33554432
net.core.rmem_default =   262144
net.core.wmem_default =   262144
net.ipv4.udp_mem      = 4096 87380 33554432
# Larger conntrack table for high-volume call workloads
net.netfilter.nf_conntrack_max = 524288
# More backlog for SIP signaling bursts
net.core.somaxconn    = 4096
net.core.netdev_max_backlog = 16384
# Disable rp_filter on FS hosts (asymmetric routing common with SIP)
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -q --system

echo "==> File-descriptor limit (FS handles tens of thousands of sockets)"
cat > /etc/security/limits.d/99-bbl-fs.conf <<'EOF'
*  soft  nofile  1048576
*  hard  nofile  1048576
EOF

echo "==> CPU governor → performance"
if command -v cpupower >/dev/null; then
    cpupower frequency-set -g performance >/dev/null 2>&1 || true
fi

echo "==> fail2ban: SSH + FreeSWITCH jails (mirror of fs-atl reference config)"
# Use the upstream `freeswitch` filter that ships with the fail2ban package
# (works at fs-atl). Earlier provisions wrote a custom freeswitch-bbl filter
# that was narrower and started before /var/log/freeswitch existed; the
# service ended up in `failed` state on every new box. Replace with an
# explicit jail.local, ensure the FS logfile path exists pre-FS-install,
# and start the service unconditionally.
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
bantime  = 86400
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 168.227.227.0/24

[freeswitch]
enabled   = true
mode      = extra
filter    = freeswitch
logpath   = /var/log/freeswitch/freeswitch.log
maxretry  = 5
findtime  = 60
bantime   = 86400
protocol  = udp
port      = 5060,5061,5080,5081
action    = nftables-multiport[name=freeswitch, port="5060,5061,5080,5081", protocol=udp]
ignoreip  = 127.0.0.1/8 192.76.120.0/24 64.16.224.0/19 64.16.250.10/32 192.76.120.31/32

# Catch SIP scanners that get rejected by FreeSWITCH ACL before they ever
# reach auth (sofia.c:NNNN "Rejected by acl"). The stock `freeswitch` filter
# above only matches sofia_reg.c auth failures, so high-volume pre-auth
# scanners (e.g. 37.187.144.149-style probing) slip through. 7h bantime
# while we verify it doesn't catch legitimate traffic — bump later if clean.
[freeswitch-acl]
enabled   = true
filter    = freeswitch-acl
logpath   = /var/log/freeswitch/freeswitch.log
maxretry  = 5
findtime  = 300
bantime   = 25200
protocol  = udp
port      = 5060,5061,5080,5081
action    = nftables-multiport[name=freeswitch-acl, port="5060,5061,5080,5081", protocol=udp]
ignoreip  = 127.0.0.1/8 192.76.120.0/24 64.16.224.0/19 64.16.250.10/32 192.76.120.31/32

# Re-ban offenders that earn 5 separate bans in 24h with a blanket all-ports
# block. Conservative 7h bantime to match freeswitch-acl; revisit once we
# confirm no self-bans.
[recidive]
enabled   = true
bantime   = 25200
findtime  = 86400
maxretry  = 5
EOF

# freeswitch-acl filter: matches FS ACL rejections (pre-auth scan traffic).
# Log line format:
#   2026-05-11 19:24:15.643439 100.00% [WARNING] sofia.c:10667 IP 1.2.3.4 Rejected by acl "all_deny"
cat > /etc/fail2ban/filter.d/freeswitch-acl.conf <<'EOF'
[INCLUDES]
before = common.conf

[Definition]
_daemon = freeswitch
failregex = ^.*\[WARN(?:ING)?\]\s+sofia\.c:\d+\s+IP\s+<HOST>\s+Rejected by acl\s+"[^"]*"\s*$
ignoreregex =
datepattern = ^%%Y-%%m-%%d[ T]%%H:%%M:%%S(?:\.%%f)?
EOF

# Patch the upstream `freeswitch` filter's _pref_line to tolerate the
# CPU-usage token FS emits between the timestamp and `[WARNING]` (e.g.
# " 87.77%"). Without this, the stock prefregex matches zero lines on
# current FS builds and the jail is silently dead — discovered after a
# 172k-probe toll-fraud scan ran 10h unhindered on fs-atl28 (2026-05-15).
# Idempotent: only adds the trailing `(?:\s+\d+(?:\.\d+)?%%)?` once.
if [ -f /etc/fail2ban/filter.d/freeswitch.conf ] \
   && ! grep -q '\\.\\\\d+)?%%)' /etc/fail2ban/filter.d/freeswitch.conf; then
    sed -i -E 's|(_pref_line = \^%\(__prefix_line\)s\(\?:\(\?:\\d\+-\)\?\\d\+-\\d\+ \\d\+:\\d\+:\\d\+\\\.\\d\+\)\?)$|\1(?:\\s+\\d+(?:\\.\\d+)?%%)?|' \
        /etc/fail2ban/filter.d/freeswitch.conf
fi

# Drop any prior bbl-build provisional jail/filter (older provisions wrote
# /etc/fail2ban/{jail.d,filter.d}/freeswitch-bbl.conf — supplanted by the
# upstream `freeswitch` filter referenced above).
rm -f /etc/fail2ban/jail.d/freeswitch-bbl.conf \
      /etc/fail2ban/filter.d/freeswitch-bbl.conf

# Pre-create the FS log path so the freeswitch jail starts cleanly on first
# boot, before step 02 installs FreeSWITCH. fail2ban won't error on an
# existing-but-empty logfile.
install -d -m 0755 /var/log/freeswitch
touch /var/log/freeswitch/freeswitch.log

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "==> 01-base.sh complete"
