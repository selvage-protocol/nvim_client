/**
 * The host's half of the grant: what a listing is read off a working copy, and how far a path a
 * peer named is allowed to reach.
 *
 * Everything here is exercised on a real directory tree under this checkout's `.tmp/`, never on
 * the host's own: the point of the boundary is that a path from the other end of the session is
 * not trusted, and a test that cannot put a symbolic link in the way is not testing it.
 *
 * The case worth reading closely is the directory link. A link to a *file* is caught by the
 * leaf's own `lstat`, which is the check a suite is tempted to stop at; a link to a *directory*
 * is not, because the leaf behind it is an ordinary file that a `stat` would vouch for. The path
 * travels *through* the link, and no such path was ever listed. The last case is the same link
 * one moment later: a directory that is a link by the time the segment after it is resolved.
 */

import assert from 'node:assert/strict';
import { mkdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import test, { after, before } from 'node:test';

import { MAX_GRANT_FILE_BYTES, MAX_GRANT_PATHS } from '../vendor/bridge/index.ts';
import { enumerateGrant, readGrantedFile } from '../companion/grant.ts';

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

test('a listing carries the files, never the directories', async () => {
  await put('listing/b.txt');
  await put('listing/a/deep.txt');
  await put('listing/c.txt');
  assert.deepEqual(await enumerateGrant(join(ROOT, 'listing')), [
    'a/deep.txt',
    'b.txt',
    'c.txt',
  ]);
});

test('a listing is written ascending by UTF-16 code unit', async () => {
  // U+1F9F5 is a surrogate pair (D83E DD75) and U+E000 is a single unit (E000). By code point —
  // and so by UTF-8 byte, which is what Neovim's own `table.sort` compares — the astral name
  // sorts *after* U+E000; by UTF-16 code unit it sorts before it, and that is the order the
  // protocol fixes for a listing (`PROTOCOL.md` §5, vector 022).
  await put('order/\u{1f9f5}.txt');
  await put('order/\u{e000}.txt');
  await put('order/z.txt');
  assert.deepEqual(await enumerateGrant(join(ROOT, 'order')), [
    'z.txt',
    '\u{1f9f5}.txt',
    '\u{e000}.txt',
  ]);
});

test('a listing leaves out what the grant excludes', async () => {
  await put('excluded/.git/config', '[core]\n');
  await put('excluded/.env', 'TOKEN=1\n');
  await put('excluded/.env.local', 'TOKEN=1\n');
  await put('excluded/node_modules/left-pad/index.js');
  await put('excluded/target/debug/build');
  await put('excluded/dist/bundle.js');
  await put('excluded/.hg/store');
  await put('excluded/kept.txt');
  assert.deepEqual(await enumerateGrant(join(ROOT, 'excluded')), ['kept.txt']);
});

test('a listing stops at the count it will carry', async () => {
  const many = join(ROOT, 'many');
  mkdirSync(many, { recursive: true });
  const names = Array.from({ length: MAX_GRANT_PATHS + 1 }, (_unused, index) =>
    String(index).padStart(5, '0'),
  );
  for (const name of names) {
    writeFileSync(join(many, `${name}.txt`), 'x\n');
  }
  const paths = await enumerateGrant(many);
  assert.equal(paths.length, MAX_GRANT_PATHS);
  // Which names survive the truncation follows the same order the listing is written in, so the
  // first of them is the first name and the tail is what is missing — not whatever the file
  // system happened to hand back first.
  assert.equal(paths[0], '00000.txt');
  assert.equal(paths.at(-1), '04999.txt');
  assert.ok(!paths.includes('05000.txt'));
});

test('a listing carries no symbolic link', async () => {
  const outside = join(ROOT, 'outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'the host never shared this\n');
  const linked = join(ROOT, 'linked');
  mkdirSync(linked, { recursive: true });
  writeFileSync(join(linked, 'here.txt'), 'this one is in the folder\n');
  symlinkSync(join(outside, 'secret.txt'), join(linked, 'file-link.txt'));
  symlinkSync(outside, join(linked, 'escape'));
  assert.deepEqual(await enumerateGrant(linked), ['here.txt']);
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
  // And nothing behind the link is listed, so it is not a path the grant ever named.
  assert.deepEqual(await enumerateGrant(root), []);
});

test('a segment that is a file is not walked through', async () => {
  await put('through/file.txt');
  await put('through/not-a-dir.txt');
  const root = join(ROOT, 'through');
  assert.equal(await readGrantedFile(root, 'not-a-dir.txt/file.txt'), undefined);
});

test('a name that is a link by the time the next segment is resolved serves nothing outside', async (t) => {
  const scratch = join(ROOT, 'swap');
  const root = join(scratch, 'root');
  const outside = join(scratch, 'outside');
  const parked = join(scratch, 'parked');
  // Deep enough that the name at the top of the path is resolved once for every segment under
  // it: one swap lands inside that window rather than after the read has finished.
  const deep = Array.from({ length: 20 }, (_unused, index) => `d${index}`);
  const asked = ['race', ...deep, 'f.txt'].join('/');
  mkdirSync(join(root, 'race', ...deep), { recursive: true });
  writeFileSync(join(root, 'race', ...deep, 'f.txt'), 'the file the folder holds\n');
  mkdirSync(join(outside, ...deep), { recursive: true });
  writeFileSync(join(outside, ...deep, 'f.txt'), 'a file outside the folder\n');

  // The name the path walks through, swapped between the real directory and a link out of the
  // folder: one `renameSync` and one `symlinkSync` inside a turn of the event loop, so a read
  // sees either the directory or the link and never a state in between. A read that resolves the
  // segments one at a time can still be *between* two of them when this lands.
  let linked = false;
  const flip = (): void => {
    if (linked) {
      rmSync(join(root, 'race'), { force: true });
      renameSync(parked, join(root, 'race'));
      linked = false;
      return;
    }
    renameSync(join(root, 'race'), parked);
    symlinkSync(outside, join(root, 'race'));
    linked = true;
  };
  let flips = 0;
  const flipping = setInterval(() => {
    flips += 1;
    flip();
  }, 0);
  t.after(() => {
    clearInterval(flipping);
    rmSync(scratch, { recursive: true, force: true });
  });

  let reads = 0;
  let inside = 0;
  let refused = 0;
  let leaked: string | undefined;
  // Bounded by both a count and a deadline: a read is tens of `await`s, and the count is what a
  // run without the pinning needs to hit one of them (it takes a handful of reads).
  const deadline = Date.now() + 5000;
  while (reads < 300 && leaked === undefined && Date.now() < deadline) {
    reads += 1;
    const text = await readGrantedFile(root, asked);
    if (text === 'the file the folder holds\n') {
      inside += 1;
      continue;
    }
    if (text !== undefined) {
      leaked = text;
      break;
    }
    refused += 1;
  }

  assert.equal(
    leaked,
    undefined,
    `${reads} reads while the name was swapped ${flips} times served a file from outside the folder: ${JSON.stringify(leaked)}`,
  );
  // Both states have to have been read through, or the reads above say nothing: a name that was
  // never a link is not the case this test is for, and one that was never a directory is not a
  // read at all.
  assert.ok(
    inside > 0 && refused > 0,
    `the name was not both a directory and a link under the reads: ${reads} reads, ${flips} swaps, ${inside} inside, ${refused} refused`,
  );
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
