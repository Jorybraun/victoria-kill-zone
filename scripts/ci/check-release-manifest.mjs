// Ensures every protocol-version literal and release surface in the repo
// agrees with release-manifest.json.
import {createHash} from 'node:crypto';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const manifest = JSON.parse(read('release-manifest.json'));
const failures = [];

if (manifest.manifestVersion !== 1) failures.push('manifestVersion must be 1');
if (!/^[0-9a-f]{40}$/.test(manifest.releaseSha ?? '')) failures.push('releaseSha must be a 40-character hex string');
if (!Number.isSafeInteger(manifest.protocolVersion) || manifest.protocolVersion < 1) failures.push('protocolVersion must be a positive integer');
for (const field of ['doClass', 'doMigrationTag', 'workerVersionTag', 'rulesSchemaHash']) {
  if (typeof manifest[field] !== 'string' || manifest[field].length === 0) failures.push(`${field} must be a nonempty string`);
}
for (const field of ['iosMinProtocol', 'iosMaxProtocol', 'convexMinProtocol']) {
  if (!Number.isSafeInteger(manifest[field])) failures.push(`${field} must be an integer`);
}

// Every protocol-version literal in the repo must equal manifest.protocolVersion.
const literalChecks = [
  ['packages/combat-protocol/src/index.ts', /PROTOCOL_VERSION = (\d+) as const/],
  ['packages/combat-protocol/src/validation.ts', /e\.v !== (\d+)/],
  ['services/combat-worker/src/index.ts', /protocol: (\d+)/],
  ['ios/VictoriaKillZone/VictoriaKillZone/Services/Realtime/CombatWire.swift', /let v = (\d+)/],
  ['convex/functions/combat.ts', /v:(\d+),iss:"vkz-lobby"/],
];
for (const [path, pattern] of literalChecks) {
  const match = read(path).match(pattern);
  if (!match) { failures.push(`${path}: expected literal matching ${pattern} not found`); continue; }
  if (Number(match[1]) !== manifest.protocolVersion) failures.push(`${path}: literal ${match[1]} != manifest protocolVersion ${manifest.protocolVersion}`);
}
const fixture = JSON.parse(read('contracts/fixtures/combat.v1.json'));
if (fixture.protocolVersion !== manifest.protocolVersion) {
  failures.push(`contracts/fixtures/combat.v1.json: protocolVersion ${fixture.protocolVersion} != manifest protocolVersion ${manifest.protocolVersion}`);
}
if (fixture.snapshot?.message?.snapshot && !/^[0-9a-f]{64}$/.test(manifest.rulesSchemaHash)) {
  failures.push('rulesSchemaHash must be a sha256 hex string');
}

// The durable object class and migration tag pin the worker contract.
const wrangler = JSON.parse(read('services/combat-worker/wrangler.jsonc').replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, ''));
const classNames = wrangler.durable_objects?.bindings?.map(b => b.class_name) ?? [];
if (!classNames.includes(manifest.doClass)) failures.push(`wrangler.jsonc durable object classes ${JSON.stringify(classNames)} do not include doClass ${manifest.doClass}`);
const migrations = wrangler.migrations ?? [];
const lastTag = migrations[migrations.length - 1]?.tag;
if (lastTag !== manifest.doMigrationTag) failures.push(`wrangler.jsonc last migration tag ${lastTag} != doMigrationTag ${manifest.doMigrationTag}`);

// The rules schema hash freezes the shape of DEFAULT_RULES.
const temporary = mkdtempSync(join(tmpdir(), 'vkz-manifest-'));
try {
  const require = createRequire(join(root, 'spectator/package.json'));
  const {build} = createRequire(require.resolve('vite'))('esbuild');
  const bundle = join(temporary, 'protocol.mjs');
  await build({entryPoints: [join(root, 'packages/combat-protocol/src/index.ts')], outfile: bundle, bundle: true, platform: 'node', format: 'esm'});
  const {DEFAULT_RULES, rulesSchemaKeyPaths} = await import(bundle);
  const hash = createHash('sha256').update(JSON.stringify(rulesSchemaKeyPaths(DEFAULT_RULES))).digest('hex');
  if (hash !== manifest.rulesSchemaHash) failures.push(`rulesSchemaHash ${manifest.rulesSchemaHash} != computed ${hash}`);
} finally {
  rmSync(temporary, {recursive: true, force: true});
}

if (failures.length > 0) {
  console.error('Release manifest check: FAIL');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('Release manifest check: PASS');
