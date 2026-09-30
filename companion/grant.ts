/**
 * The grant, read off the host's working copy.
 *
 * Everything decidable about a listing — which paths it may name, in what order it is written,
 * how a tree is derived from it, and where a walk over a folder stops — is in `vendor/bridge/`,
 * because both clients have to agree on it. What is left here is this adapter's half: the seam
 * the shared walk reads through, over Node's own file system, and resolving a room path back to
 * the file it names. It is the counterpart of `vscode_client`'s `src/adapter/grant.ts`, which
 * does the same over `vscode.workspace.fs`.
 *
 * Resolving a path a *peer* named is the only place a host reads its disk because someone else
 * asked rather than because the user acted, so nothing the path says is trusted: it is held to
 * the grant's own rules — the name-based excludes and the folder's own ignore files — and every
 * directory on the way to it has to be a plain directory of the shared folder rather than a
 * symbolic link out of it.
 */

import { existsSync, type Dirent } from 'node:fs';
import { constants, lstat, open, readdir, type FileHandle } from 'node:fs/promises';
import { join } from 'node:path';

import {
  MAX_GRANT_FILE_BYTES,
  hostPlatform,
  isGrantedPath,
  isIgnoredPath,
  walkListing,
} from '../vendor/bridge/index.ts';
import type {
  GrantRefusal,
  GrantedRead,
  IgnoreSource,
  ListingCut,
  ListingWalkSource,
  WalkEntry,
} from '../vendor/bridge/index.ts';

/**
 * The room's grant as the front-end is told it: the listing itself, whole and in the room's order,
 * and — only when there are any — the paths in it that the grant's own rules would never publish.
 *
 * `PROTOCOL.md` §6.3 has a receiver replace its view of the grant with `paths` and never merge or
 * trim it, so the listing goes to the front-end as the room holds it. What a receiver does with a
 * listed path is its own decision, and §12 leaves every path on the wire unvalidated: `..`, an
 * absolute name and `.git/config` are all names a room's listing will carry if the connection that
 * sent it puts them there. A guest turns the listing into real files, and a
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
 * Which bound stopped a walk: §13.3's two, or the work it pays for. A budget cut is the walk's
 * own — what it spends on directory reads and shareability checks — and not a listing bound.
 *
 * `paths` and `bytes` are recorded only where a file the walk would have named did not fit, so a
 * listing that holds every shareable file of the folder reports no cut. A spent budget leaves the
 * rest of the folder unread, so `budget` says the walk stopped and not that anything was left out.
 */
export type GrantCut = ListingCut;

/** What one walk found: the listing, and the bound that left the folder short of it. */
export interface GrantEnumeration {
  readonly paths: string[];
  readonly cut: GrantCut | undefined;
}

/**
 * The names of the two ignore files a host reads: the `.gitignore` any directory may state for
 * its children, and the `exclude` list a root's repository states under `info/` for the whole
 * folder.
 */
const IGNORE_FILE = '.gitignore';
const EXCLUDE_FILE = 'exclude';

/** How this adapter reads one directory of this host: the call the rest of the seam is built on. */
export type DirectoryReader = (dir: string) => Promise<readonly WalkEntry[] | undefined>;

/**
 * This host's own file system, as the shared walk's seam: every read goes through `node:fs`, an
 * entry's own type is reduced to what a listing carries (`kindOf`), and the platform is the one
 * this companion runs on, named here rather than read by the walk.
 *
 * `list` is how a directory is read, and the root's own ignore sources are read through it rather
 * than by listing the folder a second time, so a caller that hands in a reader sees every
 * directory the seam reads — which is how a test counts the root rather than reading the code to
 * see that it is read once.
 */
export function fileSystemSource(list: DirectoryReader = listDirectory): ListingWalkSource<string> {
  return {
    platform: hostPlatform(),
    entries: list,
    ignoreText: (dir, entries) => ignoreFileAt(dir, IGNORE_FILE, entries),
    shareable: (dir, name) => isShareableFile(join(dir, name)),
    child: (dir, name) => Promise.resolve(join(dir, name)),
    rootIgnores: (dir, entries) => rootIgnores(dir, entries, list),
  };
}

/** The seam a session walks through: this host's file system, read with `node:fs`'s own reader. */
export const FILE_SYSTEM_SOURCE: ListingWalkSource<string> = fileSystemSource();

/**
 * The listing of a folder as the file system held it when the walk ran: files only, ascending by
 * UTF-16 code unit, with the bound that stopped it short of the folder.
 *
 * The rule is the bridge's (`walkListing` in `vendor/bridge/listing-walk.ts`), which is the whole
 * of why this is the same walk in both clients: the bounds, the charge points and the cut reason
 * do not vary with the editor. What is here is the editor's half — `node:fs`, the folder's own
 * ignore sources, and the entry types a listing can carry.
 *
 * The listing is what this host shares by itself, so the folder's own ignore files narrow it the
 * way they narrow a `git status`: `<root>/.git/info/exclude` and every `.gitignore` at or below
 * the folder, with the last matching pattern deciding. Nothing above the folder is read, which is
 * a real difference from `git status` — a folder shared from inside a repository does not honor
 * the rules above it, because the folder is the bound on what a host reads for the room — and
 * neither `core.excludesFile` nor any other rule outside the folder is read.
 *
 * `source` is the file system the walk reads. It is the one argument a test makes its own: the
 * shared rule takes no bounds, so the way to cross one of §13.3's is to hand the walk a tree of
 * its own rather than write the hundred thousand files a real folder would need to reach it.
 */
export async function enumerateGrant(
  root: string,
  source: ListingWalkSource<string> = FILE_SYSTEM_SOURCE,
): Promise<GrantEnumeration> {
  const walked = await walkListing(source, [{ dir: root, name: '' }]);
  return { paths: walked.paths, cut: walked.cut };
}

/**
 * The ignore sources that govern everything under the folder, which is its repository exclude and
 * nothing else: `<root>/.git/info/exclude` is the lowest precedence source there is, under every
 * `.gitignore` the walk reads below it.
 *
 * A folder need not be a repository, `.git` may be a file rather than a directory (a linked
 * worktree, a submodule), and a listing may fail; each of those is a folder with no repository
 * exclude, which is what an absent one means. `.git` and `.git/info` have to be ordinary
 * directories of the folder before `info/exclude` is read, because a link to a repository
 * elsewhere would let a file outside the folder decide what this one shares.
 *
 * `entries` is the root's own listing, which the walk that calls this has just read: the root is
 * not listed a second time for its excludes, and `.git` and `info` are different directories.
 * `list` is how a directory is read, so a caller that handed the seam its own reader has the
 * `.git` read counted with the rest.
 */
async function rootIgnores(
  dir: string,
  entries: readonly WalkEntry[],
  list: DirectoryReader = listDirectory,
): Promise<IgnoreSource[]> {
  if (!holdsKind(entries, '.git', 'directory')) {
    return [];
  }
  const git = join(dir, '.git');
  if (!holdsKind(await list(git), 'info', 'directory')) {
    return [];
  }
  const text = await ignoreFileAt(join(git, 'info'), EXCLUDE_FILE, undefined, list);
  return text === undefined ? [] : [{ dir: '', text }];
}

/**
 * The kind of one entry of a directory's own listing, as a listing carries it.
 *
 * A link is tested first: it can point anywhere, including out of the folder being shared, so it
 * is neither a file this host can vouch for nor a directory to descend into. Exactly a file and
 * exactly a directory are the two a listing carries; everything else — a socket, a device, a type
 * this host cannot name — is an entry a listing cannot carry.
 */
function kindOf(entry: Dirent): WalkEntry['kind'] {
  if (entry.isSymbolicLink()) {
    return 'other';
  }
  if (entry.isFile()) {
    return 'file';
  }
  return entry.isDirectory() ? 'directory' : 'other';
}

/** A directory's own entries, or `undefined` when this host cannot list it. */
async function listDirectory(dir: string): Promise<WalkEntry[] | undefined> {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => undefined);
  return entries?.map((entry) => ({ name: entry.name, kind: kindOf(entry) }));
}

/**
 * The same for a directory that is already open, named through its descriptor so a segment
 * cannot be swapped under it. Only the pinned-step read path takes this route.
 */
async function listInside(dir: FileHandle): Promise<WalkEntry[] | undefined> {
  const entries = await readdir(inside(dir), { withFileTypes: true }).catch(() => undefined);
  return entries?.map((entry) => ({ name: entry.name, kind: kindOf(entry) }));
}

/** Whether a listing holds `name` as exactly `kind`, and not as a link or another type. */
function holdsKind(
  entries: readonly WalkEntry[] | undefined,
  name: string,
  kind: WalkEntry['kind'],
): boolean {
  return entries?.some((entry) => entry.name === name && entry.kind === kind) ?? false;
}

/** Whether a listing holds `name` as an ordinary file — not a link, a directory or a FIFO. */
function holdsFile(entries: readonly WalkEntry[] | undefined, name: string): boolean {
  return holdsKind(entries, name, 'file');
}

/**
 * Whether a listing carries `name` exactly as the path spelled it, entry name and nothing else:
 * no case folding and no normalization of the name's own. A directory this host cannot list
 * carries nothing, so a name under one is refused as a name the folder does not carry.
 */
function holdsName(entries: readonly WalkEntry[] | undefined, name: string): boolean {
  return entries?.some((entry) => entry.name === name) ?? false;
}

/**
 * The text of the ignore file `name` at `dir`, or `undefined` when `dir` holds no ignore file this
 * host will read.
 *
 * `name` counts only where `dir`'s own listing reports it as an ordinary file: a link, a directory
 * and a FIFO are each not an ignore file, and a link is exactly what a `stat` of the name follows,
 * where the listing carries `lstat`'s answer for the directory just read. Bytes that are not UTF-8
 * text are no ignore file either.
 *
 * `listing` is `dir`'s own entries when the caller already holds them, so a walk does not list a
 * directory twice; `list` is the reader the listing comes from when it does not. The check and the
 * read are two resolutions of one name, so a name swapped for a
 * link between them is followed: that is the window `readGrantedFile` already states for the leaf
 * and not a second one, and it is why the path a *peer* names has its ignore files read through
 * `ignoreFileIn` — inside the descriptor of the directory that listed them — instead.
 */
async function ignoreFileAt(
  dir: string,
  name: string,
  listing?: readonly WalkEntry[],
  list: DirectoryReader = listDirectory,
): Promise<string | undefined> {
  const entries = listing ?? (await list(dir));
  if (!holdsFile(entries, name)) {
    return undefined;
  }
  return readIgnoreText(join(dir, name));
}

/**
 * The bytes at `name` as an ignore file's text, or `undefined` when they are not one this host
 * will read.
 *
 * The open is `O_NOFOLLOW` where the platform has it, and the type comes from the descriptor that
 * open returned rather than from the name again, so the type and the bytes are one object's and
 * not two readings of a name. Where the platform has no `O_NOFOLLOW`, a name swapped for a link
 * between the listing and the open is followed: that is the window `readGrantedFile` states for
 * the leaf and not a second one.
 */
async function readIgnoreText(name: string): Promise<string | undefined> {
  const handle = await open(name, LEAF).catch(() => undefined);
  if (handle === undefined) {
    return undefined;
  }
  try {
    const info = await handle.stat().catch(() => undefined);
    if (info === undefined || !info.isFile()) {
      return undefined;
    }
    const bytes = await handle.readFile().catch(() => undefined);
    return bytes === undefined ? undefined : decodableText(bytes);
  } finally {
    await handle.close().catch(() => undefined);
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
 * Every segment on the way, and the leaf, also has to be an entry of the directory that holds it,
 * spelled exactly as that directory's listing carries it (`holdsName`): no case folding and no
 * normalization of the name's own. A file system that folds case or ignores Unicode normalization
 * resolves a spelling the listing does not carry, while the ignore check above ran on the spelling
 * the peer sent — so without this a path could pass that check and then open the file the check
 * meant to leave out. The check reads the listings `openGoverning` and `walkGoverning` already
 * take, so it costs no extra `readdir`. A name that is not an entry exactly is `missing`, the same
 * refusal a name the folder does not carry gets, and it says nothing about why the spelling failed.
 * It closes the folding and normalization aliases and nothing else: a mount point and a name the
 * local writer swaps mid-resolution are still the residuals above.
 *
 * The folder's own ignore files bind this read as well as the listing, because what the listing does
 * not carry is not this host's to serve either: the sources are the ones governing the path, read
 * only from directories the path's own resolution accepted and only where such a directory lists
 * one as an ordinary file (`openGoverning`). A path that exists and they leave out is refused
 * `not-granted`, the silent no an excluded name gets, and a path that is not there is refused
 * `missing` first, whatever they say about the name (`readLeaf`). Nothing above the folder is read,
 * so a folder shared from inside a repository does not honor the rules above it, and
 * `core.excludesFile` is not read either.
 *
 * The answer names *which* refusal it is — not one the grant carries, nothing there, not a plain
 * file, over the size a session carries, bytes that are not text — because one sentence for all of
 * them sent a person refused a `.zip` looking for a file that had never been deleted.
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
    const directory = await walkGoverning(root, segments);
    if ('kind' in directory) {
      return directory;
    }
    if (!holdsName(directory.entries, leaf)) {
      return refused('missing');
    }
    return await readLeaf(join(directory.path, leaf), directory.sources, path);
  }
  const directory = await openGoverning(root, segments);
  if ('kind' in directory) {
    return directory;
  }
  try {
    if (!holdsName(directory.entries, leaf)) {
      return refused('missing');
    }
    return await readLeaf(inside(directory.handle, leaf), directory.sources, path);
  } finally {
    await directory.handle.close().catch(() => undefined);
  }
}

/** A refusal, shaped the way the bridge reads one. */
type Refused = { readonly kind: 'refused'; readonly cause: GrantRefusal };

function refused(cause: GrantRefusal): Refused {
  return { kind: 'refused', cause };
}

/**
 * An open directory of the shared folder, with the ignore sources that govern a path under it.
 *
 * A source's `dir` is relative to the root folder, and `''` is the root itself: what
 * `isIgnoredPath` reads the patterns of each source against.
 */
type GoverningOpened =
  | {
      readonly handle: FileHandle;
      readonly sources: readonly IgnoreSource[];
      readonly entries: readonly WalkEntry[] | undefined;
    }
  | Refused;

/** The same, for a platform that cannot address a directory that is already open. */
type GoverningFound =
  | {
      readonly path: string;
      readonly sources: readonly IgnoreSource[];
      readonly entries: readonly WalkEntry[] | undefined;
    }
  | Refused;

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

/**
 * A name inside a directory that is already open: `/proc/self/fd/<fd>` is that directory, and a
 * name under it is looked up in what the descriptor holds rather than through the name again.
 */
function inside(directory: FileHandle, name = ''): string {
  return join('/proc/self/fd', String(directory.fd), name);
}

/**
 * The directory holding the path's leaf, opened one step at a time, and the ignore sources that
 * govern the path: the repository exclude at the root first, then the `.gitignore` of every
 * directory from the root down to that one, lowest precedence first.
 *
 * Every step after the folder is taken inside the descriptor of the one before it, and a step that
 * is a link is refused by `O_NOFOLLOW` where the platform has it (`NO_FOLLOW`) — the same care the
 * leaf's own read takes — and each ignore file is read from *inside* the directory that holds it
 * (`ignoreFileIn`). A `.gitignore` that is a link out of the folder, and a `.git` that is a link to
 * a repository elsewhere, are therefore not this folder's rules and not read. A step also has to be
 * an entry of the directory it is opened in, spelled exactly as that directory lists it
 * (`holdsName`); the listing that decides that is the same one the directory's own ignore file is
 * read from, so a peer's path does not list a directory twice.
 */
async function openGoverning(
  root: string,
  segments: readonly string[],
): Promise<GoverningOpened> {
  const folder = await open(root, FOLDER).catch((error: unknown) =>
    refused(stepRefusal(error)),
  );
  if ('kind' in folder) {
    return folder;
  }
  let directory = folder;
  let relative = '';
  const sources: IgnoreSource[] = [];
  const exclude = await repositoryExcludeIn(directory);
  if (exclude !== undefined) {
    sources.push({ dir: '', text: exclude });
  }
  for (let depth = 0; ; depth += 1) {
    const entries = await listInside(directory);
    const own = await ignoreFileIn(directory, IGNORE_FILE, entries);
    if (own !== undefined) {
      sources.push({ dir: relative, text: own });
    }
    if (depth === segments.length) {
      return { handle: directory, sources, entries };
    }
    const segment = segments[depth] ?? '';
    if (!holdsName(entries, segment)) {
      await directory.close().catch(() => undefined);
      return refused('missing');
    }
    const next = await open(inside(directory, segment), STEP).catch((error: unknown) =>
      refused(stepRefusal(error)),
    );
    await directory.close().catch(() => undefined);
    if ('kind' in next) {
      return next;
    }
    directory = next;
    relative = relative === '' ? segment : `${relative}/${segment}`;
  }
}

/**
 * The text of the ignore file `name` inside `dir`, or `undefined` when the directory holds no
 * ignore file this host will read.
 *
 * The directory's own listing decides what is an ignore file (`ignoreFileAt`), and both the
 * listing and the read name the child through `dir`'s descriptor, so neither step resolves a name
 * through a directory anywhere but the one the path's resolution found and accepted.
 */
async function ignoreFileIn(
  dir: FileHandle,
  name: string,
  listing?: readonly WalkEntry[],
): Promise<string | undefined> {
  const entries = listing ?? (await listInside(dir));
  if (!holdsFile(entries, name)) {
    return undefined;
  }
  return readIgnoreText(inside(dir, name));
}

/**
 * `<root>/.git/info/exclude`, read inside the root's own descriptor, or `undefined` when the
 * folder has no repository exclude — which is what an absent one means, not a fault.
 *
 * `.git` and `info` are opened with `O_NOFOLLOW` (see `NO_FOLLOW`), so a `.git` that is a link to
 * a repository elsewhere is refused where a directory has to be rather than read as this folder's
 * repository. A platform without `/proc/self/fd` does not come here; it goes through
 * `rootIgnores`, which reads the same rule off the directory listing.
 */
async function repositoryExcludeIn(directory: FileHandle): Promise<string | undefined> {
  const git = await open(inside(directory, '.git'), STEP).catch(() => undefined);
  if (git === undefined) {
    return undefined;
  }
  try {
    const info = await open(inside(git, 'info'), STEP).catch(() => undefined);
    if (info === undefined) {
      return undefined;
    }
    try {
      return await ignoreFileIn(info, EXCLUDE_FILE);
    } finally {
      await info.close().catch(() => undefined);
    }
  } finally {
    await git.close().catch(() => undefined);
  }
}

/**
 * The same walk by name, for a platform that cannot address a directory that is already open:
 * every step has to be a plain directory of the folder, spelled exactly as the directory holding it
 * lists it (`holdsName`) before the name is resolved, and the ignore files are listed and read by
 * name, but the check and the resolution of the step after it are two readings of one name — see
 * `readGrantedFile`.
 */
async function walkGoverning(
  root: string,
  segments: readonly string[],
): Promise<GoverningFound> {
  // The root is listed once: `rootIgnores` reads the repository exclude off the entries already
  // held here rather than listing the folder again for itself.
  const listed = await listDirectory(root);
  const sources: IgnoreSource[] = [...(await rootIgnores(root, listed ?? []))];
  let head = root;
  let relative = '';
  for (let depth = 0; ; depth += 1) {
    const entries = depth === 0 ? listed : await listDirectory(head);
    const own = await ignoreFileAt(head, IGNORE_FILE, entries);
    if (own !== undefined) {
      sources.push({ dir: relative, text: own });
    }
    if (depth === segments.length) {
      return { path: head, sources, entries };
    }
    const segment = segments[depth] ?? '';
    if (!holdsName(entries, segment)) {
      return refused('missing');
    }
    head = join(head, segment);
    const info = await lstat(head).catch(() => undefined);
    if (info === undefined) {
      return refused('missing');
    }
    if (!info.isDirectory()) {
      return refused('not-a-file');
    }
    relative = relative === '' ? segment : `${relative}/${segment}`;
  }
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
 *
 * The folder's own ignore files bind this read as well as the listing, and they are consulted
 * once the name is known to exist: a path that is not there is `missing` whatever they say about
 * the name, and one they leave out is `not-granted`, the silent no a name the grant never carries
 * gets — a different answer would say the guess was worth making (`docs/grant.md`).
 */
async function readLeaf(
  name: string,
  ignores: readonly IgnoreSource[],
  path: string,
): Promise<GrantedRead> {
  const info = await lstat(name).catch(() => undefined);
  if (info === undefined) {
    return refused('missing');
  }
  if (isIgnoredPath(ignores, path, false)) {
    return refused('not-granted');
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
    if (bytes === undefined) {
      return refused('missing');
    }
    const text = decodableText(bytes);
    return text === undefined ? refused('binary') : { kind: 'text', text };
  } finally {
    await handle.close().catch(() => undefined);
  }
}

/**
 * A file's bytes as text, or `undefined` when they are not what a session can carry: a NUL byte
 * or a byte sequence that is not valid UTF-8. A binary turned into a `Y.Text` would be corrupted
 * into replacement characters, and the room's own save policy would write it back over the
 * host's file. An ignore file's bytes are held to the same test, because a file that is not text
 * is not a list of patterns.
 */
function decodableText(bytes: Uint8Array): string | undefined {
  if (bytes.includes(0)) {
    return undefined;
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}
