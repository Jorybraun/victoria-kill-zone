#!/usr/bin/env python3
"""Render actual SwiftUI entry/lobby source against an existing native build.

This does not run SwiftPM or mutate app sources. It requires a current successful
macOS SwiftPM build so internal production dependencies can be linked.
"""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
build = root / "ios/VictoriaKillZone/.build/arm64-apple-macosx/debug"
hud = "--combat-hud" in sys.argv[1:]
output = root / ("design/evidence/009-gameplay-visibility" if hud else "design/evidence/007-gameplay-ui")
sources = [root / "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/ActiveDuelView.swift"] if hud else [
    root / "ios/VictoriaKillZone/VictoriaKillZone/Features/Home/HomeView.swift",
    root / "ios/VictoriaKillZone/VictoriaKillZone/Features/Lobby/WaitingRoomView.swift",
]
objects_file = build / "VictoriaKillZoneDomainPackageTests.product/Objects.LinkFileList"
if not objects_file.exists():
    raise SystemExit("A successful existing macOS SwiftPM build is required; this harness never starts one.")
objects = [path for path in shlex.split(objects_file.read_text()) if "/VictoriaKillZoneTests.build/" not in path
           and "/VictoriaKillZoneDomainPackageTests.build/" not in path
           and "/VictoriaKillZoneDomainPackageDiscoveredTests.build/" not in path]
env = dict(os.environ)
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="vkz-gameplay-preview-") as temporary:
    task_build = Path(temporary)
    copies = []
    for source in sources:
        copy = task_build / source.name
        copy.write_text("@testable import VictoriaKillZone\n" + source.read_text())
        copies.append(str(copy))
    arguments = ["-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
                 "-module-cache-path", str(task_build / "modules"), "-I", str(build / "Modules"),
                 "-I", str(root / "ios/VictoriaKillZone/.build/checkouts/convex-swift/libconvexmobile-rs.xcframework/macos-arm64/Headers"),
                 "-L", str(build), "-lconvexmobile", "-framework", "AppKit", "-framework", "Security",
                 "-framework", "SystemConfiguration", *copies, str(Path(__file__).with_name("HUDPreview.swift" if hud else "Preview.swift")),
                 *objects, "-o", str(task_build / "preview")]
    response = task_build / "compile.args"
    response.write_text("\n".join(shlex.quote(value) for value in arguments))
    compiled = subprocess.run(["xcrun", "swiftc", "@" + str(response)], env=env, capture_output=True, text=True)
    (output / "build.log").write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        raise SystemExit(f"Native preview compilation failed; see {output / 'build.log'}")
    subprocess.run([str(task_build / "preview"), str(output)], check=True, env=env)

manifest = {
    "kind": "Actual SwiftUI components in synthetic macOS phone-sized viewports",
    "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    "supportingModuleSHA256": hashlib.sha256((build / "Modules/VictoriaKillZone.swiftmodule").read_bytes()).hexdigest(),
    "sourcePreparation": "Unmodified current component sources with @testable import prepended, linked against existing production dependencies",
    "fixtures": "Classic duel, health 100, opponent health 60, ammo 8, K/D 3/3, 42 seconds; synthetic searching tracker, no networking" if hud else "Synthetic callsign Alex; host Alex; guest Riley, guest Morgan, guest Alexandria North; defined ready/disconnected states",
    "viewportPoints": [[375, 667], [393, 852]] if hud else [375, 667],
    "renderer": "Offscreen NSHostingView cacheDisplay including native ScrollView and TextField",
    "dynamicTypeCases": ["large", "xxxLarge (macOS font metrics differ from iOS)"] if hud else ["large", "accessibility3 (layout branch; macOS font metrics differ from iOS)"],
    "limitations": ["Not an iPhone screenshot", "macOS SwiftUI platform rendering; UIKit-only QR and clipboard controls excluded",
                    "No touch, keyboard, VoiceOver, networking, permissions, or camera acceptance", "Bottom views use programmatic native scrolling, not a touch gesture"],
    "PNGs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.glob("*.png"))},
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
