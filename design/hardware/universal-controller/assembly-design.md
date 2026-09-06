# V2 fabrication and assembly design

Status: original mechanical fit prototype. Units: millimetres. The drawing set and source are for a brightly coloured arcade phone controller. The purchased button sends no game input until electronics and app integration are implemented.

## What changed for printing

The earlier one-piece grip/cradle/nose was a shape study. V2 uses two hollow housing halves, a separate phone dock, a separate closed nose cap and a removable switch plate. The jaws and spacer system remain separate. Each part has its own print orientation and locating/fastening interface. This separation is intended to reduce broad supports, let the interiors print open, and allow repair without replacing the complete body.

Use only the v2 parts from one generation. The old `grip_cradle.stl` and `grip_cover.stl` are obsolete. The M4 jaw bolts and self-tapping cover screws from v1 are also obsolete: v2 uses M3 through-bolts and captive hex nuts.

## Part numbering and drawings

Open [fabrication-guide.pdf](previews/fabrication-guide.pdf) for the numbered exploded assembly, individual print files, overall views and build sequence. The authoritative IDs, transformations, nominal dimensions, pocket geometry, bolt axes and print orientations are generated in [assembly-manifest.json](exports/assembly-manifest.json). The dimensions printed in the drawings come from the exported meshes; drawings are not to scale.

STLs are individual parts in millimetres, already placed with their print base at Z=0. GLBs are viewing assemblies in metres and are not slicer projects. No G-code, supports, printer profile or infill toolpath is supplied. A single part's bounding box fitting a bed does not prove that all parts can be packed onto that bed at once.

## Joints and fastening strategy

| Joint | Hardware | Design intent |
|---|---|---|
| Left shell → right shell | Four M3 × 40 bolts and captive nuts | Close the housing across the seam; locating features register the halves |
| Nose → housing | One M3 × 45 bolt and captive nut | Retain the closed decorative cap on a locating interface |
| Phone dock → housing | Four M3 × 12 bolts and captive nuts | Transfer the phone load to the housing through the locating pads and fasteners |
| Each jaw → phone dock | Two M3 × 12 bolts and captive nuts | Adjust width along the dock slots, then lock it |
| Switch plate → housing | Two M3 × 12 bolts and captive nuts | Access and replace the purchased momentary button |

The source models clearances, not a strength rating. No adhesive is relied on for the main structural joints. Thin tape restrains the loose rigid shim stacks; soft lining still separates them from the phone. The nose is closed cosmetic geometry and carries no physical emitter.

Use M3 button-head bolts with heads no larger than Ø5.7 × 1.65 mm and standard nuts measuring 5.5 mm across flats × 2.4 mm thick. No washers are modeled. Captive nut pockets are 5.8 mm across flats × 2.7 mm deep and must match the actual nuts. Bolt head style, length, nut engagement and tool access are part of the fit check. Use the [generated fastener map](fastener-map.md) to identify the direction and seating location of every bolt. Do not substitute the old BOM.

## First print: the fit coupon

Print the coupon and the small button plate before committing to the large pieces. The 16.4 mm switch bore is in the button plate, not the coupon; confirm that the purchased switch accepts a 4 mm panel. It is a trial fit for the fastener and locator geometry, not proof that the whole assembly fits. Test with the same material, nozzle, layer settings and hardware intended for the kit. The [coupon feature map](fastener-map.md#fit-coupon-feature-map) identifies each trial hole and the thin neck to separate for the mating-lip test. Holes must accept bolts without splitting; nuts must seat and resist rotation; locating fits should seat by hand without forcing thin walls apart.

If the coupon binds or is excessively loose, adjust the relevant CAD clearances and regenerate the whole kit. Uniformly scaling the entire blaster also changes the phone fit and fastener dimensions, so retain 100% scale in the slicer and correct individual fit parameters instead.

## Print planning

The housing halves are intended to print on their outside faces with cavities facing up. The nose cap prints on its closed face with its cavity facing up. The dock, plate, jaws, shims and coupon have separate orientations recorded in the manifest. Inspect each STL independently in the slicer, especially horizontal nut pockets, countersinks, locator features and any remaining bridges.

Start with a material and profile you already know. A 0.4 mm nozzle and 0.2 mm layers are reasonable trial settings, with four walls and 30–40% infill as an initial experiment. These settings are not tested strength requirements. Filament, layer direction, surface quality and bolt torque can all change the result. Print with conspicuous arcade colours.

Splitting parts, controlling orientation, allowing fit clearance and adding locating features follow the approach described in [Prusa's modeling-for-printing guide](https://help.prusa3d.com/article/modeling-with-3d-printing-in-mind_164135). The actual split lines, joints and tolerances in this packet are original prototype choices and need a printed test.

## Assembly sequence

1. Print the fit coupon and button plate first. Trial the actual M3 hardware and locating fits, then the purchased switch in the plate. Correct individual CAD clearances if needed; do not scale the whole model.
2. Print the remaining parts in the supplied orientations. Clean mating faces and slicer-identified supports. Keep all v2 parts together; earlier v0/v1 parts are incompatible.
3. With the housing open, seat and retain FOUR J2 dock nuts and TWO J4 plate nuts. Mount the purchased switch in the loose plate with its own nut; confirm lead clearance and free travel. Keep electronics unpowered.
4. Close the shells on their locators using four J1 M3 × 40 bolts. Then attach the button plate with two J4 M3 × 12 bolts, approaching from the front BEFORE fitting the nose. Tighten gently by hand.
5. Fit the closed nose with one J3 M3 × 45 bolt and nut. Seat the dock on its pins and fit four J2 M3 × 12 bolts into the preloaded nuts, with phone and bottom liner removed for tool access.
6. Fit the jaws using four J5 M3 × 12 bolts and rear captive nuts. Adjust with the phone removed. Add two equal shim stacks, protective lining and the 15 mm restraint strap; follow the liner dimensions in the guide.
7. Bench-check with a phone-sized dummy, then the phone in its case with an independent tether. Verify retention, bolt ends, button travel, side controls, screen and all camera views before handling.

Two equal rigid shim stacks each total **18 mm minus the case-inclusive phone thickness** (for an 11 mm phone/case, each stack is 7 mm: 4 + 2 + 1). Use nominal 1 mm soft lining at the front, rear and bottom, and 1.5 mm at each side. Include any shim restraint tape in the thickness allowance. These are prototype allowances, not measured foam compression.

## What the print does not establish

Do not describe a CAD or slicer check as physical-device evidence. The first actual print must establish phone/case fit, nut and switch fit, normal button return, comfortable finger clearance, secure fastening, access to UI/ports/cameras, and retained-phone handling with a dummy before a phone is used. Record the printer/material, phone model/case and observed results without unique device identifiers.

The app remains responsible for aiming and authoritative firing. Bluetooth hardware, firmware, battery selection/restraint and app changes require the separate [integration handoff](integration-proposal.md).
