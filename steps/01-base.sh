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

echo "==> fail2ban for FreeSWITCH (after FS is configured, the jail starts)"
# We install the jail config now but don't enable until step 03 finishes
# laying down /var/log/freeswitch (jail filter reads that).
cat > /etc/fail2ban/filter.d/freeswitch-bbl.conf <<'EOF'
[Definition]
failregex = ^.*\[WARNING\] sofia_reg\.c:.*SIP auth (failure|challenge) \(REGISTER\) on sofia profile.*from <sip:[^@]*@<HOST>>.*$
            ^.*\[WARNING\] sofia\.c:.*Hangup .* \[CALL_REJECTED\].*from <HOST>.*$
ignoreregex =
EOF
cat > /etc/fail2ban/jail.d/freeswitch-bbl.conf <<'EOF'
[freeswitch-bbl]
enabled  = true
port     = 5060,5061,5080,5081,7443
filter   = freeswitch-bbl
logpath  = /var/log/freeswitch/freeswitch.log
maxretry = 5
findtime = 300
bantime  = 86400
EOF

echo "==> 01-base.sh complete"
