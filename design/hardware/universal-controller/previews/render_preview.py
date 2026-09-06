"""Render actual STL triangles using a software depth buffer; no Blender needed."""
from pathlib import Path
import os
os.environ.setdefault('MPLCONFIGDIR', '/private/tmp/pewpew-mpl-cache')
import json
import numpy as np
import trimesh
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT/'exports'/'assembly-manifest.json').read_text())
BG = '#f2f0e9'
INK = '#203236'
MUTED = '#586864'


def scene(exploded):
    meshes=[]
    for part in manifest['parts']:
        base=trimesh.load_mesh(ROOT/'exports'/part['file'])
        for inst in part['instances']:
            mesh=base.copy(); mesh.apply_transform(inst['transform'])
            if exploded:
                mesh.apply_translation(inst.get('explode',[0,0,0]))
            meshes.append((mesh,np.array(inst['color'][:3])))
    for ref in manifest['references']:
        # The phone and purchased switch are dimensional reference envelopes.
        if 'switch_body' in ref['id']:
            continue
        bounds=np.array(ref['bounds_mm'])
        mesh=trimesh.creation.box(extents=bounds[1]-bounds[0])
        mesh.apply_translation(bounds.mean(axis=0))
        color=np.array(ref['color'][:3])
        if 'phone' in ref['id']:
            color=np.array([.63,.72,.71])
            if exploded: mesh.apply_translation([0,-45,18])
        meshes.append((mesh,color))
    return meshes


def render(exploded=False, camera=False):
    meshes=scene(exploded)
    az=np.deg2rad(48 if camera else -57); el=np.deg2rad(17)
    toward=np.array([np.cos(el)*np.cos(az),np.cos(el)*np.sin(az),np.sin(el)])
    right=np.array([-np.sin(az),np.cos(az),0])
    up=np.cross(toward,right)
    basis=np.stack([right,up,toward],axis=1)
    points=np.concatenate([m.vertices@basis for m,c in meshes])
    lo,hi=points.min(axis=0),points.max(axis=0)
    width,height=720,1100
    scale=min((width-64)/(hi[0]-lo[0]),(height-75)/(hi[1]-lo[1]))
    centre=(lo+hi)/2
    depth=np.full((height,width),-np.inf)
    canvas=np.empty((height,width,3)); canvas[:]=[242/255,240/255,233/255]
    light=(toward*.7+up*.8-right*.45); light/=np.linalg.norm(light)
    for mesh,color in meshes:
        v=(mesh.vertices@basis-centre)
        v[:,0]=v[:,0]*scale+width/2
        v[:,1]=-v[:,1]*scale+height/2
        for face,normal in zip(mesh.faces,mesh.face_normals):
            if normal@toward < -1e-6: continue
            a,b,c=v[face]
            xmin=max(0,int(np.floor(min(a[0],b[0],c[0])))); xmax=min(width-1,int(np.ceil(max(a[0],b[0],c[0]))))
            ymin=max(0,int(np.floor(min(a[1],b[1],c[1])))); ymax=min(height-1,int(np.ceil(max(a[1],b[1],c[1]))))
            if xmin>xmax or ymin>ymax: continue
            den=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
            if abs(den)<1e-9: continue
            yy,xx=np.mgrid[ymin:ymax+1,xmin:xmax+1]; xx=xx+.5; yy=yy+.5
            u=((b[1]-c[1])*(xx-c[0])+(c[0]-b[0])*(yy-c[1]))/den
            w=((c[1]-a[1])*(xx-c[0])+(a[0]-c[0])*(yy-c[1]))/den
            t=1-u-w
            z=u*a[2]+w*b[2]+t*c[2]
            region=depth[ymin:ymax+1,xmin:xmax+1]
            mask=(u>=-1e-7)&(w>=-1e-7)&(t>=-1e-7)&(z>region)
            region[mask]=z[mask]
            shade=.48+.52*max(0,float(normal@light))
            canvas[ymin:ymax+1,xmin:xmax+1][mask]=np.clip(color*shade,0,1)
    return canvas

fig=plt.figure(figsize=(16,10),facecolor=BG)
fig.text(.055,.94,'PEW PEW  /  HARDWARE LAB',fontsize=12,fontweight='bold',color=MUTED)
fig.text(.055,.885,'One grip. Adjustable fit.',fontsize=32,fontweight='bold',color=INK)
fig.text(.055,.845,'Universal phone controller  ·  v0 mechanical fit prototype',fontsize=13,color=MUTED)
for rect,exploded,camera in [([.025,.205,.30,.61],False,False),([.35,.205,.30,.61],False,True),([.675,.205,.30,.61],True,True)]:
    ax=fig.add_axes(rect);ax.imshow(render(exploded,camera));ax.axis('off')
for x,num,title,detail in [(.075,'01','Player side','Portrait phone • sliding side jaws'),(.385,'02','Camera side','Open upper camera area • button trigger'),(.705,'03','Assembly study','Separate prints • removable grip cover')]:
    fig.text(x,.18,num,fontsize=11,fontweight='bold',color='#bd541e')
    fig.text(x,.15,title,fontsize=17,fontweight='bold',color=INK)
    fig.text(x,.12,detail,fontsize=10,color=MUTED)
fig.text(.055,.064,'65–90 mm case width     /     7–17 mm case thickness     /     replaceable lining + rigid shims',fontsize=12,color=INK)
fig.text(.055,.032,'Rendered from exported CAD meshes. Phone/button blocks show fit envelopes. Fit, retention, print strength and Bluetooth are untested.',fontsize=9,color=MUTED)
fig.savefig(ROOT/'previews'/'controller-preview.png',dpi=170,facecolor=BG)
plt.close(fig)
print(ROOT/'previews'/'controller-preview.png')
