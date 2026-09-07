// Run from any directory:
//   node scripts/combat-replay/generate.mjs <output.json>
//   node scripts/combat-replay/generate.mjs --check
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../../', import.meta.url));
const fixturePath = 'ios/VictoriaKillZone/VictoriaKillZone/Features/Replay/Fixtures/combat-replay-v1.json';
const [argument, ...extra] = process.argv.slice(2);
const checking = argument === '--check';
if (!argument || extra.length > 0 || (!checking && argument.startsWith('--'))) {
  throw new Error('Usage: node scripts/combat-replay/generate.mjs <output.json> | --check');
}

const require = createRequire(join(root, 'spectator/package.json'));
const { build } = createRequire(require.resolve('vite'))('esbuild');
const temporary = mkdtempSync(join(tmpdir(), 'vkz-replay-generator-'));
try {
  const bundle = join(temporary, 'scenarios.mjs');
  const output = checking ? join(temporary, 'combat-replay-v1.json') : resolve(argument);
  await build({
    entryPoints: [join(root, 'scripts/combat-replay/scenarios.ts')],
    outfile: bundle,
    bundle: true,
    platform: 'node',
    format: 'esm',
  });
  const result = spawnSync(process.execPath, [bundle, output], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error('Replay fixture generation failed.');

  if (checking) {
    const expected = join(root, fixturePath);
    if (!existsSync(expected) || !readFileSync(expected).equals(readFileSync(output))) {
      throw new Error(
        `Combat replay fixture is stale or missing. Regenerate with:\nnode scripts/combat-replay/generate.mjs ${fixturePath}`,
      );
    }
    console.log('Combat replay fixture: PASS');
  }
} finally {
  // Includes bundling errors, engine failures, missing fixtures and mismatches.
  // --check never writes to the committed fixture.
  rmSync(temporary, { recursive: true, force: true });
}
