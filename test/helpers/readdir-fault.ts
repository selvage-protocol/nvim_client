/**
 * Injects a file-system fault at the `readdir` the grant adapter imports, for as long as `work`
 * runs.
 *
 * A directory a host cannot list and a directory that is not there are different answers, and the
 * only way to reach the first through the real adapter is the reader itself: a permission bit that
 * refused the listing would refuse the open before it, and an I/O fault cannot be asked for. The
 * replacement is installed on the module object the adapter's own named import is a live binding
 * to and `syncBuiltinESMExports` republishes it, so `readGrantedFile` and `readGrantedPresence`
 * take it up unchanged — nothing about the adapter is stubbed, only the file system under it.
 */
import { readlinkSync } from 'node:fs';
import { createRequire, syncBuiltinESMExports } from 'node:module';

const load = createRequire(import.meta.url);

interface ReaddirModule {
  readdir: (dir: string, options?: unknown) => Promise<unknown>;
}

/**
 * Runs `work` with `readdir` failing, with `code`, for each directory in `directories`, and
 * restores the reader afterwards. A directory already open is named through its descriptor
 * (`/proc/self/fd/<n>`), which is resolved to the directory it holds so a test can name its
 * target the way it made it.
 */
export async function withReaddirFault(
  code: string,
  directories: readonly string[],
  work: () => Promise<void>,
): Promise<void> {
  const promises = load('node:fs/promises') as ReaddirModule;
  const real = promises.readdir;
  const named = (dir: string): boolean => {
    if (directories.includes(dir)) {
      return true;
    }
    if (!dir.startsWith('/proc/self/fd/')) {
      return false;
    }
    try {
      return directories.includes(readlinkSync(dir));
    } catch {
      return false;
    }
  };
  promises.readdir = async (dir, options) => {
    if (named(dir)) {
      throw Object.assign(new Error(`${code}: injected for a test`), { code });
    }
    return real(dir, options);
  };
  syncBuiltinESMExports();
  try {
    await work();
  } finally {
    promises.readdir = real;
    syncBuiltinESMExports();
  }
}
