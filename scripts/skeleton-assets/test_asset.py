"""Asset contract/invariant checks. These establish packaging, never visual/device quality."""
import hashlib, json, struct, unittest
from pathlib import Path
import numpy as np
from build import ASSETS,ROOT,PART_ORDER,SKULL,bind_frames,load_sources,read_obj,arc_between

def read_binary(data):
 assert data[:4]==b'SKN1'
 offset=8;parts={}
 count=struct.unpack_from('<I',data,4)[0]
 for _ in range(count):
  n=struct.unpack_from('<H',data,offset)[0];offset+=2
  name=data[offset:offset+n].decode();offset+=n
  bind=np.frombuffer(data,dtype='<f4',count=16,offset=offset).reshape(4,4).T;offset+=64
  nv,ni=struct.unpack_from('<II',data,offset);offset+=8
  vertices=np.frombuffer(data,dtype='<f4',count=nv*10,offset=offset).reshape(-1,10);offset+=nv*40
  faces=np.frombuffer(data,dtype='<u4',count=ni,offset=offset).reshape(-1,3);offset+=ni*4
  assert name not in parts
  parts[name]=(bind,vertices,faces)
 assert offset==len(data)
 return parts

class ShippedAssetTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.data=(ASSETS/'HumanSkeleton.vkskeleton').read_bytes()
  cls.manifest=json.loads((ASSETS/'manifest.json').read_text())
  cls.parts=read_binary(cls.data)
 def test_hash_size_counts_and_exact_semantic_parts(self):
  self.assertEqual(hashlib.sha256(self.data).hexdigest(),self.manifest['meshSHA256'])
  self.assertEqual(len(self.data),self.manifest['meshBytes'])
  self.assertEqual(list(self.parts),PART_ORDER)
  total=sum(len(f) for _,_,f in self.parts.values())
  self.assertEqual(total,self.manifest['triangleCount']);self.assertLessEqual(total,52000)
  self.assertEqual(len(self.parts),19);self.assertLess(len(self.data),8_388_608)
 def test_vertices_are_finite_normalized_and_indices_valid(self):
  for part,(bind,v,f) in self.parts.items():
   with self.subTest(part=part):
    self.assertTrue(np.isfinite(v).all());self.assertLessEqual(abs(v[:,:3]).max(),5)
    self.assertTrue(((v[:,6:]>=0)&(v[:,6:]<=1)).all())
    self.assertTrue(np.allclose(np.linalg.norm(v[:,3:6],axis=1),1,atol=.0001))
    self.assertLess(f.max(),len(v));self.assertGreater(len(f),0)
    area=np.linalg.norm(np.cross(v[f[:,1],:3]-v[f[:,0],:3],v[f[:,2],:3]-v[f[:,0],:3]),axis=1)
    self.assertTrue((area>1e-12).all())
 def test_bind_frames_are_affine_orthogonal_right_handed(self):
  expected,_,_,_=bind_frames()
  for part,(bind,_,_) in self.parts.items():
   with self.subTest(part=part):
    self.assertTrue(np.allclose(bind[3],[0,0,0,1]))
    self.assertGreater(np.linalg.det(bind[:3,:3]),0)
    axes=bind[:3,:3]/np.linalg.norm(bind[:3,:3],axis=0)
    self.assertTrue(np.allclose(axes.T@axes,np.eye(3),atol=1e-6))
    self.assertTrue(np.allclose(bind,expected[part],atol=1e-7))
    self.assertTrue(np.allclose(bind,np.array(self.manifest['parts'][part]['bindTransformColumnMajor']).reshape(4,4).T,atol=1e-7))
 def test_anatomical_selection_has_no_soft_tissue_or_repeated_ids(self):
  self.assertEqual(set(self.manifest['parts']['skull']['elements']),set(SKULL))
  ids=[e for p in self.manifest['parts'].values() for e in p['elements']]
  self.assertEqual(len(ids),len(set(ids)))
  for side in ['left','right']:
   self.assertEqual(len(self.manifest['parts'][side+'Hand']['elements']),27)
   self.assertEqual(len(self.manifest['parts'][side+'Foot']['elements']),26)
  self.assertEqual(len(self.manifest['parts']['spine']['elements']),17)
  self.assertEqual(len(self.manifest['parts']['cervicalSpine']['elements']),8)
  for e in ids:
   n=self.manifest['elements'][e]['name'].lower()
   self.assertFalse(any(x in n for x in ['muscle','artery','vein','lacrimal gland','eyeball','intervertebral disk']))
 def test_source_landmarks_confirm_shared_axes(self):
  p=self.manifest['sourceLandmarksMeters']
  self.assertGreater(p['left_arm_joint'][0],p['right_arm_joint'][0])
  self.assertGreater(p['head'][1],p['root'][1])
  self.assertGreater(p['root'][1],p['leftFoot'][1])
  self.assertEqual(self.manifest['sourceToReview']['rotationDeterminant'],1)
 @unittest.skipUnless((ROOT/'cache/partof_BP3D_4.0_obj_99.zip').exists(),'Pinned source cache optional in ordinary app checkout')
 def test_source_duplicate_hyoid_is_exact_geometry_and_anterior_sentinels(self):
  _,_,z=load_sources(ROOT/'cache')
  a,af,_,_=read_obj(z,'FJ2772');b,bf,_,_=read_obj(z,'FJ3201')
  self.assertTrue(np.array_equal(a,b));self.assertTrue(np.array_equal(af,bf))
  patella,_,_,_=read_obj(z,'FJ3275');femur,_,_,_=read_obj(z,'FJ3259')
  self.assertGreater(patella[:,2].mean(),femur[:,2].mean())
  sternum,_,_,_=read_obj(z,'FJ3178');spine,_,_,_=read_obj(z,'FJ3168')
  self.assertGreater(sternum[:,2].mean(),spine[:,2].mean())
  # This named middle-toe phalanx is anterior to heel in the original anatomy.
  toe,_,_,_=read_obj(z,'FJ3180');heel,_,_,_=read_obj(z,'FJ3256')
  self.assertGreater(toe[:,2].mean(),heel[:,2].mean())

if __name__=='__main__':unittest.main()
