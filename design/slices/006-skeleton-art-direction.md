# Slice 006 — Anatomical skeleton hit reveal

Status: visual target frozen for implementation, 2026-09-05. The user rejected the first model's quality and requested a dedicated design team. Art direction owns this brief; the combat-rendering owner owns the model and material implementation; integration owns application wiring and acceptance. This is the next visual slice after slice 005. It retains the existing gameplay contract and 280 ms confirmed-hit lifetime.

## The visual job

In a fraction of a second, show a convincing human skeleton inside the correctly identified opponent and make the confirmed hit legible. The visual should feel like a premium tactical game's brief anatomical scan: believable bone structure, clear depth, restrained light, and a strong human silhouette. The scene remains visible around and between the bones. This is a cosmetic anatomical template, not a medical reconstruction of the player's body.

The deliverable is an actual retargetable 3D mesh rendered in the native game. Concept images, turntable drawings, passing tests, and increased polygon counts cannot substitute for that mesh or prove its visual quality. If concept images are made, label them as concept art and review them separately from renders of the implementation.

## Why the existing model fails

The reviewed evidence is `design/evidence/005-shared-combat/skeleton-front.png` and `skeleton-three-quarter.png`, rendered from the actual `SkeletonAnatomyModel` geometry. They establish a useful first assembly, but are not accepted for this slice.

| Priority | Observed problem | Required correction |
|---|---|---|
| P0 | The skull reads as a rounded mask with black disks and a grin. | Build real recessed orbital volumes, a distinct brow, cheek arches, nasal opening, maxilla, and a separate angular mandible. The side silhouette must contain forehead, nasal bridge, upper jaw, chin, and mandibular angle. |
| P0 | Limbs read as wire rods attached to balls. | Use tapered, bowed shafts with different proximal and distal joint forms. Give the humerus, radius/ulna, femur, and tibia/fibula distinct profiles. |
| P0 | The pelvis reads as two sharp plates above circular hoops. | Build curved iliac wings with thickness, an open bowl, sacrum, shaped pubic/ischial branches, and noncircular openings. Remove the tray-like horizontal rims. |
| P0 | The ribs read as a ladder of identical tubes. | Shape a narrowing upper chest, fuller middle/lower chest, oblique ribbon-like ribs, and an evident costal arch. Lower ribs must not all end on the same straight line. |
| P1 | Vertebrae read as disconnected beads in a straight column. | Use closely articulated vertebral bodies with posterior processes and a continuous cervical/thoracic/lumbar contour. Hide unconvincing tiny details before sacrificing the column's overall shape. |
| P1 | Shoulder blades are absent; the upper chest is supported by straight sticks. | Add scapulae with curved triangular bodies and a raised spine/acromion; shape the clavicles into shallow S curves. |
| P1 | Uniform bright white flattens depth and clips detail. | Preserve warm midtones, cool shaded recesses, and a controlled rim. Form must read before emission is applied. |
| P1 | Tiny hands and feet look like repeated sticks. | Give them a coherent palm/arch mass, varied digits, visible joint groups, and clear left/right orientation. |

## Geometry and proportion targets

The following measurements are **art targets for a neutral 1.75 m review fixture**, not claims about human population measurements or the dimensions of a tracked player. The live retargeter preserves observed joint positions and segment lengths. Do not force a person's pose into the fixture, move hit volumes to match the artwork, or infer missing sensed landmarks from these values.

| Region | Neutral fixture target | Shape requirement |
|---|---|---|
| Skull | Height 0.215–0.235 m; width 0.145–0.165 m; depth 0.18–0.205 m | The cranial vault is broader above the cheek/jaw region. Eye openings are irregular rounded quadrilaterals with visible inward walls, not black spheres pasted on the surface. |
| Neck | A compact articulated link between the skull base and upper thorax | No floating skull or isolated pearl necklace. The cervical column meets the rear underside of the cranium. |
| Ribcage | Width 0.28–0.33 m; depth 0.20–0.245 m; height 0.34–0.39 m | Upper opening narrower than the lower chest; distinct front, side, and rear curvature; flattened rib section approximately 2:1 rather than circular hose. |
| Pelvis | Width 0.27–0.315 m; height 0.205–0.245 m; depth 0.175–0.215 m | Rounded iliac crests, concave interior, thickened supporting branches, integrated sacrum, and substantial depth from the side. |
| Humerus | Shaft diameter 0.075–0.10 of observed upper-arm length; proximal head diameter 0.14–0.17 | Gentle shaft bow, broader upper head, narrower shaft, differentiated elbow end. |
| Femur | Shaft diameter 0.07–0.095 of observed thigh length; distal breadth 0.15–0.18 | Distinct offset neck/head into the pelvis, outer trochanter, gentle shaft bow, paired lower condyles, and separate forward patella. |
| Forearm | Two visibly different shafts separated through their middle lengths | Radius and ulna differ in taper and end shape. Do not duplicate the same tube twice. |
| Lower leg | Tibia visually carries more mass than the lateral fibula | Tibial crest and broad upper end; finer fibula; ankle end shapes that connect convincingly to the foot. |
| Hand | Length 0.17–0.20 m; palm width 0.075–0.09 m | Carpal cluster, five metacarpal paths, thumb offset from four fingers, varied finger lengths and subtle relaxed curvature. |
| Foot | Length 0.235–0.275 m; width 0.085–0.105 m | Heel and ankle mass, raised midfoot arch, fanned forefoot, short toes, and an evident big toe on the medial side. |

Skull modeling priority is recess and silhouette. Use actual orbital/nasal cavity walls, contouring around the temples, a shallow cheek arch, and a mandibular ramus that returns toward the rear of the skull. Keep teeth subdued and seated in the jaws; a uniformly open toothy grin is an immediate rejection. The cranial vault, face, and mandible should remain distinguishable at a 200 px tall head crop. Anatomical reference: [OpenStax, The Skull](https://openstax.org/books/anatomy-and-physiology-2e/pages/7-2-the-skull).

Preserve twelve rib pairs in the close model. The upper seven connect to the sternum through the visual costal region, the following three contribute to the lower arch, and the final two have free anterior ends. Give the sternum a broader upper manubrium and narrow body rather than a thick vertical rod. These relationships define the shape; exact microscopic detail is unnecessary. Reference: [OpenStax, The Thoracic Cage](https://openstax.org/books/anatomy-and-physiology-2e/pages/7-4-the-thoracic-cage).

Use seven cervical, twelve thoracic, and five lumbar visual vertebrae, followed by an integrated sacrum/coccyx. Make lower vertebral bodies broader, with small dark articulation gaps approximately 10–18% of local pitch. Give the column an S-shaped side contour with a total forward/back excursion of roughly 30–50 mm in the neutral fixture. These are cosmetic rest-shape details attached to the observed torso, not new tracking outputs. Reference: [OpenStax, The Vertebral Column](https://openstax.org/books/anatomy-and-physiology-2e/pages/7-3-the-vertebral-column).

The pelvis must show a hip socket region and a shaped obturator opening under each wing. Use a continuous load-bearing form around these negative spaces instead of a tube ring. The sacrum should merge visually with the pelvis at the back. Reference: [OpenStax, The Pelvic Girdle and Pelvis](https://openstax.org/books/anatomy-and-physiology-2e/pages/8-3-the-pelvic-girdle-and-pelvis).

Hands and feet are neutral cosmetic templates attached to observed wrists/ankles. Their finer articulation is not sensed. Keep the thumb and large toe on the correct side through retargeting; do not mirror the material normals or collapse the arch. Form references: [OpenStax, Bones of the Upper Limb](https://openstax.org/books/anatomy-and-physiology-2e/pages/8-2-bones-of-the-upper-limb) and [Bones of the Lower Limb](https://openstax.org/books/anatomy-and-physiology-2e/pages/8-4-bones-of-the-lower-limb).

Model broad shape first, joint transitions second, recessed details third. Use smooth normals for continuous bone surfaces, deliberate creases at anatomical ridges, and real thickness at exposed rims. No degenerate triangles, inverted normals, conspicuous primitive intersections, open tube ends facing the camera, or paper-thin plates in profile. A smoother sphere is still a sphere; subdivision must serve a shaped surface.

## Material and hit presentation

Use one coherent material family, with stable depth cues in front, side, and rear views. The following values are starting art tokens, subject to actual render review at fixed exposure.

| Token | Target |
|---|---|
| Bone base | Warm ivory `#D8D5C8`; lit peak approximately `#F0EEE4` |
| Recess/shade | Cool slate `#233843`; deeply recessed cavity `#12212B` |
| Hit rim | Muted ice `#8CD5E2`, concentrated on grazing angles |
| Roughness | 0.62–0.78; broad soft response |
| Metalness | 0; bone must not read as chrome or plastic |
| Base emission | 0.02–0.05 relative intensity; anatomy stays shaded |
| Rim emission | Bounded to approximately 0.18 relative intensity; no full-body white replacement |
| Peak bone opacity | 0.88–0.96, with empty space between bones left transparent |
| Bloom | Optional; less than 2 px beyond the silhouette in the 1080 px reference. Disable before reducing shape quality. |

Shade the bone itself and use the cool rim as a brief scan cue. Avoid a wireframe pass, uniform neon outline, opaque body silhouette, or every hidden surface glowing at equal strength. Cavity darkness comes primarily from actual recess geometry; a cavity material can support that shape but cannot replace it. Keep light categories isolated from projectiles and the camera background. Use fixed review lighting without auto-exposure changes so comparison remains honest.

Preserve the current 280 ms visibility window. Within it, a suggested envelope is a fast 0–20 ms reveal, a readable plateau through approximately 100 ms, and a smooth fade that ends at 280 ms. A repeated confirmed hit may restart the existing window; it must never accumulate opacity or spawn another complete model. If exact current fade behavior is already part of tested integration, retain it until the owner accepts a timing-only presentation handoff. Reduced motion uses the same authoritative hit event with a restrained opacity pulse and no scan sweep or bloom.

Keep damage type legible without recoloring every bone bright red. The crosshair hit marker and existing accessible feedback carry the confirmed result; if the renderer can identify the relevant visual region, a restrained localized warm accent can mark that region. A hit-zone label alone does not provide an exact surface impact point. Do not invent a local impact decal from it.

## Runtime contract and bounds

Retain the current typed entry points: `SkeletonAnatomyModel.update(_:zone:)`, `LaserFXEngine.confirmHit`, and `updateSkeleton`. Rendering receives `TargetingSkeleton` and `TargetingHitZone?`; it has no network, hit-validation, collision, or game-rule ownership. Part placement remains separate from mesh construction and material configuration. Any shared API change requires an integration handoff.

| State | Required behavior |
|---|---|
| No confirmed hit | All anatomy hidden; no glow or persistent tracking skeleton. |
| Confirmed hit with fresh, confidently associated body | Show this identified body's anatomical parts for the existing bounded window. |
| Missing observed landmark | Hide dependent parts. Cosmetic details may remain only when their required observed anchors exist. |
| Stale tracking or lost target association | Hide immediately; do not leave a ghost skeleton at the last pose. |
| Unassociated terminal hit | Show the ordinary confirmed marker; do not attach anatomy to an arbitrary nearby person. |
| Repeated hit | Reuse the same pooled model and restart the bounded presentation window. |
| Leave, reconnect, scene inactive, or epoch change | Clear reveal state and release transient effects through existing lifecycle cleanup. |

Initial rendering budgets are acceptance targets to measure, not claimed performance: at most 45,000 triangles and 32 geometry draw calls per visible full-detail skeleton; at most three remote skeleton instances in a four-player match if the product later requires simultaneous reveals. Reuse immutable geometry/material resources; create no meshes, lights, textures, or nodes in pose updates. The currently supported single visible associated-target model remains sufficient unless integration changes that presentation contract.

Use screen-space detail levels only when profiling shows a need: full form above 600 px body height; medium target at most 18,000 triangles for 240–600 px; distant target at most 6,000 below 240 px. Preserve skull/jaw, ribcage shape, pelvis openings, limb pairs, hands, and feet at every level. Simplify small sutures, tiny teeth, and fine phalangeal surfaces first. Add approximately 10% threshold hysteresis and choose a level at reveal start to prevent a visible switch within 280 ms. Detail selection never affects colliders, target association, weapon timing, or hit validation.

## Review evidence and acceptance

1. Render the **actual native mesh** in a neutral standing fixture from front, rear, left/right profile, and 45° three-quarter views. Use the same 1.75 m fixture, fixed exposure, neutral key/fill lights, 1080 × 1440 output, and approximately 80% frame height. Include unlit silhouette renders and close crops of skull, shoulder/back, pelvis, hand, and foot. No image generation or retouching of these evidence renders.
2. Render observed-landmark fixture poses for elbows bent to 90°, crouch, a torso turn, and one missing wrist/ankle. Check believable connections, normal handedness, clipping, and truthful missing-part behavior. The template must not pretend to track finger curl or head yaw that the incoming observations do not establish.
3. Review 3 m, 8 m, and 15 m equivalent camera projections with the same 60° vertical field of view and 1080 px image height. Approximate upright projected heights are 546, 205, and 109 px respectively. The skull/rib/pelvis/limb silhouette must still read at distance; individual teeth are not a distant acceptance criterion. Repeat on dark, middle-gray, and bright backgrounds before actual camera composites.
4. Capture an actual rendered 280 ms reveal sequence at 0, 20, 100, 180, and 280 ms, including repeated-hit and stale-observation cases. At 280 ms there is no lingering anatomy unless a later confirmed hit restarted the window. Art review of still images alone cannot accept timing.
5. Record on-device camera evidence naming the device model and iOS version: upright/moving/crouching opponent, indoor and outdoor backgrounds, 3/8/15 m, and the four-player workload. Record frame-time/GPU cost and memory for sustained combat, with and without the reveal. Initial target is no more than 1 ms added CPU and 2 ms added GPU at p95 for one visible skeleton; revise a budget only with recorded evidence and integration agreement. A desktop SceneKit render proves form only.

Art acceptance requires a clear human silhouette in all review views, a skull with real facial depth, continuous believable torso/limb connections, a shaped ribcage and pelvis, correctly oriented hands/feet, and readable material depth without clipping. Integration and a reviewer independent of the mesh author inspect the actual renders. Any P0 defect in the review table blocks acceptance even when all tests pass.

Keep the rejected first evidence under slice 005 as history. New evidence should name the source revision, mesh triangle/draw counts, camera and lighting settings, fixture pose, and whether the image is a synthetic native render or physical camera capture. Do not mark this slice complete until the implementation and its relevant evidence exist.

## Provenance

The current geometry is original procedural work. The linked anatomy pages are structure references; their diagrams, text, and downloadable models are not imported into the game. Current source licensing must be checked before any asset reuse. Do not label an asset CC0 merely because it is downloadable or hosted by a museum/university.

If a third-party anatomical mesh is selected, store its exact source URL, author/publisher, asset identifier/version, download date, license URL and saved license text, original-file SHA-256, attribution requirements, redistribution/commercial-use permission, modifications, and conversion steps next to the asset manifest. Retain required attribution in the shipped app. A license restricted to noncommercial use does not satisfy this production game. Prefer original geometry or an individually verified CC0/compatible commercial asset; an unavailable or uncertain license is a reason to choose another asset, not to postpone the authorized original-model rebuild.
