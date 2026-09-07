#!/usr/bin/env python3
"""VKZ modular arcade controller v2: regeneration in millimetres, no Blender.
Only nominal phone dimensions are configurable; fixed joints require review.
"""
import argparse
import importlib.metadata
import json
import platform
import re
from pathlib import Path
import numpy as np
import manifold3d as m
import trimesh

OUT = Path(__file__).resolve().parent.parent / 'exports'
P = dict(phone_width=77., phone_thickness=11, phone_height=155.)
JOINTS = [(8.,-24.), (35.,-56.), (5.,-94.), (52.,-5.)]
DOCK = [(x,y) for x in (-10.,10.) for y in (5.,15.5)]
PLATE = [-13.,-44.]

def box(x0,x1,y0,y1,z0,z1):
    return m.Manifold.cube((x1-x0,y1-y0,z1-z0)).translate((x0,y0,z0))
def union(*a): return m.Manifold.batch_boolean(a,m.OpType.Add)
def sub(a,*b): return m.Manifold.batch_boolean([a,*b],m.OpType.Subtract)
def cyl(axis,a,b,c,r,n=64):
    s=m.Manifold.cylinder(b-a,r,circular_segments=n)
    if axis=='x': return s.rotate((0,90,0)).translate((a,*c))
    if axis=='y': return s.rotate((-90,0,0)).translate((c[0],a,c[1]))
    return s.translate((*c,a))
def hexx(axis,a,b,c,af=5.8): return cyl(axis,a,b,c,af/np.sqrt(3),6)
def yz(x0,x1,y0,y1,z0,z1,r):
    return union(*[cyl('x',x0,x1,(y,z),r) for y in (y0+r,y1-r) for z in (z0+r,z1-r)]).hull()
def xz(x0,x1,y0,y1,z0,z1,r):
    return union(*[cyl('y',y0,y1,(x,z),r) for x in (x0+r,x1-r) for z in (z0+r,z1-r)]).hull()
def sweep(s):
    a=s^box(-200,200,-200,200,-45,200)
    b=s^box(-200,200,-200,200,-200,-45)
    return union(a,b.transform([[1,0,0,0],[0,1,.35,15.75],[0,0,1,0]]))
def slot(a,b,z,y0,y1,r): return union(cyl('y',y0,y1,(a,z),r),cyl('y',y0,y1,(b,z),r)).hull()

def housing():
    a=union(sweep(yz(-19,19,0,46,-108,-4.4,5)),box(-19,19,0,58,-16,-4.4),box(-17.7,17.7,57,64,-13,-1))
    cavity=sweep(yz(-16,16,3,39,-104,-8.4,3))
    guard=sub(yz(-19,19,28,88,-66,-8,8),yz(-20,20,35,80,-58,-17,7),box(-13,13,-100,100,-100,100),box(-30,30,57.7,100,-17.3,100))
    a=sub(union(a,guard),cavity)
    bosses=[cyl('x',-19,19,c,5.5) for c in JOINTS]
    bosses += [cyl('z',-16,-4,c,5.5) for c in DOCK]
    bosses += [cyl('y',32,42,(0,z),4.3) for z in PLATE]
    a=union(a,*bosses)
    cuts=[box(-15.2,15.2,42,60,-49.2,-7.8),box(-11.5,11.5,38,60,-40,-17)]
    cuts += [cyl('x',-20,20,c,1.7) for c in JOINTS]
    cuts += [hexx('x',16.3,20,c) for c in JOINTS]
    for x,y in DOCK:
        cuts += [cyl('z',-17,1,(x,y),1.7),hexx('z',-11.7,-9,(x,y)),box(min(0,x),max(0,x),y-2.9,y+2.9,-11.7,-9)]
    for z in PLATE: cuts += [cyl('y',31,43,(0,z),1.7),hexx('y',34,36.7,(0,z))]
    cuts += [cyl('x',-25,25,(62,-7),1.7),cyl('y',46,65,(0,-13),3.2)]
    a=sub(a,*cuts)
    left=a^box(-100,0,-200,200,-200,200)
    right=a^box(0,100,-200,200,-200,200)
    lips=[sub(cyl('x',-.1,1.5,c,4),cyl('x',-.2,1.6,c,1.7)) for c in JOINTS]
    left=union(left,*lips)
    right=sub(right,*[cyl('x',-.1,1.8,c,4.3) for c in JOINTS])
    for x,y in [(-10,5),(10,15.5)]:
        pin=sub(cyl('z',-4.1,-2,(x,y),3.5),cyl('z',-4.2,-1.9,(x,y),1.7))
        if x<0: left=union(left,pin)
        else: right=union(right,pin)
    return left,right

def dock():
    a=union(xz(-60,60,20,28,0,38,3),box(-53,53,0,28,-4,2),box(-60,60,20,28,-4,0)); cuts=[]
    for sign in (-1,1):
        lo,hi=sorted((sign*22,sign*34.5))
        for z in (10,28): cuts += [slot(lo,hi,z,19,29,1.7),slot(lo,hi,z,19,22,3.2)]
        cuts += [box(sign*55-1.5,sign*55+1.5,19,29,12,30)]
    for c in DOCK: cuts += [cyl('z',-5,3,c,1.7),cyl('z',0,3,c,3.2)]
    for c in [(-10,5),(10,15.5)]: cuts += [cyl('z',-4.1,-1.7,c,3.8)]
    return sub(a,*cuts)
def nose():
    a=union(xz(-21,21,58,90,-16,2,3),box(21,24,58,90,-11.3,-2.7))
    return sub(a,box(-18,18,57,87,-13.3,-.7),cyl('x',-22,25,(62,-7),1.7),hexx('x',21.3,25,(62,-7)))
def button_plate():
    return sub(xz(-15,15,42,46,-49,-8,2),cyl('y',41,47,(0,-28),8.2),*[cyl('y',41,47,(0,z),1.7) for z in PLATE])
def jaw(right=True):
    i=(P['phone_width']+3)/2
    a=union(box(i,i+4,-4,19.6,2,43.4),box(i-6,i+4,-4,0,2,12),box(i-25,i+4,28.4,33.4,3,43.4),box(i-25,i+4,19.6,33.4,38.4,43.4))
    a=sub(a,*[cyl('y',27,35,(i-12,z),1.7) for z in (10,28)],*[hexx('y',30.7,34.4,(i-12,z)) for z in (10,28)])
    return a if right else a.mirror((1,0,0))
def shim(t): return xz(-6,6,0,t,5,29,1.5)
def coupon():
    a=union(box(0,30,0,22,0,4),box(34,64,0,22,0,4),box(29,35,10,12,0,2),cyl('z',3.9,5.5,(8,11),4),box(2,28,25,37,0,6),box(6,10,21,26,0,2),box(20,24,21,26,0,2))
    cuts=[cyl('z',-1,7,(8,11),1.7),cyl('z',2.2,5,(42,11),4.3),cyl('z',-1,7,(42,11),1.7),hexx('z',3.3,7,(8,31)),cyl('z',-1,7,(8,31),1.7),hexx('z',-1,2.7,(22,31)),cyl('z',-1,7,(22,31),1.7),cyl('y',24,38,(15,3),1.7)]
    for i,d in enumerate((3.2,3.3,3.4,3.5)): cuts.append(cyl('z',-1,5,(20 if i%2==0 else 56,5+12*(i//2)),d/2))
    return sub(a,*cuts)
def mesh_of(s):
    a=s.to_mesh(); return trimesh.Trimesh(vertices=np.asarray(a.vert_properties)[:,:3],faces=np.asarray(a.tri_verts),process=True)
def count(mesh):
    p=list(range(len(mesh.faces)))
    def f(i):
        while p[i]!=i: p[i]=p[p[i]]; i=p[i]
        return i
    for a,b in mesh.face_adjacency: p[f(int(a))]=f(int(b))
    return len({f(i) for i in range(len(p))})
def translate(x=0,y=0,z=0):
    a=np.eye(4);a[:3,3]=[x,y,z];return a

def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--phone-width',type=float,default=77);cli.add_argument('--phone-thickness',type=int,default=11);cli.add_argument('--phone-height',type=float,default=155)
    args=cli.parse_args()
    if not 65<=args.phone_width<=90 or not 7<=args.phone_thickness<=17 or args.phone_height<60: cli.error('Width65–90; integer thickness7–17; height≥60mm.')
    P.update(phone_width=args.phone_width,phone_thickness=args.phone_thickness,phone_height=args.phone_height)
    OUT.mkdir(parents=True,exist_ok=True)
    a,b=housing()
    solids={'housing_left':a,'housing_right':b,'phone_dock':dock(),'nose_cap':nose(),'button_plate':button_plate(),'jaw_left':jaw(False),'jaw_right':jaw(True),**{f'shim_{t}mm':shim(t) for t in (1,2,4,8)},'fit_coupon':coupon()}
    for old in ('grip_cradle.stl','grip_cover.stl'): (OUT/old).unlink(missing_ok=True)
    manifest=dict(format_version=2,design_revision='modular-arcade-blaster-v2',units='mm',status='UNPRINTED_FABRICATION_FIT_PROTOTYPE',parameters=P,
        axes={'x':'width; housing seamX0','y':'forward/camera side; screen faces−Y','z':'up; phone bottomZ3'},parts=[],references=[],validation={},assembly_relationships=[],fasteners=[],assembly_steps=[])
    manifest['fixed_design_dimensions']=dict(housing_wall_nominal_mm=3,shell_width_mm=38,shell_seam_gap_mm=0,shell_lip_od_mm=8,shell_socket_id_mm=8.6,shell_lip_length_mm=1.5,shell_socket_depth_mm=1.8,dock_locator_od_mm=7,dock_socket_id_mm=7.6,dock_locator_height_mm=2,dock_socket_depth_mm=2.3,nose_tongue_clearance_mm=.3,button_bore_mm=16.4,button_panel_thickness_mm=4,nut_pocket_across_flats_mm=5.8,nut_pocket_depth_mm=2.7)
    stack={};cursor=20;remaining=18-P['phone_thickness']
    for t in (8,4,2,1):
        if remaining>=t: cursor-=t;stack[t]=cursor;remaining-=t
    labels=['Left housing and grip','Right housing and grip','Universal phone dock','Closed arcade nose cap','Button trigger plate','Left sliding jaw','Right sliding jaw','Rigid shim 1 mm','Rigid shim 2 mm','Rigid shim 4 mm','Rigid shim 8 mm','Joint and hardware fit coupon']
    faces={
      'housing_left':('Exterior left faceX−19; cavity up',[0,-90,0],'No broad roof; inspect nut channels, locating lips and horizontal bores for local support.'),
      'housing_right':('Exterior right faceX19; cavity up',[0,90,0],'No broad roof; inspect nut channels and bores; clear hex pockets before assembly.'),
      'phone_dock':('Shelf bottomZ−4',[0,0,0],'Rear plate prints upright; inspect horizontal slots/recesses and locating sockets for short bridges.'),
      'nose_cap':('Closed frontY90; cavity up',[-90,0,0],'No cavity roof; cross-bolt/nut openings may need local support.'),
      'button_plate':('Flat rearY42',[90,0,0],'Flat4mm plate; no designed overhang.'),
      'jaw_left':('Exterior side wall',[0,-90,0],'Inspect flange, bores and captive-nut pockets for local support.'),
      'jaw_right':('Exterior side wall',[0,90,0],'Inspect flange, bores and captive-nut pockets for local support.'),
      'fit_coupon':('Flat baseZ0',[0,0,0],'Print without scaling; cut only thin joining neck for male/female fit trial.')}
    colors={'housing_left':[1,.4,.05,1],'housing_right':[1,.4,.05,1],'phone_dock':[.12,.16,.22,1],'nose_cap':[.04,.78,.85,1],'button_plate':[.04,.78,.85,1],'jaw_left':[.04,.78,.85,1],'jaw_right':[.04,.78,.85,1]}
    exploded={'housing_left':[-35,0,0],'housing_right':[35,0,0],'phone_dock':[0,0,30],'nose_cap':[0,36,0],'button_plate':[0,28,-6],'jaw_left':[-30,0,30],'jaw_right':[30,0,30]}
    geometry={}
    for index,(name,solid) in enumerate(solids.items(),1):
        source=mesh_of(solid); face,angles,supports=faces.get(name,('Broad flat face',[90,0,0],'Flat shim; no designed overhang.'))
        R=trimesh.transformations.euler_matrix(*np.radians(angles)); output=source.copy();output.apply_transform(R)
        shift=translate(*(-output.bounds[0]));output.apply_transform(shift);T=np.linalg.inv(shift@R)
        filename=name+'.stl';output.export(OUT/filename);reloaded=trimesh.load_mesh(OUT/filename,process=True);components=count(reloaded)
        assert reloaded.is_watertight and reloaded.is_winding_consistent and components==1 and reloaded.volume>0,(name,components)
        assert max(reloaded.extents[:2])<=180 and reloaded.extents[2]<50,(name,reloaded.extents)
        bottom=np.all(np.abs(reloaded.triangles[:,:,2])<1e-5,axis=1);area=float(reloaded.area_faces[bottom].sum());assert area>20,(name,area)
        instances=[]
        if name.startswith('shim_'):
            t=int(name.split('_')[1].removesuffix('mm'))
            if t in stack:
                for sign in (-1,1): instances.append(dict(id=f'{name}_{sign}',transform=(translate(x=sign*9,y=stack[t])@T).tolist(),color=[.4,.46,.52,1],explode=[sign*8,-28,30]))
        elif name!='fit_coupon':
            instances=[dict(id=name,transform=T.tolist(),color=colors[name],explode=exploded[name])];geometry[name]=solid
        manifest['parts'].append(dict(id=name,drawing_id=index,label=labels[index-1],file=filename,quantity_to_print=2 if name.startswith('shim_') else 1,instances=instances,spare_only=not bool(instances),print_orientation=face,print_face=face,supports=supports,bounds_mm=reloaded.bounds.tolist(),dimensions_mm=reloaded.extents.tolist(),assembled_source_bounds_mm=source.bounds.tolist(),volume_mm3=float(reloaded.volume),surface_area_mm2=float(reloaded.area),flat_bed_contact_area_mm2=area,vertices=len(reloaded.vertices),triangles=len(reloaded.faces),watertight=True,winding_consistent=True,connected_components=components))
    manifest['references']=[dict(id='phone_envelope_not_printable',bounds_mm=[[-P['phone_width']/2,1,3],[P['phone_width']/2,1+P['phone_thickness'],3+P['phone_height']]],color=[.16,.19,.25,.5]),dict(id='switch_body_clearance_not_printable',bounds_mm=[[-9.1,17,-37.1],[9.1,42,-18.9]],color=[.13,.15,.19,.5]),dict(id='switch_button_not_printable',bounds_mm=[[-9.1,46,-37.1],[9.1,51,-18.9]],color=[1,.15,.25,1])]
    intersections=[];keys=list(geometry)
    for i,a in enumerate(keys):
        for b in keys[i+1:]:
            v=float((geometry[a]^geometry[b]).volume());intersections.append(dict(a=a,b=b,intersection_mm3=v));assert abs(v)<.001,(a,b,v)
    exclusions=[]
    for width in (65,P['phone_width'],90):
        for thickness in (7,P['phone_thickness'],17):
            e=box(-width/2,width/2,1,1+thickness,3,3+P['phone_height'])
            for name,s in geometry.items():
                if name.startswith('jaw_'): s=s.translate((((width-P['phone_width'])/2)*(1 if name.endswith('right') else -1),0,0))
                v=float((s^e).volume());exclusions.append(dict(exclusion='phone',width_mm=width,thickness_mm=thickness,part=name,intersection_mm3=v));assert abs(v)<.001,('phone',name,v)
    for name,e in dict(switch_body=box(-9.1,9.1,17,42,-37.1,-18.9),switch_shaft=cyl('y',42,46,(0,-28),7.8),switch_button=box(-9.1,9.1,46,51,-37.1,-18.9)).items():
        for part,s in geometry.items():
            v=float((s^e).volume());exclusions.append(dict(exclusion=name,part=part,intersection_mm3=v));assert abs(v)<.001,(name,part,v)
    hw=[]
    for c in JOINTS: hw.append(('J1',union(cyl('x',-19,21,c,1.5),cyl('x',-20.65,-19,c,2.85),hexx('x',16.3,18.7,c,5.5))))
    for c in DOCK: hw.append(('J2',union(cyl('z',-12,0,c,1.5),cyl('z',0,1.65,c,2.85),hexx('z',-11.7,-9.3,c,5.5))))
    hw.append(('J3',union(cyl('x',-21,24,(62,-7),1.5),cyl('x',-22.65,-21,(62,-7),2.85),hexx('x',21.3,23.7,(62,-7),5.5))))
    for z in PLATE: hw.append(('J4',union(cyl('y',34,46,(0,z),1.5),cyl('y',46,47.65,(0,z),2.85),hexx('y',34.3,36.7,(0,z),5.5))))
    checks=[]
    for width in (65,P['phone_width'],90):
        for sign in (-1,1):
            for z in (10,28):
                c=(sign*((width+3)/2-12),z);e=union(cyl('y',22,34,c,1.5),cyl('y',20.35,22,c,2.85),hexx('y',30.7,33.1,c,5.5))
                for name,s in geometry.items():
                    if name.startswith('jaw_'): s=s.translate((((width-P['phone_width'])/2)*(1 if name.endswith('right') else -1),0,0))
                    v=float((e^s).volume());checks.append(dict(joint='J5',width_mm=width,part=name,intersection_mm3=v));assert abs(v)<.001,('jaw hardware',width,name,v)
    for joint,e in hw:
        for name,s in geometry.items():
            v=float((e^s).volume());checks.append(dict(joint=joint,part=name,intersection_mm3=v));assert abs(v)<.001,(joint,name,v)
    # Head-size insertion corridors are stricter than final static envelopes.
    # J4 must be installed with the nose absent, as the assembly steps require.
    access=[]
    corridors=[]
    corridors += [('J1 head insertion',cyl('x',-60,-19,c,2.85),set()) for c in JOINTS]
    corridors += [('J2 head insertion',cyl('z',1.65,70,c,2.85),set()) for c in DOCK]
    corridors += [('J3 head insertion',cyl('x',-60,-21,(62,-7),2.85),set())]
    corridors += [('J4 head insertion; nose absent',cyl('y',46,110,(0,z),2.85),{'nose_cap'}) for z in PLATE]
    for joint,envelope,absent in corridors:
        for name,s in geometry.items():
            if name in absent: continue
            v=float((envelope^s).volume());access.append(dict(joint=joint,part=name,intersection_mm3=v));assert abs(v)<.001,('insertion',joint,name,v)
    for width in (65,P['phone_width'],90):
        for sign in (-1,1):
            for z in (10,28):
                center=(sign*((width+3)/2-12),z);envelope=cyl('y',-30,20.35,center,2.85)
                for name,s in geometry.items():
                    if name.startswith('jaw_'): s=s.translate((((width-P['phone_width'])/2)*(1 if name.endswith('right') else -1),0,0))
                    v=float((envelope^s).volume());access.append(dict(joint='J5 head insertion',width_mm=width,part=name,intersection_mm3=v));assert abs(v)<.001,('jaw insertion',width,name,v)
    # Side-load dock nuts into their owner's open half before shell closure.
    for x,y in DOCK:
        entry=-4 if x>0 else 4
        envelope=union(hexx('z',-11.7,-9.3,(entry,y),5.5),hexx('z',-11.7,-9.3,(x,y),5.5)).hull()
        name='housing_right' if x>0 else 'housing_left';v=float((envelope^geometry[name]).volume())
        access.append(dict(joint='J2 captive nut insertion into open half',part=name,intersection_mm3=v));assert abs(v)<.001,('nut insertion',x,y,v)
    for z in PLATE:
        envelope=union(hexx('y',34.3,36.7,(4,z),5.5),hexx('y',34.3,36.7,(0,z),5.5)).hull()
        v=float((envelope^geometry['housing_left']).volume());access.append(dict(joint='J4 captive nut insertion into open left half',part='housing_left',intersection_mm3=v));assert abs(v)<.001,('plate nut insertion',z,v)
    def record(jid,length,axis,centers,seat,nut,role):
        return dict(id=jid,size=f'M3 × {length} mm',type='button-head machine bolt and standardM3 nut',quantity=len(centers),length_mm=length,axis=axis,centers=centers,head_seat_axis_positions_mm=seat,nut_axis_range_mm=nut,nut_across_flats_mm=5.5,nut_thickness_mm=2.4,modeled_nut_pocket_af_mm=5.8,clearance_bore_mm=3.4,role=role,engagement='Full nominal2.4mm nut thickness; verify purchased hardware.',access='Follow assembly order; seat inaccessible nuts before closure.')
    manifest['fasteners']=[record('J1',40,'+X',[[0,y,z] for y,z in JOINTS],[-19]*4,[16.3,18.7],'Close shell seam. Four annular locating lips. Thread ends project2.3mm beyond nuts.'),record('J2',12,'−Z',[[x,y,-4] for x,y in DOCK],[0]*4,[-11.7,-9.3],'Dock load path; recessed heads beneath removable liner.'),record('J3',45,'+X',[[0,62,-7]],[-21],[21.3,23.7],'Closed cap on receiver tongue; external side access.'),record('J4',12,'−Y',[[0,42,z] for z in PLATE],[46]*2,[34.3,36.7],'Button plate, installed before nose. Seam-captured nuts.'),record('J5',12,'+Y',[[s*((P['phone_width']+3)/2-12),28,z] for s in (-1,1) for z in (10,28)],[22]*4,[30.7,33.1],'Sliding jaws. Recessed front heads and rear captive nuts. Adjust with phone removed.')]
    instructions=[
      ([12],'Print coupon with intended settings. Check3.4mm bore and5.8mmAF nut pocket using real hardware. Cut thin neck to trial8mm lip in8.6mm socket. Hole options3.2/3.3/3.4/3.5mm; never scale whole model to correct fit.'),
      ([1,2],'Deburr and dry-fit shell lips, dock pins and nose tongue. Inspect nut channels and remove supports.'),
      ([1,2,5],'With housing open, seat and temporarily retain FOUR J2 dock nuts in side-access pockets and TWO J4 triggerplate nuts in seam pockets. They become inaccessible after closure. Fit purchased momentary switch and supplied nut to plate; verify4mm panel and free travel. Restrain insulated prototype wiring; no battery holder provided.'),
      ([1,2],'Close shell locating lips. Install FOUR J1 M3×40 bolts from left and nuts in right external hex pockets. Tighten gently and evenly; inspect protruding thread ends.'),
      ([5],'Install TWO J4 M3×12 plate bolts into preloaded nuts, approaching from forward side with nose absent. Check button travel and wiring.'),
      ([4],'Seat nose over receiver tongue. Install ONE J3 M3×45 bolt and nut using side access. Closed tip faces forward.'),
      ([3],'Seat dock on two pins and four boss faces. Install FOUR J2 M3×12 bolts into preloaded nuts. Phone and bottom liner must be absent for access.'),
      ([6,7],'Seat FOUR jaw nuts in rear hex pockets. Fit jaws over dock. Install FOUR J5 M3×12 bolts through front slots; set width and tighten with phone removed.'),
      ([8,9,10,11],'Use two equal rigid shim stacks totaling18 minus case thickness in mm. Mandatory soft rear/front/bottom liners1mm and side liners1.5mm nominal. Retain shims with thin tape; include tape thickness in allowance.'),
      ([3,6,7],'Bench-fit an inert phone-sized block first. Add15mm hook-and-loop strap through wing slots/across lower screen. Check ports, controls, retention and trigger reach before any physical trial.')]
    manifest['assembly_steps']=[dict(step=i,parts=parts,instruction=text) for i,(parts,text) in enumerate(instructions,1)]
    manifest['assembly_relationships']=[dict(parent='housing_left',children=['housing_right'],joint='J1',constraint='SeamX0; fourØ8×1.5mm lips intoØ8.6×1.8mm sockets.'),dict(parent='housing_left + housing_right',children=['phone_dock'],joint='J2',constraint='SeatingZ−4; twoØ7×2mm pins intoØ7.6×2.3mm sockets.'),dict(parent='housing_left + housing_right',children=['nose_cap'],joint='J3',constraint='SeatY58; tongueX±17.7/Z−13..−1; socketX±18/Z−13.3..−0.7.'),dict(parent='housing_left + housing_right',children=['button_plate'],joint='J4',constraint='SeatY42; flat4mm panel;0.2mm edge clearance.'),dict(parent='phone_dock',children=['jaw_left','jaw_right'],joint='J5',constraint='Case65–90mm; side foam1.5mm; plate sliding clearance0.4mm.'),dict(parent='phone_dock',children=['shim_1mm','shim_2mm','shim_4mm','shim_8mm'],constraint='StacksX±9/Z5..29, rearY20; selected '+ '+'.join(map(str,stack))+'mm.')]
    manifest['assumptions']=[
      'Target width65–90mm and thickness7–17mm include case; not every phone. Mount covers lower40.4mm and may conflict with buttons/ports/UI.',
      'All boltsM3 button-head, maximumØ5.7×1.65mm; nuts5.5mmAF×2.4mm. No washers assumed.15bolts:4×40mm,1×45mm,10×12mm;15nuts.',
      'Additional purchased16mm momentary switch, soft lining, tape and15mm restraint strap. No electronics or battery restraint supplied.',
      'Shells print on planar exterior faces with open cavities up. Local holes/nut channels may need bridging/support; inspect slicer.',
      'Print fit, torque, load, impact, retention, heat, ergonomics and wiring are untested. Geometric checks do not establish physical performance.',
      'Harmless controller only: closed arcade nose, no physical laser/emitter mount, projectile channel or firearm interface.',
      'Do not mixv1 body/cover or M4 jaw hardware withv2. This revision usesM3 throughout.'
    ]
    manifest['coupon_features']=dict(coordinate_frame='Coupon STL coordinates, millimetres; Z=0 is bed.',cut_instruction='Saw only the thin neck centered at X=32, Y=10..12, Z=0..2. Flip the separated female plate so its socket faces the male lip; their broad top faces should meet without forcing.',vertical_bores=[dict(diameter_mm=d,center_mm=[x,y]) for d,x,y in [(3.2,20,5),(3.3,56,5),(3.4,20,17),(3.5,56,17)]],horizontal_bore=dict(diameter_mm=3.4,axis='+Y',center_xz_mm=[15,3],span_y_mm=[25,37]),male_lip=dict(center_xy_mm=[8,11],outside_diameter_mm=8,height_mm=1.5),female_socket=dict(center_xy_mm=[42,11],diameter_mm=8.6,depth_mm=1.8),nut_pockets=[dict(center_xy_mm=[8,31],across_flats_mm=5.8,depth_mm=2.7,opening='up'),dict(center_xy_mm=[22,31],across_flats_mm=5.8,depth_mm=2.7,opening='toward bed; tests pocket bridging')])
    manifest['validation']=dict(stl_reloaded=True,all_parts_watertight=True,all_parts_single_connected_solid=True,positive_volume=True,max_print_height_mm=max(p['dimensions_mm'][2] for p in manifest['parts']),planar_bed_contact_measured=True,nominal_assembly_intersections=intersections,phone_and_switch_exclusions=exclusions,actual_hardware_envelope_checks=checks,head_and_nut_insertion_checks=access,physical_testing='NONE; geometry does not prove printer fit, strength or real-tool access.')
    prose_keys={'label','print_orientation','print_face','supports','instruction','constraint','role','engagement','access','type','physical_testing'}
    def readable(value,key=''):
        if isinstance(value,dict): return {k:readable(v,k) for k,v in value.items()}
        if isinstance(value,list): return [readable(v,key) for v in value]
        if isinstance(value,str) and (key in prose_keys or key=='assumptions'):
            value=re.sub(r'(?<=\d)(?=[A-Za-z])',' ',value)
            value=re.sub(r'(?<=[A-Za-z])(?=M[34]\b)',' ',value)
            value=value.replace('×',' × ').replace('Ø','Ø ')
            value=re.sub(r'\b([XYZ])(?=[−+0-9])',r'\1 = ',value)
        return value
    manifest=readable(manifest)
    (OUT/'assembly-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (OUT/'cad-environment.json').write_text(json.dumps(dict(python=platform.python_version(),packages={n:importlib.metadata.version(n) for n in ('manifold3d','trimesh','numpy')}),indent=2)+'\n')
    print(json.dumps(dict(parts=len(solids),watertight=True,connected=True,max_print_height_mm=manifest['validation']['max_print_height_mm']),indent=2))
if __name__=='__main__': main()
