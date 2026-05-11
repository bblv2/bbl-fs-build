# Per-host FS overrides (non-secret)

One file per host, named `<short>.conf`. Read by `scripts/provision.sh`
*after* `seeds/defaults.conf` to encode known fleet-level routing
decisions that diverge from defaults.

Rules:
- Only **non-secret** values. (FS-side secrets are short list anyway:
  SignalWire token, B2 app key — both cluster-wide.)
- Hosts that exactly match `defaults.conf` do not need a file here.
- `BBL_DOMAIN` is auto-set by `provision.sh` from the `hostname=`
  argument — do not duplicate it.
- register.py output (BBL_TELNYX_CONNECTION_ID, BBL_TEST_DID,
  BBL_TEST_FS_SETUP_ID, etc.) is post-provision runtime state and
  must NOT be committed here — it's written to /etc/bbl-fs-host.conf
  on the running box by register.py after Telnyx registration.

Current fleet snapshot:

| Short host       | Override                                          |
|------------------|---------------------------------------------------|
| fsb-atl1         | ESL outbound → lbb-atl (50.116.45.69)             |
| fs-atl20–24      | (defaults — lb-atl ESL)                           |
| fsb-atl15–19     | (defaults — lb-atl ESL; pre-PG-migration)         |
| fs-test-*        | (defaults; register.py output lives on-host)      |
