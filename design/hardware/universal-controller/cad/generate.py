#!/usr/bin/env python3
"""Regenerate the VKZ bench-fit controller concept, STL units millimetres.

No Blender required. See requirements.txt; run this file with Python 3.12+ (tested on 3.14.5).
All geometry is in assembly coordinates, then oriented/translated for printing.
This is a fit prototype, not a load-rated phone restraint or tested controller.
"""
from __future__ import annotations

import json
import importlib.metadata
import platform
import argparse
from pathlib import Path
import numpy as np
import manifold3d as m
import trimesh

OUT = Path(__file__).resolve().parent.parent / 'exports'
# Only the three nominal phone dimensions are user-editable through the CLI.
# Remaining P entries record FIXED dimensions of this revision; they are not
# independent parametric controls. Altering the mechanism requires CAD review.
P = dict(phone_width_min=65.0, phone_width_max=90.0, phone_width=77.0,
         phone_thickness_min=7.0, phone_thickness_max=17.0,
         phone_thickness=11.0, phone_height=155.0, side_foam=1.5,
         front_foam=1.0, rear_foam=1.0, bottom_foam=1.0,
         plate_width=120.0, plate_front=20.0, plate_back=28.0,
         plate_height=38.0, sliding_clearance=0.4,
         clamp_bore=4.5, cover_pilot=2.1, cover_clearance=2.8,
         button_bore=16.4, button_panel_thickness=4.0)


def box(x0, x1, y0, y1, z0, z1):
    return m.Manifold.cube((x1-x0, y1-y0, z1-z0)).translate((x0, y0, z0))


def cyl_y(x, z, y0, y1, radius):
    return m.Manifold.cylinder(y1-y0, radius, circular_segments=64).rotate((-90, 0, 0)).translate((x, y0, z))


def union(*objects):
    return m.Manifold.batch_boolean(objects, m.OpType.Add)


def subtract(base, *objects):
    return m.Manifold.batch_boolean([base, *objects], m.OpType.Subtract)


def round_xz(x0, x1, y0, y1, z0, z1, radius):
    corners = [cyl_y(x, z, y0, y1, radius)
               for x in (x0+radius, x1-radius)
               for z in (z0+radius, z1-radius)]
    return union(*corners).hull()


def slot(x0, x1, z, y0, y1, radius):
    return union(cyl_y(x0, z, y0, y1, radius), cyl_y(x1, z, y0, y1, radius)).hull()


def body():
    shell = round_xz(-19, 19, 0, 46, -108, -2, 6)
    cavity = round_xz(-13.5, 13.5, -1, 39, -99, -11, 4)
    button_relief = round_xz(-12, 12, 38, 42, -41, -15, 3)
    shell = subtract(shell, cavity, button_relief,
                     cyl_y(0, -28, 38, 47, P['button_bore']/2))
    plate = round_xz(-60, 60, 20, 28, 0, 38, 3)
    shelf = box(-53, 53, 0, 28, -4, 2)
    result = union(shell, plate, shelf)
    holes = []
    for side in (-1, 1):
        lo, hi = sorted((side*22, side*34.5))
        for z in (10, 28):
            holes += [slot(lo, hi, z, 19, 29, P['clamp_bore']/2),
                      slot(lo, hi, z, 19, 22.6, 4.2)]
        holes.append(box(side*55-1.5, side*55+1.5, 19, 29, 12, 30))
    for x in (-10, 10):
        for z in (-103, -7):
            holes.append(cyl_y(x, z, -1, 12, P['cover_pilot']/2))
    # Tether hole through the solid heel, separate from the electronics cavity.
    holes.append(cyl_y(0, -103, -1, 47, 2.2))
    return subtract(result, *holes)


def jaw(right=True):
    inner = (P['phone_width']+2*P['side_foam'])/2
    wall = box(inner, inner+4, -4, 19.6, 2, 43.4)
    toe = box(inner-6, inner+4, -4, 0, 2, 12)
    flange = box(inner-25, inner+4, 28.4, 33.4, 3, 43.4)
    bridge = box(inner-25, inner+4, 19.6, 33.4, 38.4, 43.4)
    # Upright joining front wall to bridge is implicit at x=inner..inner+4.
    result = union(wall, toe, flange, bridge)
    result = subtract(result, *[cyl_y(inner-12, z, 27.4, 34.4, P['clamp_bore']/2)
                                for z in (10, 28)])
    return result if right else result.mirror((1, 0, 0))


def cover():
    result = round_xz(-19, 19, -3, 0, -108, -2, 6)
    holes = [cyl_y(x, z, -4, 1, P['cover_clearance']/2)
             for x in (-10, 10) for z in (-103, -7)]
    holes.append(cyl_y(0, -103, -4, 1, 2.2))
    return subtract(result, *holes)


def shim(thickness):
    return round_xz(-6, 6, 0, thickness, 5, 29, 1.5)


def to_trimesh(solid):
    mesh = solid.to_mesh()
    return trimesh.Trimesh(vertices=np.asarray(mesh.vert_properties)[:, :3],
                           faces=np.asarray(mesh.tri_verts), process=True)


def translation(x=0, y=0, z=0):
    result = np.eye(4)
    result[:3, 3] = [x, y, z]
    return result


def connected_components(mesh):
    parents = list(range(len(mesh.faces)))
    def find(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i
    for a, b in mesh.face_adjacency:
        parents[find(int(a))] = find(int(b))
    return len({find(i) for i in range(len(parents))})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phone-width', type=float, default=77,
                        help='Nominal case-inclusive phone width,65–90mm.')
    parser.add_argument('--phone-thickness', type=int, default=11,
                        help='Nominal case-inclusive thickness,integer7–17mm; foam additional.')
    parser.add_argument('--phone-height', type=float, default=155,
                        help='Reference envelope height in mm,at least60; height fit is not certified.')
    args = parser.parse_args()
    if not 65 <= args.phone_width <= 90:
        parser.error('--phone-width must be within65–90mm')
    if not 7 <= args.phone_thickness <= 17:
        parser.error('--phone-thickness must be an integer within7–17mm')
    if args.phone_height < 60:
        parser.error('--phone-height must be at least60mm')
    P.update(phone_width=args.phone_width, phone_thickness=args.phone_thickness,
             phone_height=args.phone_height)
    rigid_remaining = 18 - P['phone_thickness']
    shim_y_positions = {}
    stack_cursor = 20
    for thickness in (8, 4, 2, 1):
        if rigid_remaining >= thickness:
            stack_cursor -= thickness
            shim_y_positions[thickness] = stack_cursor
            rigid_remaining -= thickness
    assert rigid_remaining == 0
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = dict(format_version=1, units='mm', status='UNTESTED_BENCH_FIT_PROTOTYPE',
        axes={'x': 'phone width; +x right', 'y': '+y camera/rear/forward; screen faces -y',
              'z': 'up; phone bottom at z=3'},
        parameters={k: P[k] for k in ('phone_width', 'phone_thickness', 'phone_height')},
        fixed_design_dimensions={k: v for k, v in P.items() if k not in ('phone_width', 'phone_thickness', 'phone_height')},
        parts=[], references=[], validation={}, assembly_relationships=[],
        assumptions=[
            '65–90mm case-inclusive width and 7–17mm case-inclusive thickness are design targets, not measured compatibility.',
            'Maximum clamp height above seated phone bottom is 40.4mm. Lower side buttons and ports may conflict.',
            'Phone needs 1.5mm side foam, 1mm front and rear foam, and 1mm bottom foam; dimensions are nominal installed thickness.',
            'Rigid shim requirement = 18 - case-inclusive thickness in mm; pairs of 1/2/4/8mm shims cover integer targets 1–11mm.',
            'Rear rigid shims require temporary thin double-sided tape; include tape in foam/thickness allowance.',
            'One 15mm hook-and-loop strap routes through both wing slots and across the lower screen; a tether through the grip heel is supplemental.',
            'Four M4 button-head bolts must have heads no larger than 8.4mm diameter and 2.6mm height to stay recessed.',
            'Cover uses four M2.5 self-tapping plastic screws, nominal 12mm under-head length; pilot fit requires a test print.',
            '16.4mm switch bore and 4mm panel require confirmation against the purchased switch nut, thread, leads and button travel.',
            'Housing cavity excludes screw regions and supports no particular BLE board or battery; no battery restraint is designed.',
            'No physical laser, projectile path, firearm interface, electronics, firmware or game trigger integration is included.',
            'No physical print, load, impact, phone-retention, heat, wiring or ergonomic tests have been completed.'
        ])
    solids = {'grip_cradle': body(), 'jaw_right': jaw(True), 'jaw_left': jaw(False),
              'grip_cover': cover(), **{f'shim_{t}mm': shim(t) for t in (1, 2, 4, 8)}}
    colors = {'grip_cradle': [1.0, .40, .05, 1], 'jaw_right': [.05, .78, .83, 1],
              'jaw_left': [.05, .78, .83, 1], 'grip_cover': [.12, .16, .22, 1]}
    assembled = {}
    # Rotate +90 degrees around X: assembly +Y is print +Z. Body/cover
    # lie on broad rear faces, while jaws use an outer side wall as bed face.
    body_rotation = trimesh.transformations.rotation_matrix(np.pi/2, [1, 0, 0])
    for part_id, solid in solids.items():
        source = to_trimesh(solid)
        rotation = body_rotation.copy()
        if part_id.startswith('jaw_'):
            rotation = trimesh.transformations.rotation_matrix(
                np.pi/2 if part_id == 'jaw_right' else -np.pi/2, [0, 1, 0])
        printable = source.copy()
        printable.apply_transform(rotation)
        offset = translation(*(-printable.bounds[0]))
        printable.apply_transform(offset)
        to_assembly = np.linalg.inv(offset @ rotation)
        file_name = f'{part_id}.stl'
        printable.export(OUT / file_name)
        reloaded = trimesh.load_mesh(OUT / file_name, process=True)
        components = connected_components(reloaded)
        assert reloaded.is_watertight and reloaded.is_winding_consistent and components == 1 and reloaded.volume > 0, part_id
        instances = []
        if part_id.startswith('shim_'):
            t = int(part_id.split('_')[1].removesuffix('mm'))
            # Stack from the backplate toward the screen, largest shim first.
            if t in shim_y_positions:
                for side in (-1, 1):
                    transform = translation(x=side*9, y=shim_y_positions[t]) @ to_assembly
                    instances.append(dict(id=f'{part_id}_{"left" if side<0 else "right"}',
                        transform=transform.tolist(), color=[.40, .46, .52, 1],
                        explode=[side*8, -15-(7-t)*2, 0]))
        else:
            displacement = {'grip_cradle': [0, 0, 0], 'jaw_right': [28, 8, 12],
                            'jaw_left': [-28, 8, 12], 'grip_cover': [0, -35, 0]}[part_id]
            instances.append(dict(id=part_id, transform=to_assembly.tolist(),
                                  color=colors[part_id], explode=displacement))
            assembled[part_id] = solid
        manifest['parts'].append(dict(id=part_id, file=file_name, quantity_to_print=2 if part_id.startswith('shim_') else 1,
            instances=instances, spare_only=not bool(instances),
            print_orientation='STL is already oriented with minimum XYZ at zero; verify supports in slicer.',
            supports=('Supports required under raised backplate and its slot recesses; inspect cavity roof bridging in slicer.' if part_id == 'grip_cradle' else
                      'Outer side wall lies on bed; inspect return/flange and holes for local supports in slicer.' if part_id.startswith('jaw') else
                      'Flat part; inspect slicer preview before printing.'),
            bounds_mm=reloaded.bounds.tolist(), assembled_source_bounds_mm=source.bounds.tolist(),
            volume_mm3=float(reloaded.volume), surface_area_mm2=float(reloaded.area),
            vertices=len(reloaded.vertices), triangles=len(reloaded.faces),
            watertight=bool(reloaded.is_watertight), winding_consistent=bool(reloaded.is_winding_consistent),
            connected_components=components))
    manifest['references'] = [
        dict(id='phone_envelope_not_printable', bounds_mm=[[-P['phone_width']/2, 1, 3], [P['phone_width']/2, 1+P['phone_thickness'], 3+P['phone_height']]], color=[.16, .19, .25, .5]),
        dict(id='switch_body_clearance_not_printable', bounds_mm=[[-9.1, 17, -37.1], [9.1, 42, -18.9]], color=[.13, .15, .19, .5]),
        dict(id='switch_button_not_printable', bounds_mm=[[-9.1, 46, -37.1], [9.1, 51, -18.9]], color=[1, .15, .25, 1]),
        dict(id='rear_soft_liner_left_not_printable', bounds_mm=[[-15, 1+P['phone_thickness'], 5], [-3, 2+P['phone_thickness'], 29]], color=[.12, .12, .12, 1]),
        dict(id='rear_soft_liner_right_not_printable', bounds_mm=[[3, 1+P['phone_thickness'], 5], [15, 2+P['phone_thickness'], 29]], color=[.12, .12, .12, 1]),
    ]
    overlaps = []
    names = list(assembled)
    for i, a in enumerate(names):
        for b in names[i+1:]:
            volume = float((assembled[a] ^ assembled[b]).volume())
            overlaps.append(dict(a=a, b=b, intersection_mm3=volume))
            assert abs(volume) < .001, f'Assembled collision {a}/{b}: {volume}'
    width_checks = []
    for width in (P['phone_width_min'], P['phone_width'], P['phone_width_max']):
        shift = (width-P['phone_width'])/2
        for side, name in ((1, 'jaw_right'), (-1, 'jaw_left')):
            placed = assembled[name].translate((side*shift, 0, 0))
            collision = float((placed ^ assembled['grip_cradle']).volume())
            width_checks.append(dict(phone_width_mm=width, jaw=name, body_intersection_mm3=collision))
            assert abs(collision) < .001
    manifest['validation'] = dict(stl_reloaded=True, all_parts_watertight=True,
        all_parts_single_connected_solid=True, positive_volume=True,
        nominal_assembly_intersections=overlaps, width_endpoint_intersections=width_checks,
        physical_testing='NONE; geometry checks do not establish strength, retention, printer fit or switch fit.')
    manifest['assembly_relationships'] = [
        dict(parent='grip_cradle', children=['jaw_left', 'jaw_right'], constraint='Translate along X only, ±6.25mm around midpoint width77.5; bolt centers through z10 and28, X±22..34.5.', fasteners='4×M4×20 button-head bolts, 4×M4 washers, 4×M4 nuts; heads ≤8.4mm×2.6mm. Recessed heads face phone.'),
        dict(parent='grip_cradle', children=['grip_cover'], constraint='Rear cover mating plane Y=0; pilots X±10/Z-103 and-7.', fasteners='4×M2.5×12 self-tapping plastic screws, not machine screws;2.1mm pilots.'),
        dict(parent='grip_cradle', children=['shim_1mm', 'shim_2mm', 'shim_4mm', 'shim_8mm'], constraint=f'Two rigid stacks centered X±9, Z5..29, terminating at rear plateY20. Selected {P["phone_thickness"]}mm phone uses '+ '+'.join(map(str, shim_y_positions))+'mm each side.', fasteners='Temporary thin double-sided tape and mandatory soft liners; do not leave unrestrained shims.'),
        dict(parent='grip_cradle', children=['switch_button_not_printable'], constraint='Switch shaft centerX0/Z-28, axisY; exposed button beyondY46, panelY42..46.', fasteners='Purchased switch mounting nut; bench-check shaft/thread/panel compatibility.'),
        dict(parent='grip_cradle', children=['phone_envelope_not_printable'], constraint='Seat on foam atZ3; clamp foamed sides; restraint strap throughX±55 wing slotsZ12..30 crossing lower screen.', fasteners='15mm hook-and-loop strap plus separate wrist tether through4.4mmdiameter heel hole.')
    ]
    (OUT / 'assembly-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (OUT / 'cad-environment.json').write_text(json.dumps(dict(python=platform.python_version(),
        packages={name: importlib.metadata.version(name) for name in ('manifold3d', 'trimesh', 'numpy')}), indent=2)+'\n')
    print(json.dumps({'parts': len(manifest['parts']), 'all_watertight': True,
                      'all_connected': True, 'output': str(OUT)}, indent=2))


if __name__ == '__main__':
    main()
