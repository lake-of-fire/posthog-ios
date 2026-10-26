#!/usr/bin/env python3
"""Regenerate the two SwiftPM entrypoints from the fork's maintained template."""
import argparse
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
template = (root / "LakeOfFire/Package.template.swift").read_text()
for name, tools, vision in [("Package.swift", "5.3", ""), ("Package@swift-5.9.swift", "5.9", ", .visionOS(.v1)")]:
    target = root / name
    if target.resolve() != target:
        raise SystemExit(f"Refusing redirected manifest: {target}")
    expected = template.replace("@TOOLS@", tools).replace("@VISION@", vision)
    if args.check:
        if target.read_text() != expected:
            raise SystemExit(f"Regenerate {name}: python3 LakeOfFire/scripts/render-manifests.py")
    else:
        target.write_text(expected)
