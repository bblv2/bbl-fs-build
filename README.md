# bbl-fs-build

Provisioning script for BBL FreeSWITCH boxes on Linode. Pairs with [`bbl-fs-config`](https://github.com/bblv2/bbl-fs-config) (the BBL FreeSWITCH overlay).

## Goals

- **Cheap and disposable.** Spin up a new FS box in ~5 minutes; tear it down in 30 seconds. No bespoke per-host snowflakes.
- **Portable.** Plain shell + cloud-init `user_data`, not Linode StackScripts. The same scripts could provision on AWS, Hetzner, or bare metal with minor adjustments.
- **Minimal.** Curated FS apt module set (~16 packages, not `meta-all`'s 60+). Only US English sounds. No `freeswitch-conf-vanilla` (we lay our own conf).
- **Auditable.** Every box writes `/etc/bbl-fs-build` recording exactly what it was built from (build commit, config commit, FS version, kernel, build time).
- **Self-securing.** `ufw` opens only what's used. fail2ban watches FS log. acme.sh issues + auto-renews TLS. B2 push for QC recordings.

## Sizes

```
small   g6-standard-2     2c  4G   $24/mo   ~50 callers   dev/staging
medium  g6-dedicated-4    4c  8G   $72/mo   ~200          mid-size prod
large   g6-dedicated-8    8c 16G   $144/mo  ~600          full prod (proven by fs-atl)
xlarge  g6-dedicated-16  16c 32G   $288/mo  ~1200         headroom / future-prod
```

Capacity numbers are empirical from the 2026-05-01 overnight load battery; re-validate against the regression suite when bumping FS versions.

## Provisioning a new box

```bash
# 1. Prerequisites (one-time on operator's machine)
brew install linode-cli jq         # macOS
linode-cli configure                # paste API token
cp host.conf.example /tmp/fs-beta-1.host.conf
$EDITOR /tmp/fs-beta-1.host.conf    # fill in BBL_EXTERNAL_IP, BBL_DOMAIN, secrets

# 2. Provision
./scripts/provision.sh \
    role=beta \
    size=small \
    hostname=fs-beta-1.bblapp.io \
    host-conf=/tmp/fs-beta-1.host.conf

# 3. Wait 5 min, tail /var/log/bbl-fs-build.log on the new box if you want
ssh root@<linode-ip> tail -f /var/log/bbl-fs-build.log
```

The provision script will print:
- The new Linode's public IPv4 (you'll need this for DNS)
- Root password (Linode does not store it; write it down)
- `/etc/bbl-fs-build` summary once cloud-init finishes

## What the build does (steps in order)

```
01-base.sh          OS hardening: apt update, debug tools, haveged, chrony,
                    locale=en_US, timezone=UTC, sysctls for high-RTP load,
                    fail2ban with FS jail, SignalWire apt repo
02-fs-install.sh    apt-install ~16 curated FS packages (see conf/fs-packages.conf)
03-fs-config.sh     Clone bbl-fs-config, lay vanilla baseline, apply BBL overlay,
                    render templates, restart freeswitch with systemd drop-in
04-cert.sh          acme.sh + Let's Encrypt cert; reload hook concatenates
                    key+fullchain into /etc/freeswitch/tls/wss.pem and reloads
                    the sofia client profile
05-recordings-cron  rclone config from B2 creds, smoke-test bucket, install
                    nightly /etc/cron.d push job + logrotate
06-firewall.sh      ufw rules: SSH/SIP/RTP/WSS only; everything else dropped
07-finalize.sh      Write /etc/bbl-fs-build, render motd, sanity checks
```

Each step is small and idempotent — safe to re-run after a failure. Logs go to `/var/log/bbl-fs-build.log` via `tee` from `bootstrap.sh`.

## Security

- `host.conf` is **never committed**. `.gitignore` blocks it. The example file (`host.conf.example`) shows what fields exist with empty values.
- B2 credentials live in `/etc/bbl-fs-host.conf` (mode 600) and `/root/.config/rclone/rclone.conf` (mode 600). Nowhere else on disk.
- SignalWire token similarly only on the box that needs it.
- `ufw` is configured with deny-by-default inbound. Linode Cloud Firewall (if you attach one to the instance) is the outer perimeter; `ufw` is OS-level defense in depth.
- TLS via Let's Encrypt + acme.sh. ECDSA p-256 keys (smaller, faster, modern).
- fail2ban watches FreeSWITCH log for SIP auth failures and call rejections; bans for 24h after 5 failed attempts in 5 min.

## Tearing down

```bash
./scripts/teardown.sh hostname=fs-beta-1.bblapp.io --confirm
```

Drains FreeSWITCH (waits for active calls), snapshots the disk (30-day retention by default), then deletes the Linode. `--no-snapshot` skips the snapshot if you really don't want it.

## Re-provisioning the same box

If a Linode dies or you want to bump it to a new FS version:

```bash
./scripts/teardown.sh hostname=fs-atl.bblapp.io --confirm
./scripts/provision.sh role=prod size=large hostname=fs-atl.bblapp.io host-conf=/secure/fs-atl.host.conf
```

If you've reserved a Linode Floating IP for the host's public IPv4 and assign it after provision, DNS doesn't need to change.

## Updating an existing box

For config changes:

```bash
ssh root@fs-atl.bblapp.io 'cd /usr/src/bbl-fs-config && git pull && ./scripts/apply-config.sh /etc/bbl-fs-host.conf && fs_cli -x reloadxml'
```

For build-script changes (rare — touches OS-level state):

```bash
ssh root@fs-atl.bblapp.io 'cd /usr/src/bbl-fs-build && git pull && ./setup.sh role=prod size=large hostname=fs-atl.bblapp.io'
```

Steps are idempotent so re-running is safe.

## Repository layout

```
bootstrap.sh             # 15-line user_data: clones repo + runs setup.sh
setup.sh                 # orchestrator: parses args, dispatches to steps/
conf/
  linode-sizes.conf      # size name → Linode SKU mapping
  fs-packages.conf       # apt module list (curated, not meta-all)
steps/                   # idempotent installation steps, run in numeric order
  01-base.sh
  02-fs-install.sh
  03-fs-config.sh
  04-cert.sh
  05-recordings-cron.sh
  06-firewall.sh
  07-finalize.sh
templates/               # rendered files (rclone.conf, cron, motd, push script)
scripts/                 # local-side helpers
  provision.sh           # linode-cli wrapper to create a new box
  teardown.sh            # drain + snapshot + delete
host.conf.example        # operator copies + fills in
```
