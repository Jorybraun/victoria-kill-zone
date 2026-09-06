#!/usr/bin/env python3
"""Reproducible offline BodyParts3D -> indexed SKN1. See README.md for licensing/bind contract."""
from __future__ import annotations
import argparse, csv, hashlib, io, json, math, struct, zipfile
from pathlib import Path
import numpy as np
import fast_simplification
import trimesh
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
ASSETS = REPO/'ios/VictoriaKillZone/VictoriaKillZone/Features/Game/SkeletonAssets'
SOURCE_PINS = {
 'partof_BP3D_4.0_obj_99.zip': '9fbc713fffeee924a5a657d9813d84d7eb957bded63adb854931dd5e3eb61c97',
 'partof_parts_list_e.txt': '9224080557053e6f1322f1e13ab27f0ecde0db19bb3b505f0631afad230eeebd',
 'partof_element_parts.txt': '3f5f6df1028eb122b30de77c711597b6bb8e5541658e5985859fd228adbf88ea',
}
SKULL='FJ3199 FJ3200 FJ3263 FJ3265 FJ3269 FJ3272 FJ3273 FJ3274 FJ3281 FJ3287 FJ3289 FJ3309 FJ3369 FJ3371 FJ3375 FJ3378 FJ3379 FJ3380 FJ3386 FJ3392 FJ3394 FJ3395'.split()
PART_ORDER='skull cervicalSpine ribcage spine pelvis leftClavicle rightClavicle leftUpperArm rightUpperArm leftForearm rightForearm leftThigh rightThigh leftShin rightShin leftHand rightHand leftFoot rightFoot'.split()
# Whole-asset rigid conversion only: (x,y,z) mm -> (x,z,-y) m.
# Floor from lowest calcaneus; anterior origin through pelvic root. det(rotation)=+1.
FLOOR_MM=68.42
ANTERIOR_ORIGIN_MM=80.0

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def convert(v): return np.column_stack((v[:,0], v[:,2]+FLOOR_MM, -v[:,1]-ANTERIOR_ORIGIN_MM))*0.001

def load_sources(cache):
 for f,digest in SOURCE_PINS.items():
  if not (cache/f).is_file() or sha(cache/f)!=digest: raise ValueError(f'Absent or hash-mismatched source {f}; run fetch.py')
 rows=list(csv.DictReader(io.StringIO((cache/'partof_parts_list_e.txt').read_text()),delimiter='\t'))
 names={r['en']:r['concept id'] for r in rows}
 elements={}
 for r in csv.DictReader(io.StringIO((cache/'partof_element_parts.txt').read_text()),delimiter='\t'):
  elements.setdefault(r['concept id'],set()).add(r['element file id'])
 z=zipfile.ZipFile(cache/'partof_BP3D_4.0_obj_99.zip')
 return names,elements,z

def select(names,elements):
 groups={p:set() for p in PART_ORDER}; sources={p:[] for p in PART_ORDER}
 def add(part,name):
  if name not in names: raise ValueError('Unknown anatomy '+name)
  groups[part].update(elements[names[name]])
  sources[part].append({'concept':names[name],'name':name})
 groups['skull'].update(SKULL)
 for n in ['atlas','axis','third cervical vertebra','fourth cervical vertebra','fifth cervical vertebra','sixth cervical vertebra','seventh cervical vertebra','hyoid bone']:add('cervicalSpine',n)
 # Explicit connecting cartilage gives costal arch continuity without importing muscle/eye/discs.
 for n in names:
  if (n.startswith(('right ','left ')) and (n.endswith(' rib') or 'costal cartilage' in n)) or n=='sternum': add('ribcage',n)
  if n.endswith(('thoracic vertebra','lumbar vertebra')) and not n.startswith('intervertebral'): add('spine',n)
 for n in ['sacrum','left hip bone','right hip bone']:add('pelvis',n)
 for side in ['left','right']:
  for n in ['clavicle','scapula']:add(side+'Clavicle',side+' '+n)
  for part,bones in [('UpperArm',['humerus']),('Forearm',['radius','ulna']),('Thigh',['femur','patella']),('Shin',['tibia','fibula'])]:
   for n in bones:add(side+part,side+' '+n)
  for n in names:
   if side not in n.split():continue
   if (('phalanx' in n and any(x in n for x in ['finger','thumb'])) or 'metacarpal bone' in n or n==side+' '+n.split()[-1] and n.split()[-1] in ['scaphoid','lunate','triquetral','pisiform','trapezium','trapezoid','capitate','hamate']):add(side+'Hand',n)
   if (('phalanx' in n and 'toe' in n) or 'metatarsal bone' in n or any(x in n for x in ['calcaneus','talus','cuneiform bone','cuboid bone','navicular bone of'])):add(side+'Foot',n)
 # Exact duplicate hyoid element in official table; FJ3201 matches it byte-for-byte geometry.
 groups['cervicalSpine'].discard('FJ2772')
 seen=set()
 for part in PART_ORDER:
  if seen.intersection(groups[part]):raise ValueError('Repeated element in '+part)
  seen.update(groups[part])
 return groups,sources

def read_obj(z,eid):
 raw=z.read('partof_BP3D_4.0_obj_99/'+eid+'.obj')
 text=raw.decode();lines=text.splitlines()
 if '# Compatibility version : 4.0' not in text or '# Build-up logic : FMA 3.0 part_of' not in text:raise ValueError('Wrong version '+eid)
 v=np.array([[float(x) for x in l.split()[1:4]] for l in lines if l.startswith('v ')],dtype=np.float64)
 faces=[]
 for l in lines:
  if l.startswith('f '):
   face=[int(x.split('/')[0])-1 for x in l.split()[1:]]
   for k in range(1,len(face)-1): faces.append([face[0],face[k],face[k+1]])
 f=np.array(faces,dtype=np.int32)
 name=next(l.split(' : ')[1] for l in lines if l.startswith('# English name'))
 return convert(v),f,name,hashlib.sha256(raw).hexdigest()

def clean(v,f):
 # Merge exactly coincident OBJ positions before quadratic simplification; do not
 # weld across separately authored bones or fill anatomical openings.
 v,inv=np.unique(v,axis=0,return_inverse=True);f=inv[f]
 valid=(f[:,0]!=f[:,1])&(f[:,1]!=f[:,2])&(f[:,0]!=f[:,2]);f=f[valid]
 cross=np.cross(v[f[:,1]]-v[f[:,0]],v[f[:,2]]-v[f[:,0]])
 f=f[np.linalg.norm(cross,axis=1)>1e-12]
 used,inv=np.unique(f,return_inverse=True)
 return v[used],inv.reshape(-1,3).astype(np.int32)

def normals(v,f):
 n=np.zeros_like(v);fn=np.cross(v[f[:,1]]-v[f[:,0]],v[f[:,2]]-v[f[:,0]])
 for k in range(3):np.add.at(n,f[:,k],fn)
 norms=np.linalg.norm(n,axis=1)
 for i in np.flatnonzero(norms<1e-14):
  incident=fn[np.any(f==i,axis=1)]
  n[i]=incident[np.argmax(np.linalg.norm(incident,axis=1))]
  norms[i]=np.linalg.norm(n[i])
 if np.any(norms<1e-14): raise ValueError('Zero normal')
 return n/norms[:,None]

# Joint centres are art-reviewed anatomical estimates in the common source
# coordinate frame, NOT perpart AABB centres and NOT ARKit measurements.
# Values inspect paired long-bone articulating surfaces; all source offsets stay intact.
SOURCE_LANDMARKS_MM={
 'root':[0,-80,850], 'neck_1_joint':[0,-78,1370], 'head':[0,-92,1510],
 'spine_7_joint':[0,-70,1230],
 'leftShoulder':[65,-90,1340], 'rightShoulder':[-65,-90,1340],
 'left_arm_joint':[158,-78,1318], 'right_arm_joint':[-158,-78,1318],
 'left_forearm_joint':[216,-73,1040], 'right_forearm_joint':[-216,-73,1040],
 'leftHand':[251,-113,812], 'rightHand':[-251,-113,812],
 'left_upLeg_joint':[55,-82,812], 'right_upLeg_joint':[-55,-82,812],
 'left_leg_joint':[80,-82,373], 'right_leg_joint':[-80,-82,373],
 'leftFoot':[70,-74,-2], 'rightFoot':[-70,-74,-2],
}

def unit(v): return v/np.linalg.norm(v)
def arc_between(a,up):
 # Minimum rotation transporting the common superior/anterior basis to segment up.
 # No reflection, no limb-down front/back flip.
 up=unit(up);a=unit(a);v=np.cross(a,up);c=float(a@up)
 if c<-0.999999:return np.diag([1.,-1.,-1.])
 K=np.array([[0,-v[2],v[1]],[v[2],0,-v[0]],[-v[1],v[0],0.]])
 return np.eye(3)+K+K@K/(1+c)
def arc_up(up): return arc_between(np.array([0.,1.,0.]),up)

def bind_frames():
 p={k:convert(np.array([v],dtype=float))[0] for k,v in SOURCE_LANDMARKS_MM.items()}
 W=np.linalg.norm(p['left_arm_joint']-p['right_arm_joint']);H=np.linalg.norm(p['neck_1_joint']-p['root'])
 torso=arc_up(p['neck_1_joint']-p['root']); frames={}
 def frame(origin,rotation,height):
  m=np.eye(4);m[:3,:3]=rotation@np.diag([W,height,W]);m[:3,3]=origin;return m
 for name in ['ribcage','spine','pelvis','leftClavicle','rightClavicle']:frames[name]=frame(p['root'],torso,H)
 for name in ['skull','cervicalSpine']:frames[name]=frame(p['neck_1_joint'],arc_between(torso[:,1],p['head']-p['neck_1_joint'])@torso,np.linalg.norm(p['head']-p['neck_1_joint']))
 for side in ['left','right']:
  segments={'UpperArm':('arm_joint','forearm_joint'),'Forearm':('forearm_joint','Hand'),'Thigh':('upLeg_joint','leg_joint'),'Shin':('leg_joint','Foot')}
  def key(s):return side+s if s in ['Hand','Foot'] else side+'_'+s
  for name,(a,b) in segments.items():
   prox,dist=p[key(a)],p[key(b)];frames[side+name]=frame(prox,arc_between(torso[:,1],prox-dist)@torso,np.linalg.norm(prox-dist))
  for name,a,b in [('Hand','forearm_joint','Hand'),('Foot','leg_joint','Foot')]:
   prox,dist=p[key(a)],p[key(b)];frames[side+name]=frame(dist,arc_between(torso[:,1],prox-dist)@torso,np.linalg.norm(prox-dist))
 return frames,p,W,H

def tooth_mesh():
 # Original restrained closed dentition seated at the alveolar borders. 14 crowns
 # per jaw (no roots visible); narrow natural incisor-to-molar variation. Never
 # used for collision or inferred facial/finger tracking.
 allv=[];allf=[]
 for upper in [True,False]:
  for side in [-1,1]:
   for i,(x,z,w,d,h) in enumerate([
    (3.4,93.7,6.2,5.0,7.0),(9.7,93.1,5.5,5.2,6.3),(15.4,90.5,5.4,6.2,6.8),
    (20.3,86.7,5.7,7.0,5.2),(23.4,80.7,6.3,7.4,4.8),(25.5,73.0,7.5,8.0,4.8),(26.1,64.8,7.7,8.0,4.4)]):
    # Desired source-mm centre: y(vertical) lower jaw edge at 1456, upper 1466.
    cy=1463.0+(h*.48 if upper else -h*.48)
    # Rounded superellipsoid crowns with modest inset; source anterior z offset
    # already converted above (raw OBJ y is negative anterior).
    theta=math.atan2(x,60.0)
    center=np.array([side*x,cy+FLOOR_MM,z])*0.001
    ring_n=10;rings=5;v=[]
    for j in range(rings+1):
     lat=-math.pi/2+math.pi*j/rings
     for k in range(ring_n):
      lon=2*math.pi*k/ring_n
      def sq(a,p):return math.copysign(abs(a)**p,a)
      local=np.array([w*.5*sq(math.cos(lat),.55)*sq(math.cos(lon),.55),h*.5*sq(math.sin(lat),.7),d*.5*sq(math.cos(lat),.55)*sq(math.sin(lon),.55)])*.001
      rot=np.array([[math.cos(theta),0,side*math.sin(theta)],[0,1,0],[-side*math.sin(theta),0,math.cos(theta)]])
      v.append(center+rot@local)
    f=[]
    for j in range(rings):
     for k in range(ring_n):
      a=j*ring_n+k;b=j*ring_n+(k+1)%ring_n;c=(j+1)*ring_n+k;d0=(j+1)*ring_n+(k+1)%ring_n
      f.extend([[a,c,b],[b,c,d0]])
    v,f=clean(np.array(v),np.array(f));allf.append(f+sum(len(x) for x in allv));allv.append(v)
 return np.concatenate(allv),np.concatenate(allf)

def build(cache,out,budget=52000):
 names,elements,z=load_sources(cache);groups,selections=select(names,elements)
 source={};meta={};stats={}
 for part in PART_ORDER:
  source[part]=[]
  for eid in sorted(groups[part]):
   v,f,name,digest=read_obj(z,eid);source[part].append((eid,v,f,name))
   meta[eid]={'name':name,'sourceSHA256':digest,'sourceTriangles':len(f)}
  stats[part]=sum(len(f) for _,_,f,_ in source[part])
 print('Source triangles by group:',stats,flush=True)
 # Preserve already-low-detail limb, hand, foot and rib shape. Simplify complex
 # cranial internal surfaces first, reserve budget for silhouette-bearing facial bones.
 caps={'skull':14500,'cervicalSpine':2700,'ribcage':6400,'spine':4800,'pelvis':3400,
       'leftClavicle':1400,'rightClavicle':1400,'leftUpperArm':1000,'rightUpperArm':1000,
       'leftForearm':750,'rightForearm':750,'leftThigh':1150,'rightThigh':1150,
       'leftShin':850,'rightShin':850,'leftHand':1300,'rightHand':1300,'leftFoot':1400,'rightFoot':1400}
 # Face + cranium receives explicit prioritization, avoiding indiscriminate pressure
 # from the densely triangulated internal ethmoid/vomer.
 skull_caps={'FJ3199':750,'FJ3200':2200,'FJ3263':160,'FJ3369':160,'FJ3265':180,'FJ3371':180,
  'FJ3269':1200,'FJ3375':1200,'FJ3272':150,'FJ3378':150,'FJ3273':220,'FJ3379':220,
  'FJ3274':1300,'FJ3380':1300,'FJ3281':800,'FJ3386':800,'FJ3287':600,'FJ3392':600,
  'FJ3289':1800,'FJ3309':1200,'FJ3394':700,'FJ3395':180}
 frames,landmarks,W,H=bind_frames(); output={}; partmeta={}
 for part in PART_ORDER:
  vs=[];fs=[]
  for eid,v,f,name in source[part]:
   raw_count=len(f);v,f=clean(v,f)
   target=skull_caps[eid] if part=='skull' else max(40,int(caps[part]*raw_count/stats[part]))
   target=min(len(f),target)
   if target<len(f): v,f=fast_simplification.simplify(v,f,target_count=target,agg=5)
   v,f=clean(v,f)
   # Two mild Taubin passes only on the skull smooth decimation stair steps while
   # preserving cavity openings; no hole filling or inter-bone welds.
   if part=='skull':
    mesh=trimesh.Trimesh(v,f,process=False)
    trimesh.smoothing.filter_taubin(mesh,lamb=.25,nu=.26,iterations=2)
    v=np.array(mesh.vertices);f=np.array(mesh.faces)
   fs.append(f+sum(len(a) for a in vs));vs.append(v)
   meta[eid]['outputTriangles']=len(f)
  if part=='skull':
   v,f=tooth_mesh();fs.append(f+sum(len(a) for a in vs));vs.append(v)
  v,f=np.concatenate(vs),np.concatenate(fs);n=normals(v,f)
  # Subtle geometry-derived cavity ambient attenuation, no view-facing baked light.
  # Local normal disagreement describes creases; kept low contrast for mobile light.
  adj=np.zeros_like(n);counts=np.zeros(len(v))
  for a,b in [(0,1),(1,2),(2,0)]:
   np.add.at(adj,f[:,a],n[f[:,b]]);np.add.at(adj,f[:,b],n[f[:,a]])
   np.add.at(counts,f[:,a],1);np.add.at(counts,f[:,b],1)
  coherence=np.sum(n*adj/np.maximum(counts,1)[:,None],axis=1)
  shade=np.clip(.90+.10*coherence,.84,1.)
  color=np.column_stack([shade,shade,shade,np.ones(len(v))])
  vertices=np.concatenate([v,n,color],axis=1).astype('<f4')
  output[part]=(vertices,f.astype('<u4'))
  partmeta[part]={'vertices':len(v),'triangles':len(f),'elements':sorted(groups[part]),'concepts':selections[part],
   'bindTransformColumnMajor':frames[part].T.ravel().tolist(),'boundsMeters':[v.min(0).tolist(),v.max(0).tolist()]}
  print(part,len(v),len(f),flush=True)
 total=sum(len(f) for _,f in output.values())
 if total>budget:raise ValueError(f'Asset triangles {total} exceeds approved {budget}')
 b=io.BytesIO();b.write(b'SKN1');b.write(struct.pack('<I',len(output)))
 for part,(v,f) in output.items():
  name=part.encode();b.write(struct.pack('<H',len(name)));b.write(name);b.write(frames[part].T.astype('<f4').tobytes());b.write(struct.pack('<II',len(v),f.size));b.write(v.tobytes());b.write(f.tobytes())
 out.mkdir(parents=True,exist_ok=True);asset=b.getvalue();(out/'HumanSkeleton.vkskeleton').write_bytes(asset)
 manifest=json.loads((ASSETS/'manifest.json').read_text())
 manifest.update({'status':'mesh-built-pending-native-visual-and-device-acceptance','format':'SKN1','meshSHA256':hashlib.sha256(asset).hexdigest(),'meshBytes':len(asset),
  'triangleCount':total,'vertexCount':sum(len(v) for v,_ in output.values()),'geometryDrawCount':len(output),'sourceElementCount':len(meta),
  'sourceTriangles':sum(stats.values()),'sourcePins':SOURCE_PINS,'generator':'scripts/skeleton-assets/build.py','generatorSHA256':sha(Path(__file__)),'sourceToReview':{'units':'metres','axes':'+X subject-left, +Y superior, +Z anterior','formula':'[x, z + 68.42, -y - 80] / 1000','rotationDeterminant':1},
  'bindContract':'nodeTransform = targetFrame * inverse(sourceBindFrame); raw vertices in shared source-world metres; columns encode semantic lengths, not AABB normalization',
  'sourceLandmarksMeters':{k:v.tolist() for k,v in landmarks.items()},'sourceReferenceWidthMeters':W,'sourceReferenceTorsoHeightMeters':H,
  'visualAcceptance':{'status':'not-accepted','remaining':['Jagged orbital/maxilla/vault facets in native closeup review','Rigid shoulder and source foot yaw require further retarget review','Physical camera and sustained GPU/CPU profiling not recorded'],'scopeDecision':'User asked to close current skeleton integration and prioritize game work before further art iterations.'},
  'landmarkEvidence':'Art-reviewed articulating-surface joint-centre estimates in source anatomy; not captured ARKit pivots. Physical-device alignment remains required.',
  'originalCosmeticGeometry':{'teeth':'28 seated closed crowns with varied incisor/canine/premolar/molar profiles; original geometry, no sensed facial articulation','triangleCount':len(tooth_mesh()[1])},
  'excludedDuplicateElements':{'FJ2772':'Geometry identical to selected FJ3201 hyoid'},
  'connectingStructures':'Explicit costal cartilage from source; no intervertebral disks, eye/lacrimal soft tissue, muscle or organ surfaces.',
  'parts':partmeta,'elements':meta})
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(f'Wrote {total} triangles, {len(asset)} bytes, {manifest["meshSHA256"]}',flush=True)
 return manifest
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,default=ROOT/'cache');p.add_argument('--output',type=Path,default=ASSETS);p.add_argument('--budget',type=int,default=52000);args=p.parse_args();build(args.cache,args.output,args.budget)
