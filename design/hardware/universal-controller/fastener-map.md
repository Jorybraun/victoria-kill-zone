# Generated fastener map — v2

Units: millimetres, in assembled coordinates. X is left/right width; Y is forward toward the cameras; Z is up. Coordinates apply to the selected nominal assembly, not the reoriented STL print bed.

Selected phone envelope: 77 × 155 × 11 mm (width × height × thickness, including case).

Bolt axis is the insertion direction. The axis coordinate in each centre is a reference joint plane; use the head-seat coordinate to locate the underside of the actual bolt head. All heads are button-head, maximum Ø5.7 × 1.65 mm; all nuts are 5.5 mm across flats × 2.4 mm. No washers are modeled.

| Joint | Qty / length | Insert | Reference centres (X, Y, Z) | Head seat on axis | Nut extent on axis |
|---|---|---|---|---|---|
| J1 | 4 × M3 × 40 mm | +X | (0, 8, -24); (0, 35, -56); (0, 5, -94); (0, 52, -5) | -19 | 16.3 to 18.7 |
| J2 | 4 × M3 × 12 mm | −Z | (-10, 5, -4); (-10, 15.5, -4); (10, 5, -4); (10, 15.5, -4) | 0 | -11.7 to -9.3 |
| J3 | 1 × M3 × 45 mm | +X | (0, 62, -7) | -21 | 21.3 to 23.7 |
| J4 | 2 × M3 × 12 mm | −Y | (0, 42, -13); (0, 42, -44) | 46 | 34.3 to 36.7 |
| J5 | 4 × M3 × 12 mm | +Y | (-28, 28, 10); (-28, 28, 28); (28, 28, 10); (28, 28, 28) | 22 | 30.7 to 33.1 |

All modeled nuts receive their full nominal 2.4 mm thickness of thread engagement. Actual bolt tolerances and incomplete end threads still require a hardware fit check. J1 thread ends project 2.3 mm beyond the nuts; check these external ends before handling.

Seat and retain the four J2 nuts and two J4 nuts while the housing is open. J1 and J3 nuts are accessible from the side. Install the J4 plate before the nose. J2 bolts require the phone and bottom liner to be removed; J5 bolts require the phone removed. A modeled access path does not prove clearance for every screwdriver handle.

J5 jaw centres move with phone width: X = ±((case width + 3) / 2 − 12), at Z = 10 and 28. Regenerate the manifest and drawing set when changing the nominal phone dimensions.

## Fit coupon feature map

Coupon STL coordinates, millimetres; Z=0 is bed.

Saw only the thin neck centered at X=32, Y=10..12, Z=0..2. Flip the separated female plate so its socket faces the male lip; their broad top faces should meet without forcing.

| Feature | Location in coupon STL |
|---|---|
| Ø3.2 vertical test hole | X=20, Y=5 |
| Ø3.3 vertical test hole | X=56, Y=5 |
| Ø3.4 vertical test hole | X=20, Y=17 |
| Ø3.5 vertical test hole | X=56, Y=17 |
| Male locating lip | X=8, Y=11 |
| Female locating socket | X=42, Y=11 |
| 5.8 mm across-flats nut pocket, up | X=8, Y=31 |
| 5.8 mm across-flats nut pocket, toward bed; tests pocket bridging | X=22, Y=31 |
| Ø3.4 horizontal hole, axis +Y | X=15, Z=3, Y=25 to 37 |

The switch gauge is the separate button plate: Ø16.4 mm bore through a 4 mm panel. The coupon does not contain a switch gauge.
