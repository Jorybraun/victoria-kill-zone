#!/usr/bin/env python3
"""Export pinned source skull and actual packaged skull for native comparison."""
from pathlib import Path
import json, struct
import numpy as np
from build import ROOT,ASSETS,SKULL,load_sources,read_obj,clean,normals

def obj(path,v,f):
 n=normals(v,f)
 with path.open('w') as out:
  out.write('# BodyParts3D, DBCLS, CC BY 4.0. Review-world metres. See shipped NOTICE.\n')
  for p in v:out.write('v %.9f %.9f %.9f\n'%tuple(p))
  for p in n:out.write('vn %.9f %.9f %.9f\n'%tuple(p))
  for t in f+1:out.write('f '+' '.join(f'{i}//{i}' for i in t)+'\n')
def main():
 work=ROOT/'work';work.mkdir(exist_ok=True)
 _,_,z=load_sources(ROOT/'cache');vs=[];fs=[]
 for e in SKULL:
  v,f,_,_=read_obj(z,e);v,f=clean(v,f);fs.append(f+sum(len(a) for a in vs));vs.append(v)
 obj(work/'skull-source.obj',np.concatenate(vs),np.concatenate(fs))
 data=(ASSETS/'HumanSkeleton.vkskeleton').read_bytes();offset=8;n=struct.unpack_from('<H',data,offset)[0];offset+=2
 assert data[offset:offset+n]==b'skull';offset+=n+64
 nv,ni=struct.unpack_from('<II',data,offset);offset+=8
 v=np.frombuffer(data,dtype='<f4',count=nv*10,offset=offset).reshape(-1,10);offset+=nv*40
 f=np.frombuffer(data,dtype='<u4',count=ni,offset=offset).reshape(-1,3)
 obj(work/'skull-packaged.obj',v[:,:3],f)
 print(work)
if __name__=='__main__':main()
