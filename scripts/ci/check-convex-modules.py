#!/usr/bin/env python3
"""Reject source paths that Convex's deployment API cannot accept."""
import json
from pathlib import Path
import re
import sys


project = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "convex"
config = json.loads((project / "convex.json").read_text())
functions = project / config.get("functions", "convex")
if not functions.is_dir():
    raise SystemExit(f"Convex functions directory is missing: {functions}")

# Source extensions and exclusions follow the pinned Convex CLI's entry points.
extensions = {".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".jsx"}
invalid = []
checked = 0
for source in sorted(functions.rglob("*")):
    if not source.is_file() or source.suffix not in extensions:
        continue
    relative = source.relative_to(functions)
    if relative.parts[0] == "_generated" or source.name.startswith((".", "#")) or source.name.count(".") > 1:
        continue
    checked += 1
    if any(re.fullmatch(r"[A-Za-z0-9_.]+", component) is None for component in relative.parts):
        invalid.append(str(relative))

if invalid:
    raise SystemExit("Invalid Convex module paths (use letters, numbers, underscores or periods):\n" + "\n".join(invalid))
print(f"Convex module paths: PASS ({checked} source files)")
