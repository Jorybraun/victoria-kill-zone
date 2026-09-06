# V2 digital verification

Observed September 6, 2026. This is an unprinted fabrication fit prototype.

CAD source SHA-256: `1337cc126e87ef383a32f1e9c192811fedd0727c388b0edd38951b716b84ff43`.

The generator reloaded all 12 STL types as watertight, consistently wound, single connected solids with positive volume. Default assembly is 77 × 155 × 11 mm. Separate CAD regenerations also passed for 65 × 140 × 7 mm and 90 × 170 × 17 mm phone/case envelopes, then the default was restored.

The default manifest records 21 plastic-pair checks, 84 phone/switch exclusion checks, 161 hardware-envelope checks and 165 bolt-head/nut insertion checks. An independent read-only review also checked all 15 bolt insertion paths and jaw clearance at 65 and 90 mm widths. Modeled head diameter is 5.7 mm; this does not test actual screwdriver handles.

`python previews/audit_print_geometry.py` independently reloaded all 12 STLs and confirmed flat bed contact, positive solids and per-part bounds within 180 mm. Maximum build height is 42 mm. The audit reports downward-facing surface area for slicer inspection; it does not certify support-free printing.

The four-page fabrication PDF was visually inspected for labels, clipping and assembly-order consistency. The GLB export script reloaded both viewing files and checked their geometry bounds in metres. The packaged ZIP passed its integrity check and contains 12 STL types, two GLBs, the PDF, source and instructions.

`pnpm verify` passed on the final implementation: workspace lint, type checks, tests and builds, including the newer combat packages merged into the branch. The combat test server requires localhost access; the initial sandboxed run stopped with EPERM, and the full check was rerun with that access. `git diff --check` passed. The draft PR identifies the committed revision for review.

No physical print, named printer test, hardware insertion by hand, load/impact/retention test, electronics connection or physical-device game firing was performed. Start with the coupon and button plate, then a dummy phone. Physical evidence is still required before claiming compatibility or performance.
