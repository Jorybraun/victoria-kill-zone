"""Create a numbered fabrication drawing set from the current STL manifest."""
from pathlib import Path
import textwrap
import re
import json
import numpy as np
import trimesh
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.patches import Circle
from render_preview import ROOT, manifest, scene, rasterize, BG, INK, MUTED

OUT=ROOT/'previews'
PARTS=manifest['parts']
NUMBERS={p['id']:str(p.get('drawing_id',i+1)).zfill(2) for i,p in enumerate(PARTS)}
LABELS={p['id']:p.get('label',p['id'].replace('_',' ').title()) for p in PARTS}


def page(title, subtitle, n):
    fig=plt.figure(figsize=(11.69,8.27),facecolor=BG)
    fig.text(.045,.954,'PEW PEW  /  FABRICATION STUDY',fontsize=9,color=MUTED,weight='bold')
    fig.text(.045,.904,title,fontsize=23,color=INK,weight='bold')
    fig.text(.045,.868,subtitle,fontsize=10,color=MUTED)
    fig.text(.045,.035,'V2 · MILLIMETRES · NOT TO SCALE · UNTESTED FIT PROTOTYPE',fontsize=8,color=MUTED)
    fig.text(.955,.035,f'{n:02d} / 04',fontsize=8,color=MUTED,ha='right')
    return fig


def wrapped(fig,x,y,text,width=80,size=10,line=.024,color=INK):
    for para in str(text).split('\n'):
        for row in textwrap.wrap(para,width=width) or ['']:
            fig.text(x,y,row,fontsize=size,color=color,va='top');y-=line
    return y


def readable(text):
    text=re.sub(r'(?<=[a-z])(?=[XYZ][−0-9])', ' ', text)
    text=re.sub(r'([XYZ])(?=[−0-9])', r'\1 = ', text)
    text=re.sub(r'(?<=[a-z])(?=[0-9])', ' ', text)
    return re.sub(r'(?<=[0-9])mm', ' mm', text)


def quantity_label(part):
    q=part.get('quantity_to_print',1)
    return f'{q} (optional for this fit)' if part['id'].startswith('shim_') and part.get('spare_only') else str(q)


def mesh_for(part):
    return trimesh.load_mesh(ROOT/'exports'/part['file'])


def finish(pdf,fig,name):
    fig.savefig(OUT/f'{name}.png',dpi=150,facecolor=BG)
    pdf.savefig(fig,facecolor=BG)
    plt.close(fig)


with PdfPages(OUT/'fabrication-guide.pdf') as pdf:
    # 1: Numbered exploded assembly; hardware and phone are reference envelopes.
    fig=page('01  /  Print separately. Assemble with fasteners.',
             'Numbered printed components. The phone and purchased switch are separate items.',1)
    meshes=scene(True,False)
    pixels,project=rasterize(meshes,azimuth=34,elevation=21,width=1200,height=1000,margin=240)
    ax=fig.add_axes([.025,.085,.67,.75]);ax.imshow(pixels);ax.axis('off')
    callouts=[]
    for part in PARTS:
        if not part.get('instances'):continue
        inst=part['instances'][0]
        mesh=mesh_for(part);mesh.apply_transform(inst['transform']);mesh.apply_translation(inst.get('explode',[0,0,0]))
        xy=project(mesh.bounds.mean(axis=0))
        callouts.append((xy,NUMBERS[part['id']]))
    for left in (True,False):
        group=sorted([c for c in callouts if (c[0][0]<600)==left],key=lambda c:c[0][1])
        for yy,(target,label) in zip(np.linspace(180,820,max(1,len(group))),group):
            xx=55 if left else 1145
            ax.plot([xx,target[0]],[yy,target[1]],color=MUTED,linewidth=.7)
            ax.add_patch(Circle((xx,yy),21,facecolor=INK,edgecolor=BG,linewidth=1.5,zorder=5))
            ax.text(xx,yy,label,color='white',weight='bold',fontsize=9,ha='center',va='center',zorder=6)
    yy=.81
    for p in PARTS:
        fig.text(.705,yy,NUMBERS[p['id']],fontsize=11,weight='bold',color='#bd541e')
        fig.text(.745,yy,LABELS[p['id']],fontsize=10,weight='bold',color=INK)
        fig.text(.745,yy-.020,f"Print quantity: {quantity_label(p)}",fontsize=8,color=MUTED)
        yy-=.053
    finish(pdf,fig,'01-exploded-assembly')

    # 2: Each model rendered in its exported print orientation, dimensions read
    # from the STL rather than manually restated measurements.
    fig=page('02  /  Individual print files',
             'One STL per part type. Read dimensions as width × depth × build height; check supports in your slicer.',2)
    columns=3;rows=int(np.ceil(len(PARTS)/columns))
    cell_h=.75/rows
    for i,p in enumerate(PARTS):
        col=i%columns;row=i//columns
        x=.045+col*.31;y=.827-row*cell_h
        fig.text(x,y,f"{NUMBERS[p['id']]}  {LABELS[p['id']]}",fontsize=9,weight='bold',color=INK)
        mesh=mesh_for(p)
        color=p.get('instances',[{}])[0].get('color',[.05,.65,.7,1]) if p.get('instances') else [.45,.5,.52,1]
        picture,_=rasterize([(mesh,np.array(color[:3]))],azimuth=-55,elevation=50,width=420,height=190,margin=30)
        ax=fig.add_axes([x,y-cell_h+.054,.135,cell_h-.05]);ax.imshow(picture);ax.axis('off')
        dims=mesh.extents
        fig.text(x+.14,y-.037,' × '.join(f'{v:.1f}' for v in dims)+' mm',fontsize=8,color=INK)
        fig.text(x+.14,y-.059,f"Quantity {quantity_label(p)}",fontsize=8,color=MUTED)
        note=p.get('print_face',p.get('print_orientation','Inspect supplied orientation.'))
        wrapped(fig,x+.14,y-.082,readable(note),width=29,size=7.3,line=.015)
    finish(pdf,fig,'02-print-parts')

    # 3: Three orthographic assembly views, with dimensioned overall envelopes.
    fig=page('03  /  Assembly geometry and joint references',
             'Overall plastic envelopes are derived from the exported meshes. See assembly-design.md for joint details.',3)
    solids=[]
    for p in PARTS:
        for inst in p.get('instances',[]):
            mesh=mesh_for(p);mesh.apply_transform(inst['transform'])
            solids.append((mesh,np.array(inst.get('color',[1,.4,.05])[:3])))
    for rect,az,el,title,axes in [([.035,.39,.30,.41],0,0,'SIDE VIEW · Y/Z',(1,2)),([.35,.39,.29,.41],90,0,'FRONT VIEW · X/Z',(0,2)),([.675,.39,.29,.41],0,90,'TOP VIEW · Y/X',(1,0))]:
        pic,project=rasterize(solids,azimuth=az,elevation=el,width=700,height=720,margin=130)
        ax=fig.add_axes(rect);ax.imshow(pic);ax.axis('off')
        joint_ids=['J1','J3','J4'] if title.startswith('SIDE') else ['J5'] if title.startswith('FRONT') else ['J2']
        for k,jid in enumerate(joint_ids):
            joint=next(j for j in manifest['fasteners'] if j['id']==jid)
            coords=np.array(joint['centers'],dtype=float)
            axis='XYZ'.index(joint['axis'][-1])
            coords[:,axis]=joint['head_seat_axis_positions_mm']
            points=np.array([project(c) for c in coords])
            ax.scatter(points[:,0],points[:,1],s=18,facecolors='none',edgecolors='#bd541e',linewidths=1)
            tx=70 if k%2==0 else 625;ty=150+k*165
            ax.plot([tx,points[0,0]],[ty,points[0,1]],color='#bd541e',linewidth=.8)
            ax.text(tx,ty,jid,fontsize=8,weight='bold',ha='center',va='center',color='white',bbox={'facecolor':'#bd541e','edgecolor':'none','pad':2})
        bounds=np.concatenate([m.bounds for m,c in solids]);dims=bounds.max(axis=0)-bounds.min(axis=0)
        fig.text(rect[0]+.015,.82,title,fontsize=10,weight='bold',color=INK)
        fig.text(rect[0]+.015,.37,f'{dims[axes[0]]:.1f} × {dims[axes[1]]:.1f} mm overall',fontsize=9,color=MUTED)
    fig.text(.05,.295,'JOINTS TO CHECK BEFORE THE FULL PRINT',fontsize=10,weight='bold',color=INK)
    yy=.264
    for joint in manifest['fasteners']:
        desc=f"{joint['id']}  /  {joint['quantity']} × {joint['size']} — {readable(joint['role'])}"
        yy=wrapped(fig,.05,yy,desc,width=133,size=8.5,line=.018)-.009
    finish(pdf,fig,'03-assembly-geometry')

    # 4: Human-authored assembly instructions and BOM live in a compact JSON
    # companion so these exact reviewed instructions also enter the PDF.
    notes_path=ROOT/'fabrication-notes.json'
    notes=json.loads(notes_path.read_text())
    fig=page('04  /  Build order and first-print checks',
             'Fit coupons first, then fasteners and switch, then the housing. Electronics are not supplied or implemented.',4)
    yy=.81
    for i,step in enumerate(notes['assembly_steps'],1):
        fig.text(.05,yy,f'{i:02d}',fontsize=11,weight='bold',color='#bd541e')
        yy=wrapped(fig,.09,yy,step,width=67,size=9.5,line=.021)-.022
    fig.text(.665,.812,'HARDWARE',fontsize=11,weight='bold',color=INK)
    yb=.78
    for item in notes['hardware']:
        yb=wrapped(fig,.665,yb,item,width=43,size=9,line=.022)-.01
    yb-=.025
    fig.text(.665,yb,'BEFORE USING A PHONE',fontsize=10,weight='bold',color=INK);yb-=.031
    wrapped(fig,.665,yb,notes['fit_check'],width=43,size=9,line=.022)
    finish(pdf,fig,'04-build-order')
# Keep the exact coordinate map synchronized with the exported assembly.
lines=['# Generated fastener map — v2', '',
       'Units: millimetres, in assembled coordinates. X is left/right width; Y is forward toward the cameras; Z is up. Coordinates apply to the selected nominal assembly, not the reoriented STL print bed.', '',
       f"Selected phone envelope: {manifest['parameters']['phone_width']} × {manifest['parameters']['phone_height']} × {manifest['parameters']['phone_thickness']} mm (width × height × thickness, including case).", '',
       'Bolt axis is the insertion direction. The axis coordinate in each centre is a reference joint plane; use the head-seat coordinate to locate the underside of the actual bolt head. All heads are button-head, maximum Ø5.7 × 1.65 mm; all nuts are 5.5 mm across flats × 2.4 mm. No washers are modeled.', '',
       '| Joint | Qty / length | Insert | Reference centres (X, Y, Z) | Head seat on axis | Nut extent on axis |',
       '|---|---|---|---|---|---|']
for joint in manifest['fasteners']:
    coords='; '.join('(' + ', '.join(f'{v:g}' for v in c) + ')' for c in joint['centers'])
    seats=', '.join(f'{v:g}' for v in sorted(set(joint['head_seat_axis_positions_mm'])))
    nut=' to '.join(f'{v:g}' for v in joint['nut_axis_range_mm'])
    lines.append(f"| {joint['id']} | {joint['quantity']} × {joint['size']} | {joint['axis']} | {coords} | {seats} | {nut} |")
lines+=['', 'All modeled nuts receive their full nominal 2.4 mm thickness of thread engagement. Actual bolt tolerances and incomplete end threads still require a hardware fit check. J1 thread ends project 2.3 mm beyond the nuts; check these external ends before handling.', '',
        'Seat and retain the four J2 nuts and two J4 nuts while the housing is open. J1 and J3 nuts are accessible from the side. Install the J4 plate before the nose. J2 bolts require the phone and bottom liner to be removed; J5 bolts require the phone removed. A modeled access path does not prove clearance for every screwdriver handle.', '',
        'J5 jaw centres move with phone width: X = ±((case width + 3) / 2 − 12), at Z = 10 and 28. Regenerate the manifest and drawing set when changing the nominal phone dimensions.', '']
coupon=manifest['coupon_features']
lines+=['## Fit coupon feature map', '', coupon['coordinate_frame'], '', coupon['cut_instruction'], '',
        '| Feature | Location in coupon STL |', '|---|---|']
for bore in coupon['vertical_bores']:
    lines.append(f"| Ø{bore['diameter_mm']:g} vertical test hole | X={bore['center_mm'][0]:g}, Y={bore['center_mm'][1]:g} |")
for label,key in [('Male locating lip','male_lip'),('Female locating socket','female_socket')]:
    f=coupon[key];lines.append(f"| {label} | X={f['center_xy_mm'][0]:g}, Y={f['center_xy_mm'][1]:g} |")
for f in coupon['nut_pockets']:
    lines.append(f"| 5.8 mm across-flats nut pocket, {f['opening']} | X={f['center_xy_mm'][0]:g}, Y={f['center_xy_mm'][1]:g} |")
f=coupon['horizontal_bore']
lines+= [f"| Ø{f['diameter_mm']:g} horizontal hole, axis {f['axis']} | X={f['center_xz_mm'][0]:g}, Z={f['center_xz_mm'][1]:g}, Y={f['span_y_mm'][0]:g} to {f['span_y_mm'][1]:g} |", '',
         'The switch gauge is the separate button plate: Ø16.4 mm bore through a 4 mm panel. The coupon does not contain a switch gauge.', '']
(ROOT/'fastener-map.md').write_text('\n'.join(lines))
print(OUT/'fabrication-guide.pdf')
