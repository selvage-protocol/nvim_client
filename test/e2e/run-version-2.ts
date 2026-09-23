/**
 * The two-real-instance `selvage/2` proof: a host Neovim and a guest Neovim, each loading the real
 * plugin and starting its own real companion, one minting a version-2 room on a real `selvaged
 * --serve-version-2` and the other joining it by the link the host handed on, editing the same
 * document in both directions.
 *
 * It sits beside `test/e2e/run.ts`, which is the version-1 proof and stays what it was: the
 * version this client's published users speak is not the version this file is about, and a proof
 * that covered both would have to say which half a failure came from. What the two share is the
 * harness (`test/e2e/harness.lua`) and the rule that every process in the run is real.
 *
 * Nothing here is a stub. What this file does itself is start the server, give the two Neovims a
 * scratch directory each and a file to pass the invite through, and compare what they ended up
 * holding.
 *
 * Run it with `scripts/e2e/run-version-2.sh`. It is not part of `npm test` or CI: it needs a
 * `nvim`, a built `selvaged` and a network path between them.
 */

import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

import { RealServer } from '../helpers/selvaged.ts';

const ROOT = resolve(import.meta.dirname, '..', '..');
const RUN_DIR = resolve(ROOT, '.tmp', 'e2e-version-2');

const MARKER_HOST = '[[V2-HOST-EDIT]]';
const MARKER_GUEST = '[[V2-GUEST-EDIT]]';
const SEED_PATH = 'notes.txt';
// Deliberately not ASCII: every offset on the wire is a UTF-16 code unit and every offset in
// Neovim is a byte, and a document made only of ASCII would not tell the two apart.
const SEED_TEXT = 'a version two room, two real editors \u{1f9f5}\n';

const DEADLINE_MS = Number(process.env['SELVAGE_E2E_DEADLINE_MS'] ?? '30000');
const NVIM = process.env['SELVAGE_NVIM'] ?? 'nvim';

function log(...parts: unknown[]): void {
  console.log('[e2e/v2]', ...parts);
}

interface Outcome {
  role: string;
  error?: string;
  edit?: { text: string; invite?: string; link?: string; role?: string };
}

function readOutcome(path: string): Outcome | undefined {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as Outcome;
  } catch {
    return undefined;
  }
}

async function pollFor<T>(
  label: string,
  check: () => T | undefined,
  deadlineMs = DEADLINE_MS,
): Promise<T> {
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    const value = check();
    if (value !== undefined) {
      return value;
    }
    if (Date.now() >= deadline) {
      throw new Error(`timed out after ${deadlineMs}ms waiting for ${label}`);
    }
    await delay(100);
  }
}

/** One real headless Neovim, running one of this proof's driver scripts. */
function runInstance(
  role: 'host' | 'guest',
  workspace: string,
  env: Record<string, string>,
  logFile: string,
): Promise<number> {
  const out = createWriteStream(logFile);
  const child = spawn(NVIM, ['--headless', '-l', resolve(ROOT, 'test', 'e2e', `${role}2.lua`)], {
    cwd: workspace,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const prefix = (chunk: Buffer): void => {
    const text = chunk.toString();
    out.write(text);
    for (const line of text.split('\n')) {
      if (line.trim() !== '') {
        console.log(`[${role}]`, line);
      }
    }
  };
  child.stdout.on('data', prefix);
  child.stderr.on('data', prefix);
  return new Promise<number>((resolvePromise) => {
    child.on('exit', (code, signal) => {
      out.end();
      log(`${role} nvim exited: code ${code} signal ${signal}`);
      resolvePromise(code ?? 1);
    });
  });
}

let server: RealServer | undefined;

async function main(): Promise<void> {
  rmSync(RUN_DIR, { recursive: true, force: true });
  mkdirSync(RUN_DIR, { recursive: true });

  log('starting the real selvaged with --serve-version-2');
  server = await RealServer.start({ serveVersion2: true });
  log('selvaged listening at', server.wsBase);

  const hostWorkspace = mkdtempSync(join(RUN_DIR, 'host-'));
  const guestWorkspace = mkdtempSync(join(RUN_DIR, 'guest-'));
  writeFileSync(join(hostWorkspace, SEED_PATH), SEED_TEXT);

  const inviteFile = resolve(RUN_DIR, 'invite.txt');
  const joinedFile = resolve(RUN_DIR, 'joined.txt');
  const guestAckFile = resolve(RUN_DIR, 'guest-edit-seen.txt');
  const hostResultFile = resolve(RUN_DIR, 'host-result.json');
  const guestResultFile = resolve(RUN_DIR, 'guest-result.json');

  const sharedEnv: Record<string, string> = {
    SELVAGE_E2E_PLUGIN_ROOT: ROOT,
    SELVAGE_E2E_SEED_PATH: SEED_PATH,
    SELVAGE_E2E_INVITE_FILE: inviteFile,
    SELVAGE_E2E_JOINED_FILE: joinedFile,
    SELVAGE_E2E_GUEST_ACK_FILE: guestAckFile,
    SELVAGE_E2E_MARKER_HOST: MARKER_HOST,
    SELVAGE_E2E_MARKER_GUEST: MARKER_GUEST,
    SELVAGE_E2E_DEADLINE_MS: String(DEADLINE_MS),
  };

  const hostRun = runInstance(
    'host',
    hostWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: hostResultFile,
      SELVAGE_E2E_SERVER_URL: server.wsBase,
    },
    resolve(RUN_DIR, 'host.log'),
  );

  // The guest cannot start before the invite exists: the link is the room, and the fragment on it
  // is the only copy of the room's keys there is.
  const invite = await pollFor('the host to mint a room', () => {
    const outcome = readOutcome(hostResultFile);
    const text = existsInvite(inviteFile) ? readFileSync(inviteFile, 'utf8') : undefined;
    if (text !== undefined && text.trim() !== '') {
      return text.trim();
    }
    if (outcome?.error !== undefined) {
      throw new Error(`the host failed: ${outcome.error}`);
    }
    return undefined;
  });

  // §5.1: the link a host hands on is its page link, and the fragment on it is the room key and
  // the host key. Both halves are read here: a page link without the fragment joins a version-1
  // room that does not exist, and the failure would arrive as a room that is not there.
  if (!/^https?:\/\/[^\s#?#]+\/?\?room=[^&]+&token=[^#]+#k=[A-Za-z0-9_-]{43}&h=[A-Za-z0-9_-]{43}$/.test(invite)) {
    throw new Error(`the invite is not a page link with §5.1's fragment: ${invite}`);
  }
  log('the host is inviting with a page link whose fragment carries both keys');

  const guestRun = runInstance(
    'guest',
    guestWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: guestResultFile,
    },
    resolve(RUN_DIR, 'guest.log'),
  );

  const [hostCode, guestCode] = await Promise.all([hostRun, guestRun]);

  const host = readOutcome(hostResultFile);
  const guest = readOutcome(guestResultFile);
  if (host === undefined || guest === undefined) {
    throw new Error(
      `an instance wrote no outcome: host ${String(hostCode)}, guest ${String(guestCode)}`,
    );
  }
  if (host.error !== undefined) {
    throw new Error(`the host failed: ${host.error}`);
  }
  if (guest.error !== undefined) {
    throw new Error(`the guest failed: ${guest.error}`);
  }
  if (hostCode !== 0 || guestCode !== 0) {
    throw new Error(`an instance exited non-zero: host ${hostCode}, guest ${guestCode}`);
  }

  const hostText = host.edit?.text ?? '';
  const guestText = guest.edit?.text ?? '';
  log('the host ended holding', JSON.stringify(hostText));
  log('the guest ended holding', JSON.stringify(guestText));

  if (host.edit?.role !== 'host') {
    throw new Error(`the host read its role as ${String(host.edit?.role)}`);
  }
  if (guest.edit?.role !== 'guest') {
    throw new Error(`the guest read its role as ${String(guest.edit?.role)}`);
  }
  // The connection's own invite is the wire form of the same room and the same two keys, and the
  // guest joined the page link: one room reached by both addresses, which is `§5.1`'s rule.
  const wire = host.edit?.invite ?? '';
  if (!/^ws:\/\/[^\s#?#]+\/session\?room=[^&]+&token=[^#]+#k=[A-Za-z0-9_-]{43}&h=[A-Za-z0-9_-]{43}$/.test(wire)) {
    throw new Error(`the connection's own invite is not the wire form with the fragment: ${wire}`);
  }
  if (guest.edit?.link !== invite) {
    throw new Error(`the guest joined ${String(guest.edit?.link)} rather than ${invite}`);
  }
  if (!hostText.includes(MARKER_HOST) || !hostText.includes(MARKER_GUEST)) {
    throw new Error(`the host did not end up holding both edits: ${JSON.stringify(hostText)}`);
  }
  if (guestText !== hostText) {
    throw new Error(
      `the two replicas disagree:\nhost  ${JSON.stringify(hostText)}\nguest ${JSON.stringify(guestText)}`,
    );
  }
  if (!hostText.includes(SEED_TEXT.trim())) {
    throw new Error(`the room's own text is not in what the host holds: ${JSON.stringify(hostText)}`);
  }

  // The host's own working copy is what makes the guest's edit a saved file rather than a buffer:
  // the guest's line reaches the room, and the host's editor writes what the room holds.
  const onDisk = readFileSync(join(hostWorkspace, SEED_PATH), 'utf8');
  if (!onDisk.includes(MARKER_GUEST)) {
    throw new Error(`the host's file does not hold the guest's edit: ${JSON.stringify(onDisk)}`);
  }

  log('a version-2 host and guest exchanged an edit through a real server, both directions');
}

function existsInvite(path: string): boolean {
  try {
    readFileSync(path);
    return true;
  } catch {
    return false;
  }
}

try {
  await main();
} catch (error: unknown) {
  console.error('[e2e/v2] FAILED:', error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  // Bounded rather than waited on: a socket some process on the other end is still holding must
  // not keep the verdict from being reported.
  await Promise.race([server?.stop() ?? Promise.resolve(), delay(5000)]);
}
