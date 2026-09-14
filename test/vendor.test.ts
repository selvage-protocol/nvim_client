/**
 * The vendored copy is the seam's editor-independent half, and the only thing that keeps it
 * usable from a second editor is that it never reaches for the first one. A `vscode` import
 * anywhere under `vendor/` means `scripts/sync-engine.sh` copied something that does not
 * belong here, and it is cheaper to fail on that than to discover it at run time.
 */

import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../vendor', import.meta.url));

function sources(dir: string): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      found.push(...sources(path));
    } else if (entry.name.endsWith('.ts')) {
      found.push(path);
    }
  }
  return found;
}

test('the vendored engine and bridge are there', () => {
  const files = sources(root).map((path) => path.slice(root.length + 1));
  assert.ok(files.includes(join('engine', 'engine.ts')), files.join(', '));
  assert.ok(files.includes(join('bridge', 'bridge.ts')), files.join(', '));
});

test('nothing under vendor/ imports an editor', () => {
  for (const path of sources(root)) {
    const text = readFileSync(path, 'utf8');
    for (const match of text.matchAll(/from\s+'([^']+)'/g)) {
      assert.notEqual(match[1], 'vscode', `${path} imports vscode`);
    }
  }
});
