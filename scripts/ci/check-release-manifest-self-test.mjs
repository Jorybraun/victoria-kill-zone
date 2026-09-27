// Negative regression for check-release-manifest.mjs: copies the checked files
// into a temp root, proves a clean run passes, then proves each mutating the
// checked sites fails closed. Also unit-tests the JSONC comment stripper.
import {execFileSync} from 'node:child_process';
import {cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseJsonc, stripJsonComments} from '../lib/jsonc.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const script = join(root, 'scripts/ci/check-release-manifest.mjs');

// --- JSONC stripper unit checks ---
const parsed = parseJsonc('{\n  // a comment\n  "vars": {"CONVEX_URL": "https://example.convex.cloud"}, /* block */\n  "note": "https://x.test//not-a-comment"\n}');
if (parsed.vars.CONVEX_URL !== 'https://example.convex.cloud' || parsed.note !== 'https://x.test//not-a-comment') {
  throw new Error('stripJsonComments corrupted a string containing //');
}
if (!stripJsonComments('"a\\"//b"').includes('"a\\"//b"')) {
  throw new Error('stripJsonComments mishandled an escaped quote');
}
const commas = parseJsonc('{\n  "a": 1, // trailing in object\n  "list": [1, 2,],\n  "keep": "x,//" , "keep2": "a,}",\n}');
if (commas.a !== 1 || commas.list.length !== 2 || commas.keep !== 'x,//' || commas.keep2 !== 'a,}') {
  throw new Error('parseJsonc must drop trailing commas but keep // and ,} inside strings');
}

// --- Checked-site copy ---
const requiredPaths = [
  'release-manifest.json',
  'contracts/fixtures/combat.v1.json',
  'services/combat-worker/wrangler.jsonc',
  'services/combat-worker/src/index.ts',
  'services/combat-worker/src/room.ts',
  'services/combat-worker/src/projection-store.ts',
  'ios/VictoriaKillZone/VictoriaKillZone/Services/Realtime/CombatWire.swift',
  'convex/functions/combat.ts',
  'spectator/package.json',
];
const temp = mkdtempSync(join(tmpdir(), 'vkz-manifest-self-test-'));
try {
  for (const path of requiredPaths) {
    const target = join(temp, path);
    cpSync(join(root, path), target, {recursive: true});
  }
  cpSync(join(root, 'packages/combat-protocol/src'), join(temp, 'packages/combat-protocol/src'), {recursive: true});

  const run = () => {
    try {
      execFileSync('node', [script], {env: {...process.env, VKZ_MANIFEST_CHECK_ROOT: temp}, stdio: 'pipe'});
      return 0;
    } catch (error) {
      return error.status ?? 1;
    }
  };

  if (run() !== 0) throw new Error('clean temp copy must pass the manifest check');

  const mutate = (path, from, to) => {
    const target = join(temp, path);
    const source = readFileSync(join(root, path), 'utf8');
    if (!source.includes(from)) throw new Error(`${path}: seed ${JSON.stringify(from)} not found`);
    writeFileSync(target, source.replace(from, to));
  };

  const cases = [
    ['packages/combat-protocol/src/validation.ts', '.v !== 1', '.v !== 2'],
    ['services/combat-worker/src/room.ts', 'v: 1', 'v: 2'],
    ['services/combat-worker/src/projection-store.ts', 'v: 1', 'v: 2'],
    ['convex/functions/combat.ts', 'v:1', 'v:2'],
    ['packages/combat-protocol/src/index.ts', 'PROTOCOL_VERSION = 1 as const', 'PROTOCOL_VERSION = 2 as const'],
  ];
  for (const [path, from, to] of cases) {
    mutate(path, from, to);
    if (run() === 0) throw new Error(`${path} mutation ${from} -> ${to} must fail the manifest check`);
    cpSync(join(root, path), join(temp, path)); // restore for the next case
  }

  // Manifest range violations each fail independently.
  const manifestPath = 'release-manifest.json';
  const manifest = JSON.parse(readFileSync(join(root, manifestPath), 'utf8'));
  for (const patch of [{iosMinProtocol: 3}, {iosMinProtocol: 0}, {convexMinProtocol: 99}]) {
    writeFileSync(join(temp, manifestPath), JSON.stringify({...manifest, ...patch}));
    if (run() === 0) throw new Error(`manifest patch ${JSON.stringify(patch)} must fail the manifest check`);
  }
} finally {
  rmSync(temp, {recursive: true, force: true});
}
console.log('check-release-manifest self-test: PASS');
