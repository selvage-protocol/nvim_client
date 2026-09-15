/**
 * The grant, read off the host's working copy.
 *
 * Everything decidable about a listing — which paths it may name, in what order it is written —
 * is in `vendor/bridge/grant.ts`, because both clients have to agree on it. What is left here is
 * this adapter's half: resolving a room path back to the file it names, over Node's own file
 * system. It is the counterpart of `vscode_client`'s `src/adapter/grant.ts`, which does the same
 * over `vscode.workspace.fs`.
 *
 * Resolving a path a *peer* named is the only place a host reads its disk because someone else
 * asked rather than because the user acted, so nothing the path says is trusted: it is held to
 * the grant's own rules, and every directory on the way to it has to be a plain directory of the
 * shared folder rather than a symbolic link out of it.
 */

import { lstat, readFile } from 'node:fs/promises';
import { join } from 'node:path';

import { MAX_GRANT_FILE_BYTES, isGrantedPath } from '../vendor/bridge/index.ts';

/** A regular file small enough for one `Y.Text`, which is all a document can be. */
async function isShareableFile(absolute: string): Promise<boolean> {
  const info = await lstat(absolute).catch(() => undefined);
  return info !== undefined && info.isFile() && info.size <= MAX_GRANT_FILE_BYTES;
}

/**
 * A file's text, or `undefined` when the path is not one this host can serve.
 *
 * `undefined` is the answer for anything that is not a readable text file inside the shared
 * folder: a path the grant excludes (the `.git` tree, an environment file), one that escapes the
 * folder, a directory, a symbolic link, a file over the size a session will carry, bytes that are
 * not text, and anything that cannot be read at all. The caller reports the refusal rather than
 * putting an empty document into the room.
 *
 * The path is walked one segment at a time because `join` resolves nothing: a path that travels
 * *through* a symbolic link lands on a real file somewhere else entirely, while the leaf's own
 * `lstat` reports an ordinary file. No such path was listed — the walk leaves links out — so what
 * it would read is outside the grant. The leaf is checked as well: a link is never served, which
 * is stricter than following one to a plain file, because a link is not something the listing
 * ever named.
 *
 * What this cannot see, because the file system does not report it: a segment that is a mount
 * point rather than a link, and a link put in place between this walk and the read that follows.
 */
export async function readGrantedFile(root: string, path: string): Promise<string | undefined> {
  if (!isGrantedPath(path)) {
    return undefined;
  }
  const segments = path.split('/');
  let head = root;
  for (const segment of segments.slice(0, -1)) {
    head = join(head, segment);
    const info = await lstat(head).catch(() => undefined);
    if (info === undefined || !info.isDirectory()) {
      return undefined;
    }
  }
  const leaf = join(head, segments[segments.length - 1] as string);
  if (!(await isShareableFile(leaf))) {
    return undefined;
  }
  const bytes = await readFile(leaf).catch(() => undefined);
  return bytes === undefined ? undefined : decodableText(bytes);
}

/**
 * A file's bytes as text, or `undefined` when they are not what a session can carry: a NUL byte
 * or a byte sequence that is not valid UTF-8. A binary turned into a `Y.Text` would be corrupted
 * into replacement characters, and the room's own save policy would write it back over the
 * host's file.
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
