/**
 * The host's half of the grant: how far a path a peer named is allowed to reach.
 *
 * Everything here is exercised on a real directory tree under this checkout's `.tmp/`, never on
 * the host's own: the point of the boundary is that a path from the other end of the session is
 * not trusted, and a test that cannot put a symbolic link in the way is not testing it.
 *
 * The case worth reading closely is the directory link. A link to a *file* is caught by the
 * leaf's own `lstat`, which is the check a suite is tempted to stop at; a link to a *directory*
 * is not, because the leaf behind it is an ordinary file that a `stat` would vouch for. The path
 * travels *through* the link, and no such path was ever listed.
 */

import assert from 'node:assert/strict';
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import test, { after, before } from 'node:test';

import { MAX_GRANT_FILE_BYTES } from '../vendor/bridge/index.ts';
import { readGrantedFile } from '../companion/grant.ts';

const SCRATCH = resolve(import.meta.dirname, '..', '.tmp');
const ROOT = join(SCRATCH, 'grant-unit');

/** Writes a file, making its directories. `body` is text so that a file reads back as itself. */
async function put(path: string, body = 'contents\n'): Promise<void> {
  const absolute = join(ROOT, path);
  await mkdir(join(absolute, '..'), { recursive: true });
  await writeFile(absolute, body);
}

before(() => {
  rmSync(ROOT, { recursive: true, force: true });
  mkdirSync(ROOT, { recursive: true });
});

after(() => {
  rmSync(ROOT, { recursive: true, force: true });
});

test('a plain file in the folder is served as its text', async () => {
  await put('served/notes.txt', 'a dokument twö editors share\n');
  assert.equal(
    await readGrantedFile(join(ROOT, 'served'), 'notes.txt'),
    'a dokument twö editors share\n',
  );
});

test('a nested plain file is served', async () => {
  await put('served/src/main.rs', 'fn main() {}\n');
  assert.equal(await readGrantedFile(join(ROOT, 'served'), 'src/main.rs'), 'fn main() {}\n');
});

test('a path the grant does not name is refused', async () => {
  await put('refused/.git/config', '[core]\n');
  await put('refused/.env', 'TOKEN=1\n');
  await put('refused/dir/file.txt');
  const root = join(ROOT, 'refused');
  const notTheGrants = [
    // Outside the folder, by a segment or by an absolute name.
    '../outside.txt',
    'dir/../../outside.txt',
    '/etc/hostname',
    // The excludes the grant is defined by, whatever the file system holds there.
    '.git/config',
    '.env',
    '.env.local',
    // A directory is not a document.
    'dir',
    // A name that resolves somewhere else is not one of the host's.
    'dir\\file.txt',
    '',
    // Not there at all.
    'missing.txt',
  ];
  for (const path of notTheGrants) {
    assert.equal(await readGrantedFile(root, path), undefined, `${path} was served`);
  }
});

test('a symbolic link to a file is not served', async () => {
  const outside = join(ROOT, 'link-outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'not the host\'s to hand out\n');
  const root = join(ROOT, 'link-leaf');
  mkdirSync(root, { recursive: true });
  // A real file in the folder, so the link's target is a readable plain file and only the link
  // itself can be what refuses it.
  symlinkSync(join(outside, 'secret.txt'), join(root, 'secret.txt'));
  assert.equal(await readGrantedFile(root, 'secret.txt'), undefined);
});

test('a path through a directory link is not served', async () => {
  const outside = join(ROOT, 'escape-outside');
  mkdirSync(join(outside, 'inner'), { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'the folder this session shares does not hold this\n');
  writeFileSync(join(outside, 'inner', 'deeper.txt'), 'nor this\n');
  const root = join(ROOT, 'escape-root');
  mkdirSync(root, { recursive: true });
  symlinkSync(outside, join(root, 'escape'));
  // Every one of these is a readable *plain* file at the leaf: only walking the segments finds
  // the link. A guard that stopped at the leaf would serve both.
  for (const path of ['escape/secret.txt', 'escape/inner/deeper.txt']) {
    assert.equal(await readGrantedFile(root, path), undefined, `${path} was served through a link`);
  }
});

test('a segment that is a file is not walked through', async () => {
  await put('through/file.txt');
  await put('through/not-a-dir.txt');
  const root = join(ROOT, 'through');
  assert.equal(await readGrantedFile(root, 'not-a-dir.txt/file.txt'), undefined);
});

test('bytes a session cannot carry are refused', async () => {
  await writeFile(join(ROOT, 'bytes-nul'), Buffer.from([0x61, 0x00, 0x62]));
  await writeFile(join(ROOT, 'bytes-latin1'), Buffer.from([0x61, 0xff, 0xfe, 0x62]));
  assert.equal(await readGrantedFile(ROOT, 'bytes-nul'), undefined);
  assert.equal(await readGrantedFile(ROOT, 'bytes-latin1'), undefined);
});

test('a file over the size a session carries is refused, and one at it is not', async () => {
  await writeFile(join(ROOT, 'big.txt'), Buffer.alloc(MAX_GRANT_FILE_BYTES + 1, 0x61));
  await writeFile(join(ROOT, 'at-the-limit.txt'), Buffer.alloc(MAX_GRANT_FILE_BYTES, 0x61));
  assert.equal(await readGrantedFile(ROOT, 'big.txt'), undefined);
  assert.equal(
    (await readGrantedFile(ROOT, 'at-the-limit.txt'))?.length,
    MAX_GRANT_FILE_BYTES,
  );
});
