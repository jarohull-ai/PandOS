#!/usr/bin/env python3
"""Embed provision.sh into user_configuration.json's custom_commands field.

provision.sh is the single, human-readable source of truth for the
provisioning script archinstall runs via custom_commands. Before this
script existed, the same text was hand-duplicated into four places (two
user_configuration.json copies plus two now-dead provision.sh mirrors)
and they drifted the first time one of them got edited alone - the
PandaCode version-pin fix landed in the JSON but not in either
provision.sh copy. Run this after editing provision.sh; never hand-edit
custom_commands in a JSON file directly.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROVISION = ROOT / "provision.sh"
TARGETS = [
    ROOT / "user_configuration.json",
    ROOT.parent / "pandos-iso/configs/pandos/airootfs/root/pandos/user_configuration.json",
]


def main() -> int:
    if not PROVISION.is_file():
        print(f"error: {PROVISION} not found", file=sys.stderr)
        return 1

    script = PROVISION.read_text()

    for path in TARGETS:
        if not path.is_file():
            print(f"error: {path} not found", file=sys.stderr)
            return 1
        cfg = json.loads(path.read_text())
        cfg["custom_commands"] = [script]
        path.write_text(json.dumps(cfg, indent=2))
        print(f"synced {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
