#!/usr/bin/env python3
"""Fail when the native project silently omits app/test sources or repeats IDs."""
from collections import Counter
import json
from pathlib import Path
import re
import subprocess


root = Path(__file__).resolve().parents[2] / "ios/VictoriaKillZone"
project = root / "VictoriaKillZone.xcodeproj/project.pbxproj"
text = project.read_text()
ids = re.findall(r"^\t\t([A-Z0-9]{24}) /\*.*\*/ = ", text, re.MULTILINE)
duplicates = [key for key, count in Counter(ids).items() if count > 1]
if duplicates:
    raise SystemExit("Duplicate Xcode object IDs: " + ", ".join(duplicates))
objects = json.loads(subprocess.check_output(
    ["plutil", "-convert", "json", "-o", "-", str(project)]
))["objects"]
parents = {}
for key, value in objects.items():
    if value["isa"] == "PBXGroup":
        for child in value.get("children", []):
            if child in parents:
                raise SystemExit("Xcode item has multiple parent groups: " + child)
            parents[child] = key


def location(key):
    value = objects[key]
    tree = value.get("sourceTree", "<group>")
    if tree == "SOURCE_ROOT":
        base = root
    elif tree == "<group>":
        base = location(parents[key]) if key in parents else root
    else:
        raise SystemExit("Unsupported source tree for local source: " + tree)
    return (base / value.get("path", "")).resolve()


for name in ("VictoriaKillZone", "VictoriaKillZoneTests"):
    target = next(v for v in objects.values() if v["isa"] == "PBXNativeTarget" and v["name"] == name)
    compiled = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != "PBXSourcesBuildPhase":
            continue
        for build_id in phase["files"]:
            compiled.append(location(objects[build_id]["fileRef"]))
    expected = {p.resolve() for p in (root / name).rglob("*.swift")}
    missing, extra = expected - set(compiled), set(compiled) - expected
    repeated = [str(p.relative_to(root)) for p, count in Counter(compiled).items() if count > 1]
    if missing or extra or repeated:
        details = [f"{name} source membership differs from its source tree."]
        details += ["Missing: " + str(p.relative_to(root)) for p in sorted(missing)]
        details += ["Unexpected: " + str(p) for p in sorted(extra)]
        details += ["Repeated: " + p for p in repeated]
        raise SystemExit("\n".join(details))
    print(f"Xcode source membership: {name} PASS ({len(compiled)} files)")
