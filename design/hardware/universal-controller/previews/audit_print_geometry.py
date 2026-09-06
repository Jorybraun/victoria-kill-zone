"""Independent STL read-back for flat-bed contact and bounded print dimensions.

This is a geometry screen. It does not replace slicing, strength or print tests.
"""
from pathlib import Path
import json
import numpy as np
import trimesh
ROOT=Path(__file__).resolve().parents[1]
m=json.loads((ROOT/'exports/assembly-manifest.json').read_text())
rows=[]
for p in m['parts']:
    mesh=trimesh.load_mesh(ROOT/'exports'/p['file'])
    bed=np.all(np.abs(mesh.triangles[:,:,2])<.0001,axis=1)
    down=mesh.face_normals[:,2]<-np.sqrt(.5)
    above=mesh.triangles[:,:,2].min(axis=1)>.05
    row={'part':p['id'],'dimensions_mm':mesh.extents.tolist(),
         'minimum_z_mm':float(mesh.bounds[0,2]),
         'flat_bed_contact_mm2':float(mesh.area_faces[bed].sum()),
         'downward_facing_area_above_bed_mm2':float(mesh.area_faces[down&above].sum()),
         'watertight':bool(mesh.is_watertight),
         'positive_volume':bool(mesh.volume>0)}
    assert row['watertight'] and row['positive_volume'],p['id']
    assert np.all(mesh.extents<=180.001),p['id']
    assert abs(row['minimum_z_mm'])<.001,p['id']
    assert row['flat_bed_contact_mm2']>1,p['id']
    rows.append(row)
out={'method':'Independent STL re-load; face area atZ0; total downward-facing area above the bed. This cannot classify bridge spans, toolpaths, strength or support removability.',
     'result':'PASS: all files have planar bed contact, positive closed volumes, Z0 bases and dimensions<=180mm.',
     'parts':rows}
(ROOT/'previews/print-geometry-audit.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({'checked':len(rows),'all_have_flat_bed_contact':True,'within_180mm':True}))
