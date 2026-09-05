"""Print pinned source bone inventory without extracting the full archive."""
from pathlib import Path
import csv, zipfile, json
import numpy as np
ROOT=Path(__file__).resolve().parent
PARTS=list(csv.DictReader((ROOT/'cache/partof_parts_list_e.txt').open(),delimiter='\t'))
ELEMS={}
for r in csv.DictReader((ROOT/'cache/partof_element_parts.txt').open(),delimiter='\t'):
 ELEMS.setdefault(r['concept id'],[]).append(r['element file id'])
ZIP=zipfile.ZipFile(ROOT/'cache/partof_BP3D_4.0_obj_99.zip')
def read(eid):
 lines=ZIP.read('partof_BP3D_4.0_obj_99/'+eid+'.obj').decode().splitlines()
 v=np.array([[float(n) for n in l.split()[1:4]] for l in lines if l.startswith('v ')])
 f=np.array([[int(n.split('/')[0])-1 for n in l.split()[1:4]] for l in lines if l.startswith('f ')],dtype=np.int32)
 name=next(l.split(' : ')[1] for l in lines if l.startswith('# English name'))
 return v,f,name
if __name__=='__main__':
 for p in PARTS:
  if p['en'] in ['left humerus','right humerus','left femur','right femur','left radius','left ulna','left tibia','left fibula','left patella','sternum','atlas','axis','sacrum','left hip bone','left talus','left calcaneus','left clavicle','left scapula']:
   for e in ELEMS[p['concept id']]:
    v,f,n=read(e); print(p['en'],e,n,len(v),len(f),'min',v.min(0).round(2).tolist(),'max',v.max(0).round(2).tolist())
