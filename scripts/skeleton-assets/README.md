# Anatomical skeleton asset build

This is the durable, offline reproducible source for the application's real indexed bone mesh. The runtime asset is `ios/VictoriaKillZone/VictoriaKillZone/Features/Game/SkeletonAssets/HumanSkeleton.vkskeleton`. The generator and source fingerprints survive restarts in the repository. The downloaded public source archive and tools live in ignored `cache/`, `work/`, and `.venv/` folders; the 64 MB archive is not shipped in the app or committed.

The current candidate contains 19 geometry groups and 51,796 triangles in 1,695,385 bytes. Integration approved the provisional 52,000-triangle art budget on 2026-09-05 to preserve cranial shape and seated teeth. This does not establish device frame cost. Native visual review still rejects jagged skull/maxilla/vault details; source foot yaw and rigid shoulder alignment remain review limitations. The user requested closing this integration and prioritizing game work before another art iteration. Do not label this candidate visually accepted or production performance verified.

## Rebuild

Use Python 3.12 with the exact requirements. Only `fetch.py` needs the network; it downloads explicit public files and rejects a hash change instead of silently accepting a new upstream version.

```sh
python3 -m venv scripts/skeleton-assets/.venv
scripts/skeleton-assets/.venv/bin/pip install -r scripts/skeleton-assets/requirements.txt
scripts/skeleton-assets/.venv/bin/python scripts/skeleton-assets/fetch.py
scripts/skeleton-assets/.venv/bin/python scripts/skeleton-assets/build.py
scripts/skeleton-assets/.venv/bin/python -m unittest discover -s scripts/skeleton-assets -p 'test_*.py' -v
```

A cached rebuild is offline. `build.py --output scripts/skeleton-assets/work/rebuild` lets a reviewer compare the binary SHA without modifying the shipped asset. Binary output is deterministic with the pinned dependency versions; `manifest.json` records source, element, generator and output hashes, transformations, counts and per-part selection. `export_skull_review.py` emits the full source skull and actual packaged skull as standalone OBJ files under ignored `work/` for comparison through native rendering. `inspect_source.py` prints original anatomical bounds for source review.

## Source and modifications

Source: [BodyParts3D version 4.0, FMA 3.0 PART-OF archive](https://dbarchive.biosciencedbc.jp/en/bodyparts3d/download.html), provided by the Database Center for Life Science. The official publisher's [current license](https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html), updated 2025-02-27, grants CC BY 4.0 reuse. Required attribution, full CC BY 4.0 text and the saved official license page are included beside the shipped asset. Historical OBJ headers retain CC BY-SA 2.1 Japan text; the current publisher grant is saved explicitly rather than erasing that history.

Conversion selects the 22 cranial bones frozen in design slice 006, seven cervical vertebrae, 17 thoracic/lumbar vertebrae, ribs/sternum and explicit costal cartilage, pelvic bones/sacrum, paired limbs, 27 bones per hand and 26 per foot. No eyes, lacrimal glands, disks, muscle or organs are included. The source table lists identical hyoid geometry under two IDs; the generator omits `FJ2772` and retains `FJ3201`, and an offline source test verifies equality.

Each selected element is simplified independently with deterministic quadratic error collapse; coincident vertices and degenerate faces are removed within that element. Cranial allocations are explicit to avoid spending the visual budget on dense internal ethmoid/vomer surfaces. Two mild Taubin smoothing passes apply to cranial geometry. Other anatomical elements retain individual shape and relative source positions. Per-vertex normals and low-contrast geometry-derived cavity shading are computed offline. No camera-dependent lighting is baked. Twenty-eight original rounded tooth crowns add restrained closed dentition because the source has no teeth. They are cosmetic geometry, not measured dental anatomy.

## Coordinate and bind contract

The only whole-source axis/unit conversion is `[x, z + 68.42, -y - 80] / 1000` from OBJ millimetres. It has a positive determinant and establishes subject-left +X, superior +Y, anterior +Z. Vertices remain in that single shared world. Individual bones are never normalized to independent boxes.

The manifest records art-reviewed source joint-centre estimates based on the source articulating surfaces. These are not measured ARKit pivots or physical-device alignment evidence. Each bind matrix is column-major and maps the part's semantic reference frame into shared source-world metres. The native model transforms geometry by `targetFrame × inverse(sourceBindFrame)`. Torso parts share a root-origin bind; skull/cervical parts use neck origin; limb parts use proximal joints; hands and feet use wrist/ankle origins. Transverse columns use the source humeral-root width; longitudinal columns use the corresponding observed span. Limb superior is distal-to-proximal; shortest-arc transport from the torso's superior axis preserves anterior without reflecting normals or flipping the knee. The source-pose fixture should therefore produce identity node transforms.

The narrow source humeral span versus the frozen review fixture, fixed torso-attached clavicle/scapula groups and source foot toe-out are acknowledged limitations of this cosmetic rigid template. Hit volumes and association never derive from this asset. Runtime reveal remains the existing confirmed-hit window and hides when observation/association becomes invalid.

## Verification limits

Tests validate exact semantic group coverage, manifest/output agreement, normalized finite vertex data, valid nondegenerate triangles, affine positive orthogonal bind frames, source axis sentinels and exclusion of unintended anatomy. They do not prove appearance. Native evidence and independent findings belong in `design/evidence/006-skeleton-model/`. Device camera alignment, sustained rendering cost and real 280 ms combat behavior need the physical-device gates in the repository contract.
