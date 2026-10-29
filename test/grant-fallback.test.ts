/**
 * The folder's own license to be absent, on the walk that names a step by path.
 *
 * `/proc/self/fd` is how a step is taken inside a directory that is already open. A platform that
 * has it refuses a deleted root at the open, before a listing is ever read; the name-by-path walk
 * has no such open, so a root the host no longer holds reaches the listing itself and has to
 * answer the same absence. The route is chosen once, from the file system the adapter imported,
 * so this file pins that choice at its own import boundary: `existsSync` answers `/proc/self/fd`
 * absent for the life of the process, which is what a platform without it reports. Nothing of the
 * adapter is stubbed — the same real reader over the same real directories — and the
 * listing-fault conversion itself is a real `readdir` failure injected at that reader.
 */

import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { join, resolve } from 'node:path';
import test, { after, before } from 'node:test';

import type { GrantedRead } from '../vendor/bridge/index.ts';
import { withReaddirFault } from './helpers/readdir-fault.ts';

interface SyncFs {
  existsSync: (path: string) => boolean;
}

const fs = createRequire(import.meta.url)('node:fs') as SyncFs;
const realExistsSync = fs.existsSync;
fs.existsSync = (path: string): boolean => (path === '/proc/self/fd' ? false : realExistsSync(path));
syncBuiltinESMExports();

// The query gives this evaluation of the adapter its own module instance, so the pinned-step
// choice reads the boundary this file set whatever order the runner loaded the other test files
// in. The literal in the type position is the same module, for the result's own shape.
const adapter = '../companion/grant.ts?unpinned';
const { readGrantedFile, readGrantedPresence } = (await import(adapter)) as typeof import('../companion/grant.ts');

/** The cause a read refused with, or `undefined` when it served something. */
function cause(read: GrantedRead): string | undefined {
  return read.kind === 'refused' ? read.cause : undefined;
}

const ROOT = join(resolve(import.meta.dirname, '..', '.tmp'), 'grant-fallback');

before(() => {
  rmSync(ROOT, { recursive: true, force: true });
  mkdirSync(join(ROOT, 'faulted', 'sub'), { recursive: true });
  writeFileSync(join(ROOT, 'faulted', 'sub', 'deep.txt'), 'deep\n');
  writeFileSync(join(ROOT, 'faulted', 'here.txt'), 'here\n');
  mkdirSync(join(ROOT, 'gone', 'sub'), { recursive: true });
  writeFileSync(join(ROOT, 'gone', 'sub', 'deep.txt'), 'deep\n');
});

after(() => {
  fs.existsSync = realExistsSync;
  syncBuiltinESMExports();
  rmSync(ROOT, { recursive: true, force: true });
});

test('a root the folder no longer holds is a confirmed absence on the name-by-path walk', async () => {
  const gone = join(ROOT, 'gone');
  rmSync(gone, { recursive: true, force: true });
  assert.equal(
    await readGrantedPresence(gone, 'deep.txt'),
    'missing',
    'a deleted root was read as an unlistable one, not as the path being absent',
  );
  assert.equal(
    await readGrantedPresence(gone, 'sub/deep.txt'),
    'missing',
    'a deleted root was not read as an absent ancestor',
  );
  assert.equal(
    cause(await readGrantedFile(gone, 'deep.txt')),
    'missing',
    "the content read's refusal for a deleted root changed",
  );
});

test('a listing the host is refused is an unknown, not an absence, on that walk', async () => {
  const root = join(ROOT, 'faulted');
  for (const code of ['EIO', 'EACCES']) {
    await withReaddirFault(code, [root], async () => {
      assert.equal(await readGrantedPresence(root, 'here.txt'), 'unknown', `${code}: the root leaf`);
      assert.equal(await readGrantedPresence(root, 'sub/deep.txt'), 'unknown', `${code}: through the root`);
      assert.equal(
        cause(await readGrantedFile(root, 'here.txt')),
        'missing',
        `${code}: the content read's refusal changed`,
      );
    });
    await withReaddirFault(code, [join(root, 'sub')], async () => {
      assert.equal(await readGrantedPresence(root, 'sub/deep.txt'), 'unknown', `${code}: the leaf's own parent`);
      assert.equal(await readGrantedPresence(root, 'here.txt'), 'present', `${code}: a sibling at the root`);
    });
  }
});

test('an ancestor the walk finds gone at its listing is an absence, not a fault', async () => {
  const root = join(ROOT, 'faulted');
  await withReaddirFault('ENOENT', [join(root, 'sub')], async () => {
    assert.equal(
      await readGrantedPresence(root, 'sub/deep.txt'),
      'missing',
      'an ancestor gone at its listing was read as a fault',
    );
  });
});

test('the restored host still answers a name it holds and one it does not', async () => {
  const root = join(ROOT, 'faulted');
  assert.equal(await readGrantedPresence(root, 'sub/deep.txt'), 'present');
  assert.equal(await readGrantedPresence(root, 'absent.txt'), 'missing');
});
