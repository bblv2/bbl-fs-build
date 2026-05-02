#!/bin/bash
# 03-fs-config.sh — clone bbl-fs-config and apply its overlay+templates.
#
# Lays down the BBL custom /etc/freeswitch/ on top of the apt-shipped
# vanilla baseline. This step is where the BBL "secret sauce" lands.
set -euo pipefail

if [[ ! -r "$BBL_HOST_CONF" ]]; then
    echo "$0: $BBL_HOST_CONF missing — write it before bbl-fs-build runs" >&2
    echo "    (the linode-cli wrapper writes it at provision time)" >&2
    exit 1
fi

# Validate required vars; auto-discover BBL_EXTERNAL_IP if absent
# shellcheck disable=SC1090
. "$BBL_HOST_CONF"
if [[ -z "${BBL_EXTERNAL_IP:-}" ]]; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
    if [[ -z "$detected" ]]; then
        echo "$0: BBL_EXTERNAL_IP not set in host.conf and auto-detect failed" >&2
        exit 1
    fi
    echo "==> Auto-detected BBL_EXTERNAL_IP=$detected (was blank in host.conf)"
    BBL_EXTERNAL_IP="$detected"
    # Persist back into host.conf so subsequent re-runs see it
    if grep -q '^BBL_EXTERNAL_IP=' "$BBL_HOST_CONF"; then
        sed -i "s|^BBL_EXTERNAL_IP=.*|BBL_EXTERNAL_IP=$detected|" "$BBL_HOST_CONF"
    else
        echo "BBL_EXTERNAL_IP=$detected" >> "$BBL_HOST_CONF"
    fi
    export BBL_EXTERNAL_IP
fi
for var in BBL_EXTERNAL_IP BBL_DOMAIN; do
    [[ -n "${!var:-}" ]] || { echo "$0: $var unset in $BBL_HOST_CONF" >&2; exit 1; }
done

CONFIG_REPO=${BBL_CONFIG_REPO:-git@github.com:bblv2/bbl-fs-config.git}
CONFIG_BRANCH=${BBL_CONFIG_BRANCH:-main}
CONFIG_DIR=/usr/src/bbl-fs-config

echo "==> Acquiring bbl-fs-config"
if [[ -f "$CONFIG_DIR/scripts/apply-config.sh" ]]; then
    # Already present (e.g. rsynced from operator-side via provision.sh,
    # since bbl-fs-config is private and the box has no GitHub SSH key).
    # Try to git pull if the origin is HTTPS and reachable; otherwise
    # use what's there.
    if [[ -d "$CONFIG_DIR/.git" ]]; then
        git -C "$CONFIG_DIR" fetch --quiet 2>/dev/null \
            && git -C "$CONFIG_DIR" reset --quiet --hard "origin/$CONFIG_BRANCH" \
            || echo "    (git fetch failed — using existing checkout as-is)"
    else
        echo "    using existing checkout (no .git, no remote sync attempted)"
    fi
else
    echo "==> Cloning bbl-fs-config from $CONFIG_REPO"
    git clone --quiet --branch "$CONFIG_BRANCH" "$CONFIG_REPO" "$CONFIG_DIR"
fi

echo "==> Lay down apt-shipped vanilla baseline"
# /etc/freeswitch is created by `apt install freeswitch` but mostly empty.
# The vanilla flavor is at /usr/share/freeswitch/conf/vanilla/.
if [[ ! -f /etc/freeswitch/freeswitch.xml ]]; then
    if [[ -d /usr/share/freeswitch/conf/vanilla ]]; then
        cp -a /usr/share/freeswitch/conf/vanilla/. /etc/freeswitch/
    else
        echo "$0: no vanilla flavor in /usr/share/freeswitch/conf/ — install freeswitch-conf-vanilla" >&2
        exit 1
    fi
fi

echo "==> Apply BBL overlay + render templates"
"$CONFIG_DIR/scripts/apply-config.sh" "$BBL_HOST_CONF"

# Remove vanilla sip_profiles BBL doesn't use. Both bind to the same
# port range as BBL's external/client profiles and cause sofia
# 'Address already in use' errors on FS 1.10.12+. fs-atl tolerated
# them on 1.10.8 because vars.xml's $${internal_sip_port} was
# undefined (silent skip); newer FS treats undefined as 5060 and
# clashes with external. Cleanest fix: just drop them — BBL uses
# external + client only.
echo "==> Removing vestigial vanilla sip_profiles (internal, external-ipv6)"
rm -f /etc/freeswitch/sip_profiles/internal.xml \
      /etc/freeswitch/sip_profiles/external-ipv6.xml

# CA bundle for mod_http_cache HTTPS downloads. http_cache.conf.xml
# references $${certs_dir}/cacert.pem (resolves to /etc/freeswitch/tls/
# cacert.pem). Without this file, every HTTPS GetDigits/playback URL
# silently fails the TLS verify and the prompt is inaudible — the call
# proceeds but callers hear nothing during welcome/PIN prompts.
#
# Symlink to the system bundle (managed by the ca-certificates package,
# refreshed by OS updates) instead of fetching a stale snapshot.
echo "==> Wiring CA bundle for mod_http_cache HTTPS"
install -d -o freeswitch -g freeswitch -m 750 /etc/freeswitch/tls
ln -sf /etc/ssl/certs/ca-certificates.crt /etc/freeswitch/tls/cacert.pem
chown -h freeswitch:freeswitch /etc/freeswitch/tls/cacert.pem

# mod_http_cache writes downloaded files into /var/cache/freeswitch but
# does NOT create the dir if missing — it just logs 'open() error: No
# such file or directory' on every URL fetch. apt-installed FS doesn't
# pre-create this dir.
echo "==> Creating mod_http_cache cache dir"
install -d -o freeswitch -g freeswitch -m 750 /var/cache/freeswitch

echo "==> Restart FreeSWITCH so systemd drop-in (script_dir, -rp) takes effect"
systemctl daemon-reload
systemctl enable freeswitch
systemctl restart freeswitch

# Wait for FS to come up cleanly
echo "==> Waiting up to 30s for FreeSWITCH to accept fs_cli"
for _ in $(seq 1 30); do
    if fs_cli -x 'status' >/dev/null 2>&1; then
        echo "==> FreeSWITCH is up:"
        fs_cli -x 'status' | head -5
        break
    fi
    sleep 1
done
fs_cli -x 'status' >/dev/null 2>&1 \
    || { echo "$0: FreeSWITCH failed to start — check journalctl -u freeswitch" >&2; exit 1; }

echo "==> 03-fs-config.sh complete"
