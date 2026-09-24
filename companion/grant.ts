/**
 * The grant, read off the host's working copy.
 *
 * Everything decidable about a listing — which paths it may name, in what order it is written —
 * is in `vendor/bridge/grant.ts`, because both clients have to agree on it. What is left here is
 * this adapter's half: walking a real directory tree with Node's own file system, and resolving a
 * room path back to the file it names. It is the counterpart of `vscode_client`'s
 * `src/adapter/grant.ts`, which does the same over `vscode.workspace.fs`.
 *
 * Resolving a path a *peer* named is the only place a host reads its disk because someone else
 * asked rather than because the user acted, so nothing the path says is trusted: it is held to
 * the grant's own rules, and every directory on the way to it has to be a plain directory of the
 * shared folder rather than a symbolic link out of it.
 */

import { existsSync, type Dirent } from 'node:fs';
import { constants, lstat, open, readdir, type FileHandle } from 'node:fs/promises';
import { join } from 'node:path';

import {
  MAX_GRANT_FILE_BYTES,
  MAX_GRANT_PATHS,
  isBinaryNamedPath,
  isGrantedPath,
  sortGrant,
} from '../vendor/bridge/index.ts';
import type { GrantRefusal, GrantedRead } from '../vendor/bridge/index.ts';

/**
 * The room's grant as the front-end is told it: the listing itself, whole and in the room's order,
 * and — only when there are any — the paths in it that the grant's own rules would never publish.
 *
 * `PROTOCOL.md` §6.3 has a receiver replace its view of the grant with `paths` and never merge or
 * trim it, so the listing goes to the front-end as the room holds it. What a receiver does with a
 * listed path is its own decision, and §12 leaves every path on the wire unvalidated: `..`, an
 * absolute name and `.git/config` are all names a room will carry if a host — or, at `selvage/1`, the
 * server the listing lives on — sends them. A guest turns the listing into real files, and a
 * `.git/` materialised there is a repository every git-aware tool in the editor then runs `git` in,
 * with whatever `core.fsmonitor` the room wrote into its config. `unsafe` is what the mirror refuses
 * to put on disk: the same rule `isGrantedPath` holds a host's own enumeration to, so a conforming
 * host's listing never has one and the member is absent for it.
 */
export function grantReport(
  paths: readonly string[],
): { kind: 'grant'; paths: readonly string[]; unsafe?: string[] } {
  const unsafe = paths.filter((path) => !isGrantedPath(path));
  return unsafe.length === 0 ? { kind: 'grant', paths } : { kind: 'grant', paths, unsafe };
}

/**
 * How many entries a walk will look at before it stops. The path count is the listing's own
 * bound; this is the one that keeps a directory tree with a hundred thousand entries in it from
 * costing a hundred thousand stats before the first path is ever published.
 */
export const MAX_GRANT_NODES = 20_000;

/**
 * The listing of a folder as the file system held it when the walk ran: files only, ascending by
 * UTF-16 code unit.
 *
 * The count is a bound and not an error: a tree larger than it produces a truncated listing,
 * which is a project view missing some names rather than a wedged session. Each directory's
 * entries are visited in name order — the same code-unit order the listing is written in — so
 * which paths survive the truncation does not depend on the file system's own order.
 */
export async function enumerateGrant(root: string): Promise<string[]> {
  const paths: string[] = [];
  const budget = { nodes: MAX_GRANT_NODES };
  await walk(root, '', paths, budget);
  return sortGrant(paths);
}

async function walk(
  dir: string,
  relative: string,
  out: string[],
  budget: { nodes: number },
): Promise<void> {
  if (out.length >= MAX_GRANT_PATHS || budget.nodes <= 0) {
    return;
  }
  let entries: Dirent[];
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    // A directory that cannot be listed is one this host cannot share; it is not a fault the
    // session should hear about, because the grant is a listing and not a promise.
    return;
  }
  entries.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
  for (const entry of entries) {
    if (out.length >= MAX_GRANT_PATHS || budget.nodes <= 0) {
      return;
    }
    budget.nodes -= 1;
    const child = relative === '' ? entry.name : `${relative}/${entry.name}`;
    if (!isGrantedPath(child)) {
      continue;
    }
    // A symbolic link is neither a file this host can vouch for nor one it should follow,
    // because it can point anywhere, including out of the folder being shared. Nothing behind a
    // link is listed, and nothing behind it is descended into.
    if (entry.isSymbolicLink()) {
      continue;
    }
    if (entry.isDirectory()) {
      await walk(join(dir, entry.name), child, out, budget);
      continue;
    }
    // A listing carries files and never directories.
    if (!entry.isFile()) {
      continue;
    }
    // A file whose name declares a format a room cannot carry is left out, because the read
    // refuses every file of that format as `binary`: naming it offered a guest a file no fetch
    // could fill. The rule is the name alone and it is a floor — this walk reads no bytes, so a
    // binary whose name declares no format stays listed and gets that refusal for asking
    // (`GRANT_BINARY_SUFFIXES` in the grant's own rules).
    if (isBinaryNamedPath(child)) {
      continue;
    }
    if (await isShareableFile(join(dir, entry.name))) {
      out.push(child);
    }
  }
}

/**
 * A regular file small enough for one `Y.Text`, which is all a document can be.
 *
 * This is the half of the read's rule a walk can afford: a file's bytes are not read to decide
 * whether to name it. What a listing names is therefore a file a session *may* carry, and a file
 * whose name declares a format it cannot is a separate line drawn from the name alone
 * (`isBinaryNamedPath`).
 */
async function isShareableFile(absolute: string): Promise<boolean> {
  const info = await lstat(absolute).catch(() => undefined);
  return info !== undefined && info.isFile() && info.size <= MAX_GRANT_FILE_BYTES;
}

/**
 * `O_NOFOLLOW` where the platform has it, so a name that is a link is refused by the open itself
 * rather than by an `lstat` of the same name that a rename can get behind. Windows has none, and
 * there `isShareableFile`'s `lstat` is the only thing that refuses a link.
 */
const NO_FOLLOW = constants.O_NOFOLLOW ?? 0;

/** The folder a session shares: a link at the root *is* the folder the front-end named. */
const FOLDER = constants.O_RDONLY | constants.O_DIRECTORY;

/** A step inside it: a directory, and never a link to one. */
const STEP = FOLDER | NO_FOLLOW;

/** A leaf: the file itself, and never a link to one. */
const LEAF = constants.O_RDONLY | NO_FOLLOW;

/**
 * Whether a step can be taken relative to the directory the step before it found. Linux publishes
 * a process's open descriptors under `/proc/self/fd`, and a name under one of those is looked up
 * in the directory that descriptor holds rather than through the name again. Node offers no other
 * way to name the child of a directory that is already open.
 */
const PINNED_STEPS = existsSync('/proc/self/fd');

/**
 * A file's text, or why this host cannot serve it.
 *
 * The path is resolved one segment at a time because `join` resolves nothing: a path that travels
 * *through* a symbolic link lands on a real file somewhere else entirely, while the leaf's own
 * `lstat` reports an ordinary file. No such path was listed — the walk leaves links out — so what
 * it would read is outside the grant. The leaf is checked as well: a link is never served, which
 * is stricter than following one to a plain file, because a link is not something the listing
 * ever named.
 *
 * Checking a name and then reading it are two resolutions of that name, and a segment that is a
 * plain directory when it is checked can be a link somewhere else by the time the next segment
 * is: the file system reports neither reading to the other. So where the platform allows it each
 * step is taken *inside the descriptor of the directory the step before it found*
 * (`/proc/self/fd/<fd>/<name>`), which is the directory itself and not a name anything can be
 * swapped under — a segment replaced by a link between two steps is refused, and the leaf is read
 * through the descriptor its type and size were read from. Node cannot name the child of an open
 * directory on a platform without `/proc/self/fd`; there the steps are named by path and checked
 * with `lstat`, and a name replaced by a link between two of them is followed. That window is
 * what is left, and it takes a concurrent local writer to enter it: a peer asking for a path
 * cannot, and a writer that can already has this host's own file access, so what it exposes is
 * the peer rather than the host.
 *
 * What is not closed on any platform: a segment that is a *mount point* rather than a link. The
 * file system reports it as a directory, `realpath` answers with a path inside the folder for it,
 * and only a comparison of the file systems' identities (`st_dev`) at each step would see it. It
 * takes `CAP_SYS_ADMIN` to plant, and the VS Code client serves it too.
 *
 * The answer names *which* refusal it is — nothing there, not a plain file, over the size a
 * session carries, bytes that are not text — because one sentence for all of them sent a person
 * refused a `.zip` looking for a file that had never been deleted.
 */
export async function readGrantedFile(root: string, path: string): Promise<GrantedRead> {
  if (!isGrantedPath(path)) {
    return refused('not-granted');
  }
  const segments = path.split('/');
  const leaf = segments.pop();
  if (leaf === undefined) {
    return refused('not-granted');
  }
  if (!PINNED_STEPS) {
    const directory = await walkToDirectory(root, segments);
    return 'kind' in directory ? directory : await readLeaf(join(directory.path, leaf));
  }
  const directory = await openToDirectory(root, segments);
  if ('kind' in directory) {
    return directory;
  }
  try {
    return await readLeaf(inside(directory.handle, leaf));
  } finally {
    await directory.handle.close().catch(() => undefined);
  }
}

/** A refusal, shaped the way the bridge reads one. */
type Refused = { readonly kind: 'refused'; readonly cause: GrantRefusal };

function refused(cause: GrantRefusal): Refused {
  return { kind: 'refused', cause };
}

/** An open directory of the shared folder, or why the path's steps do not lead to one. */
type OpenedDirectory = { readonly handle: FileHandle } | Refused;

/** A directory of the shared folder named by path, or why the steps do not lead to one. */
type FoundDirectory = { readonly path: string } | Refused;

/**
 * Why a step could not be taken. A name that is not there is `missing`; anything else the file
 * system refuses — a link where a directory has to be, a name that is not a directory — is
 * `not-a-file`. Steps are opened with `O_NOFOLLOW` where the platform has it, so a link is
 * refused as one rather than followed.
 */
function stepRefusal(error: unknown): GrantRefusal {
  if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT') {
    return 'missing';
  }
  return 'not-a-file';
}

/** A name inside a directory that is already open: `/proc/self/fd/<fd>` is that directory. */
function inside(directory: FileHandle, name: string): string {
  return join('/proc/self/fd', String(directory.fd), name);
}

/**
 * The directory the path's segments name, opened one step at a time — a refusal when a step is
 * not a plain directory of the folder. Every step after the folder is resolved inside the
 * descriptor of the one before it, so the names walked through are not resolved a second time.
 */
async function openToDirectory(
  root: string,
  segments: readonly string[],
): Promise<OpenedDirectory> {
  const folder = await open(root, FOLDER).catch((error: unknown) =>
    refused(stepRefusal(error)),
  );
  if ('kind' in folder) {
    return folder;
  }
  let directory = folder;
  for (const segment of segments) {
    const next = await open(inside(directory, segment), STEP).catch((error: unknown) =>
      refused(stepRefusal(error)),
    );
    await directory.close().catch(() => undefined);
    if ('kind' in next) {
      return next;
    }
    directory = next;
  }
  return { handle: directory };
}

/**
 * The same walk by name, for a platform that cannot address a directory that is already open:
 * every step has to be a plain directory of the folder, but the check and the resolution of the
 * step after it are two readings of one name — see `readGrantedFile`.
 */
async function walkToDirectory(
  root: string,
  segments: readonly string[],
): Promise<FoundDirectory> {
  let head = root;
  for (const segment of segments) {
    head = join(head, segment);
    const info = await lstat(head).catch(() => undefined);
    if (info === undefined) {
      return refused('missing');
    }
    if (!info.isDirectory()) {
      return refused('not-a-file');
    }
  }
  return { path: head };
}

/**
 * A leaf's text, or why it is not one this host will serve.
 *
 * The size and the type are read before the bytes and again through the descriptor they are read
 * with, so the name it was opened under cannot be moved to something else in between.
 * `isShareableFile` is the same first half of the rule, one step earlier, and it is the half the
 * listing's own walk can afford: a walk does not read a file's bytes to decide whether to name
 * it, and the host's own disk is not read for a peer until the peer asks (`DESIGN.md` §4.2). A
 * file whose name declares a format no session carries is the listing's own line, drawn from the
 * name alone (`isBinaryNamedPath`); what is left to this read is a binary the name did not
 * declare, which is refused here.
 */
async function readLeaf(name: string): Promise<GrantedRead> {
  const info = await lstat(name).catch(() => undefined);
  if (info === undefined) {
    return refused('missing');
  }
  if (!info.isFile()) {
    return refused('not-a-file');
  }
  if (info.size > MAX_GRANT_FILE_BYTES) {
    return refused('too-large');
  }
  const handle = await open(name, LEAF).catch((error: unknown) =>
    refused(stepRefusal(error)),
  );
  if ('kind' in handle) {
    return handle;
  }
  try {
    const opened = await handle.stat().catch(() => undefined);
    if (opened === undefined) {
      return refused('missing');
    }
    if (!opened.isFile()) {
      return refused('not-a-file');
    }
    if (opened.size > MAX_GRANT_FILE_BYTES) {
      return refused('too-large');
    }
    const bytes = await handle.readFile().catch(() => undefined);
    return bytes === undefined ? refused('missing') : decodableText(bytes);
  } finally {
    await handle.close().catch(() => undefined);
  }
}

/**
 * A file's bytes as text, or a refusal when they are not what a session can carry: a NUL byte or
 * a byte sequence that is not valid UTF-8. A binary turned into a `Y.Text` would be corrupted
 * into replacement characters, and the room's own save policy would write it back over the
 * host's file.
 */
function decodableText(bytes: Uint8Array): GrantedRead {
  if (bytes.includes(0)) {
    return refused('binary');
  }
  try {
    return { kind: 'text', text: new TextDecoder('utf-8', { fatal: true }).decode(bytes) };
  } catch {
    return refused('binary');
  }
}
