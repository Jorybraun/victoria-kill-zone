#!/usr/bin/env python3
"""Fetch only explicitly pinned public anatomical source files. No app runtime network use."""
from pathlib import Path
import argparse, hashlib, urllib.request
PINS={
 'partof_BP3D_4.0_obj_99.zip':('9fbc713fffeee924a5a657d9813d84d7eb957bded63adb854931dd5e3eb61c97',64888505),
 'partof_parts_list_e.txt':('9224080557053e6f1322f1e13ab27f0ecde0db19bb3b505f0631afad230eeebd',59351),
 'partof_element_parts.txt':('3f5f6df1028eb122b30de77c711597b6bb8e5541658e5985859fd228adbf88ea',651179),
}
BASE='https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/'
def fetch(cache):
 cache.mkdir(parents=True,exist_ok=True)
 for name,(digest,_) in PINS.items():
  path=cache/name
  if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==digest:
   print('Verified cached',name);continue
  staging=path.with_suffix(path.suffix+'.download')
  try:
   with urllib.request.urlopen(BASE+name,timeout=60) as source,staging.open('wb') as output:
    size=0
    while chunk:=source.read(131072):
     size+=len(chunk)
     if size>70_000_000:raise ValueError('Unexpected source size')
     output.write(chunk)
   if hashlib.sha256(staging.read_bytes()).hexdigest()!=digest:raise ValueError('Source changed: '+name+'; do not silently repin')
   staging.replace(path);print('Fetched and verified',name)
  finally:
   staging.unlink(missing_ok=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,default=Path(__file__).resolve().parent/'cache');fetch(p.parse_args().cache)
