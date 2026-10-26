#!/usr/bin/env python3
"""Regenerate the two SwiftPM entrypoints from the fork's maintained template."""
import argparse
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
template = (root / "LakeOfFire/Package.template.swift").read_text()
sources = json.loads((root / "LakeOfFire/package-sources.json").read_text())
retained = set(sources + ["LakeOfFire/Resources/PrivacyInfo.xcprivacy"])
# Enumerate repository inputs at regeneration time, never at manifest evaluation
# time. Ignored build/cache files must not make generated manifests unstable.
files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
files = {path for path in files if path and not path.startswith(".") and (root / path).exists()}

def exclusions(prefix=""):
    children = sorted({path[len(prefix):].split("/")[0] for path in files if path.startswith(prefix)})
    result = []
    for child in children:
        path = prefix + child
        if path in retained:
            continue
        if any(source.startswith(path + "/") for source in retained):
            result.extend(exclusions(path + "/"))
        else:
            result.append(path)
    return result

template = template.replace("@SOURCES@", json.dumps(sources, indent=4, ensure_ascii=False))
template = template.replace("@EXCLUDED@", json.dumps(exclusions(), indent=4, ensure_ascii=False))
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
