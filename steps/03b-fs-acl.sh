#!/bin/bash
# 03b-fs-acl.sh — provision FreeSWITCH event-socket ACL.
#
# Without this, a fresh FS host accepts only loopback ESL connections, so
# ConferencePlay/Mute/Kick/Deaf from lbb-atl (or any external relay) get a
# "rude-rejection: Access Denied, go away." reply at the FS app layer —
# even when the OS-level firewall (06-firewall.sh) opens port 8021.
#
# Idempotent: parses the existing acl.conf.xml with ElementTree, adds any
# missing <node type="allow"> entries to <list name="esl_in">, leaves the
# file alone if all required IPs are already present. Reloads ACL into
# running FS if `fs_cli` is responsive.
#
# Pairs with the matching ufw rules in 06-firewall.sh.

set -euo pipefail

ACL_FILE=/etc/freeswitch/autoload_configs/acl.conf.xml

if [[ ! -f "$ACL_FILE" ]]; then
    echo "==> $ACL_FILE not present yet — skipping (FS not installed?)"
    exit 0
fi

echo "==> Provisioning esl_in ACL in $ACL_FILE"

# IPs that must be in esl_in for BBL to function. Comments are written to
# the XML as <!-- --> trailing siblings so future readers know what each is.
#   50.116.36.14  = lb-atl.bblapp.io  (production LB)
#   50.116.45.69  = lbb-atl.bblapp.io (beta LB)
#   66.228.60.230 = rpt.bblapp.io     (ops box; ad-hoc admin commands)
#   127.0.0.1     = local fs_cli
python3 - "$ACL_FILE" <<'PY'
import sys, xml.etree.ElementTree as ET

acl_file = sys.argv[1]
required = [
    ("127.0.0.1/32",   "local fs_cli"),
    ("50.116.36.14/32",  "lb-atl.bblapp.io"),
    ("50.116.45.69/32",  "lbb-atl.bblapp.io"),
    ("66.228.60.230/32", "rpt.bblapp.io"),
]

tree = ET.parse(acl_file)
root = tree.getroot()

# Find <list name="esl_in"> at any depth
esl_in = None
for lst in root.iter("list"):
    if lst.attrib.get("name") == "esl_in":
        esl_in = lst
        break

if esl_in is None:
    # No esl_in list at all — find the parent <network-list> and add one
    parent = root.find(".//network-list") or root
    esl_in = ET.SubElement(parent, "list", {"name": "esl_in", "default": "deny"})
    print("  created new <list name='esl_in' default='deny'>")

existing = {n.attrib.get("cidr") for n in esl_in.findall("node") if n.attrib.get("type") == "allow"}
added = []
for cidr, label in required:
    if cidr in existing:
        continue
    node = ET.SubElement(esl_in, "node", {"type": "allow", "cidr": cidr})
    # ElementTree won't add a comment with the standard API in this version;
    # rely on the cidr value itself + the README/script for documentation.
    added.append(f"{cidr} ({label})")

if added:
    tree.write(acl_file, encoding="UTF-8", xml_declaration=True)
    print("  added:")
    for a in added:
        print(f"    + {a}")
else:
    print("  no changes — all required IPs already present")
PY

# Reload into running FS if fs_cli is responsive (skip if FS not started yet).
if command -v fs_cli >/dev/null 2>&1 && \
   timeout 3 fs_cli -x "status" >/dev/null 2>&1; then
    echo "==> fs_cli reloadacl"
    fs_cli -x "reloadacl"
else
    echo "==> FS not running — ACL will load on next start"
fi
