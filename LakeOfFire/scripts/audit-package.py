#!/usr/bin/env python3
"""Check SwiftPM's actual product graph against the maintained source boundary."""
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
graph = json.load(sys.stdin)
products = graph["products"]
assert len(products) == 1 and products[0]["name"] == "PostHogEvents", products
targets = {target["name"]: target for target in graph["targets"]}
assert set(targets) == {"PostHogEvents", "PostHogEventsTests"}, set(targets)
core = targets["PostHogEvents"]
expected = set(json.loads((root / "LakeOfFire/package-sources.json").read_text()))
assert set(core["sources"]) == expected, (set(core["sources"]) - expected, expected - set(core["sources"]))
assert not core.get("target_dependencies") and not core.get("product_dependencies"), core
assert not graph.get("dependencies"), graph.get("dependencies")
assert core["type"] == "library", core["type"]
allowed_imports = {"Foundation", "CoreGraphics", "Security"}
for relative in expected:
    source = (root / relative).read_text()
    modules = set(re.findall(r"^\s*import\s+(\w+)", source, re.MULTILINE))
    assert modules <= allowed_imports, (relative, modules - allowed_imports)
    # Architectural lint, separate from behavior tests. These dynamic entry
    # points have no purpose in a Foundation-only event uploader.
    assert not re.search(r"\b(?:NSClassFromString|NSSelectorFromString|Selector|dlsym|dlopen|method_exchangeImplementations)\s*\(", source), relative
print(f"PostHogEvents: {len(expected)} admitted Swift files, no external dependencies or optional SDK targets")
