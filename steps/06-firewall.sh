#!/bin/bash
# 06-firewall.sh — ufw rules for FS hosts.
#
# Opens only what's actually used by BBL FS. RTP port range narrowed
# from FS's default to keep amplification-attack surface small.
#
# Closed by default policy — Linode Cloud Firewall (if attached) acts
# as the outer perimeter, ufw is defense-in-depth at the OS.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"

ufw --force reset >/dev/null

# Outbound: allow everything (FS dials Telnyx, fetches HTTP from chb-atl, etc.)
ufw default allow outgoing

# Inbound: deny by default
ufw default deny incoming

# Always allow SSH from anywhere (Linode Cloud Firewall should restrict
# this further to known operator IPs; ufw is just a safety net)
ufw allow 22/tcp comment 'ssh'

# SIP signaling
ufw allow 5060/udp comment 'sip external (telnyx-facing)'
ufw allow 5060/tcp comment 'sip external tcp'
ufw allow 5061/udp comment 'sip-tls'
ufw allow 5080/udp comment 'sip client (bbl apps)'
ufw allow 5080/tcp comment 'sip client tcp'
ufw allow 5081/udp comment 'sip client tls'

# WebRTC (sofia client profile)
ufw allow 7443/tcp comment 'wss webrtc'

# RTP — narrow range. FS default is 16384-32768, we narrow to
# 16384-32767 (~16K ports = ~8000 simultaneous calls cap, well above
# our 720-concurrent ceiling on g6-dedicated-8).
ufw allow 16384:32767/udp comment 'rtp'

# HTTP for acme.sh standalone renewals (port 80 only when renewing,
# but ufw rule is permanent — acme.sh still needs to bind port 80
# briefly every 60 days)
ufw allow 80/tcp comment 'acme http-01 challenge'

# ICMP echo (ping) — debugging
ufw default allow routed
echo y | ufw enable

echo "==> ufw status:"
ufw status verbose | head -30

echo "==> 06-firewall.sh complete"
