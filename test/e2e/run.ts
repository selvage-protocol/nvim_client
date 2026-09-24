/**
 * The two-real-instance proof: a host Neovim and a guest Neovim, each loading the real plugin and
 * starting its own real companion, one minting a room on a real `selvaged` and the other joining
 * it by the link the host handed on, editing the same document in both directions.
 *
 * The room is the one the server seats, and the link is `§5.1`'s: the host's page link with the
 * room key and the host key on its fragment, which is the whole of what a join reads.
 *
 * Nothing here is a stub. What this file does itself is start the server, give the two Neovims a
 * scratch directory each and a file to pass the invite through, and compare what they ended up
 * holding.
 *
 * Run it with `scripts/e2e/run-two-instance.sh`. It is not part of `npm test` or CI: it needs a
 * `nvim`, a built `selvaged` and a network path between them.
 */

import { spawn } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import * as net from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

import { RealServer } from '../helpers/selvaged.ts';

const ROOT = resolve(import.meta.dirname, '..', '..');
const RUN_DIR = resolve(ROOT, '.tmp', 'e2e-run');

const MARKER_HOST = '[[HOST-EDIT]]';
const MARKER_GUEST = '[[GUEST-EDIT]]';
const MARKER_HOST_2 = '[[HOST-EDIT-AFTER-BLIP]]';
const MARKER_GUEST_2 = '[[GUEST-EDIT-AFTER-BLIP]]';
const MARKER_GRANTED = '[[GUEST-EDIT-IN-GRANTED]]';
const SEED_PATH = 'notes.txt';
// Deliberately not ASCII: every offset on the wire is a UTF-16 code unit and every offset in
// Neovim is a byte, and a document made only of ASCII would not tell the two apart.
const SEED_TEXT = 'two real editors, one room, two real companion processes \u{1f9f5}\n';
// A file the host writes into the folder it shares and never opens in its own window. The guest
// opens it, so its text can only have arrived because the host read its own working copy on the
// guest's request — the guest's own hold is the ask, and there is nothing else it could have read.
const GRANTED_PATH = 'granted/never-opened.txt';
const GRANTED_TEXT = 'a file the host never opens in its own window\n';

const RECONNECT = process.env['SELVAGE_E2E_RECONNECT'] !== '0';
const DEADLINE_MS = Number(process.env['SELVAGE_E2E_DEADLINE_MS'] ?? '30000');
const RECONNECT_DEADLINE_MS = Number(process.env['SELVAGE_E2E_RECONNECT_DEADLINE_MS'] ?? '60000');
const NVIM = process.env['SELVAGE_NVIM'] ?? 'nvim';

function log(...parts: unknown[]): void {
  console.log('[e2e]', ...parts);
}

interface Outcome {
  role: string;
  error?: string;
  edit?: { text: string; invite?: string; link?: string; role?: string };
  /** What the granted path held in this window, and whether this window had it open too early. */
  granted?: { text: string; heldBeforeGuest?: boolean };
  /** The text both windows end on after the guest's socket was cut and came back. */
  phase2?: { text: string };
}

/**
 * A TCP relay a test can cut without touching the process on either end of it — the same idea as
 * `reference_server/crates/harness`'s `DropProxy`. The guest reaches the server only through the
 * invite it is handed, so rewriting that link's authority to point here is all it takes to put the
 * relay in the guest's path and leave the host's connection alone.
 */
class DropProxy {
  private readonly server: net.Server;
  private readonly sockets: Set<net.Socket>;
  readonly port: number;

  private constructor(server: net.Server, port: number, sockets: Set<net.Socket>) {
    this.server = server;
    this.port = port;
    this.sockets = sockets;
  }

  /** The authority a link has to carry to reach the server through this relay. */
  get address(): string {
    return `127.0.0.1:${String(this.port)}`;
  }

  static async start(targetHost: string, targetPort: number): Promise<DropProxy> {
    return new Promise((resolvePromise, reject) => {
      const sockets = new Set<net.Socket>();
      const server = net.createServer((client) => {
        const upstream = net.connect(targetPort, targetHost);
        sockets.add(client);
        sockets.add(upstream);
        upstream.pipe(client);
        client.pipe(upstream);
        const forget = (): void => {
          sockets.delete(client);
          sockets.delete(upstream);
        };
        client.on('close', forget);
        upstream.on('close', forget);
        client.on('error', () => {
          upstream.destroy();
        });
        upstream.on('error', () => {
          client.destroy();
        });
      });
      server.on('error', reject);
      server.listen(0, '127.0.0.1', () => {
        const address = server.address();
        if (address === null || typeof address === 'string') {
          reject(new Error('the relay has no port'));
          return;
        }
        resolvePromise(new DropProxy(server, address.port, sockets));
      });
    });
  }

  /** Destroys every socket the relay is forwarding: a network blip from both ends, with the
   * server and the other peer untouched. */
  dropAll(): void {
    for (const socket of this.sockets) {
      socket.destroy();
    }
  }

  async stop(): Promise<void> {
    this.dropAll();
    await new Promise<void>((resolvePromise) => {
      this.server.close(() => {
        resolvePromise();
      });
    });
  }
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
  const child = spawn(NVIM, ['--headless', '-l', resolve(ROOT, 'test', 'e2e', `${role}.lua`)], {
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
let relay: DropProxy | undefined;

/** Stops both, bounded rather than waited on: a socket some process on the other end is still
 * holding must not keep a verdict from being reported. */
async function stopAll(): Promise<void> {
  await Promise.race([
    (async () => {
      await relay?.stop();
      await server?.stop();
    })(),
    delay(5000),
  ]);
}

async function main(): Promise<void> {
  rmSync(RUN_DIR, { recursive: true, force: true });
  mkdirSync(RUN_DIR, { recursive: true });

  log('starting the real selvaged');
  server = await RealServer.start();
  log('selvaged listening at', server.wsBase);

  // The relay is in the guest's path only when this run has a blip to make: the link the guest is
  // handed is rewritten to it in `test/e2e/guest.lua`.
  let guestRelay: DropProxy | undefined;
  if (RECONNECT) {
    const port = Number(/:(\d+)$/.exec(server.address)?.[1] ?? NaN);
    if (!Number.isInteger(port)) {
      throw new Error(`could not parse a port out of ${server.address}`);
    }
    guestRelay = await DropProxy.start('127.0.0.1', port);
    relay = guestRelay;
    log(`relay listening on 127.0.0.1:${String(guestRelay.port)} -> ${server.address}`);
  }

  const hostWorkspace = mkdtempSync(join(RUN_DIR, 'host-'));
  const guestWorkspace = mkdtempSync(join(RUN_DIR, 'guest-'));
  writeFileSync(join(hostWorkspace, SEED_PATH), SEED_TEXT);
  mkdirSync(join(hostWorkspace, dirname(GRANTED_PATH)), { recursive: true });
  writeFileSync(join(hostWorkspace, GRANTED_PATH), GRANTED_TEXT);

  const inviteFile = resolve(RUN_DIR, 'invite.txt');
  const joinedFile = resolve(RUN_DIR, 'joined.txt');
  const guestAckFile = resolve(RUN_DIR, 'guest-edit-seen.txt');
  const grantedDoneFile = resolve(RUN_DIR, 'granted-done.txt');
  const grantedAckFile = resolve(RUN_DIR, 'granted-ack.txt');
  const phase2AckFile = resolve(RUN_DIR, 'phase2-ack.txt');
  const guestDoneFile = resolve(RUN_DIR, 'guest-done.txt');
  const controlFile = RECONNECT ? resolve(RUN_DIR, 'blip-over.txt') : undefined;
  const hostResultFile = resolve(RUN_DIR, 'host-result.json');
  const guestResultFile = resolve(RUN_DIR, 'guest-result.json');
  // The host's companion writes its IPC trace here. `§5.1`'s fragment is the room's own key, and
  // a trace outlives the room, so this file is read below as well as written.
  const hostTraceFile = resolve(RUN_DIR, 'host-companion.log');

  const sharedEnv: Record<string, string> = {
    SELVAGE_E2E_PLUGIN_ROOT: ROOT,
    SELVAGE_E2E_SEED_PATH: SEED_PATH,
    SELVAGE_E2E_INVITE_FILE: inviteFile,
    SELVAGE_E2E_JOINED_FILE: joinedFile,
    SELVAGE_E2E_GUEST_ACK_FILE: guestAckFile,
    SELVAGE_E2E_MARKER_HOST: MARKER_HOST,
    SELVAGE_E2E_MARKER_GUEST: MARKER_GUEST,
    SELVAGE_E2E_MARKER_HOST_2: MARKER_HOST_2,
    SELVAGE_E2E_MARKER_GUEST_2: MARKER_GUEST_2,
    SELVAGE_E2E_MARKER_GRANTED: MARKER_GRANTED,
    SELVAGE_E2E_GRANTED_PATH: GRANTED_PATH,
    SELVAGE_E2E_GRANTED_TEXT: GRANTED_TEXT,
    SELVAGE_E2E_GRANTED_DONE_FILE: grantedDoneFile,
    SELVAGE_E2E_GRANTED_ACK_FILE: grantedAckFile,
    SELVAGE_E2E_PHASE2_ACK_FILE: phase2AckFile,
    SELVAGE_E2E_GUEST_DONE_FILE: guestDoneFile,
    SELVAGE_E2E_DEADLINE_MS: String(DEADLINE_MS),
    SELVAGE_E2E_RECONNECT_DEADLINE_MS: String(RECONNECT_DEADLINE_MS),
    ...(controlFile === undefined ? {} : { SELVAGE_E2E_CONTROL_FILE: controlFile }),
  };

  const hostRun = runInstance(
    'host',
    hostWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: hostResultFile,
      SELVAGE_E2E_SERVER_URL: server.wsBase,
      SELVAGE_COMPANION_LOG: hostTraceFile,
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
  // the host key. Both halves are read here: a page link without the fragment names no room this
  // client will join, and the failure would arrive as a room that is not there.
  if (!/^https?:\/\/[^\s#?#]+\/?\?room=[^&]+&token=[^#]+#k=[A-Za-z0-9_-]{43}&h=[A-Za-z0-9_-]{43}$/.test(invite)) {
    throw new Error(`the invite is not a page link with §5.1's fragment: ${invite}`);
  }
  log('the host is inviting with a page link whose fragment carries both keys');
  const fragment = invite.slice(invite.indexOf('#') + 1);
  const roomKey = /(?:^|&)k=([^&]+)/.exec(fragment)?.[1] ?? '';

  const guestRun = runInstance(
    'guest',
    guestWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: guestResultFile,
      ...(guestRelay === undefined ? {} : { SELVAGE_E2E_PROXY_ADDR: `127.0.0.1:${String(guestRelay.port)}` }),
    },
    resolve(RUN_DIR, 'guest.log'),
  );

  // The blip lands once both windows are past the granted phase: the host has said it took the
  // marker, and the two are waiting for the signal below. Cutting anywhere earlier would take a
  // phase's own messages with it instead of proving the reconnect.
  if (guestRelay !== undefined && controlFile !== undefined) {
    await pollFor(
      'the granted phase to be acknowledged',
      () => (existsSync(grantedAckFile) ? true : undefined),
      DEADLINE_MS + 40_000,
    );
    guestRelay.dropAll();
    await delay(2000);
    writeFileSync(controlFile, 'go');
    log('blip signalled; waiting for the guest to reconnect and both sides to re-converge');
  }

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
  // One room reached by both addresses, which is `§5.1`'s rule. A run with a blip puts the relay
  // in the guest's path, so that the socket cut is the guest's and the host's is untouched: the
  // link it joins is the host's own, and only its authority names the relay.
  const expectedLink =
    guestRelay === undefined ? invite : invite.replace(/^(https?:\/\/)[^/]+/, `$1${guestRelay.address}`);
  if (guest.edit?.link !== expectedLink) {
    throw new Error(`the guest joined ${String(guest.edit?.link)} rather than ${expectedLink}`);
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

  // The granted path: a file this host never opened, whose text the guest opened because the room
  // listed it. The guest's copy can only be the host's own read, and the marker it wrote back is
  // what proves the content travelled in both directions over a path that was a name until then.
  const wanted = GRANTED_TEXT + MARKER_GRANTED;
  if (guest.granted?.text !== wanted) {
    throw new Error(
      `the guest did not end on the host's copy of the granted path:\nwanted ${JSON.stringify(wanted)}\nguest  ${JSON.stringify(guest.granted?.text)}`,
    );
  }
  if (host.granted?.text !== wanted) {
    throw new Error(
      `the host's copy of the granted path did not take the guest's marker:\nwanted ${JSON.stringify(wanted)}\nhost   ${JSON.stringify(host.granted?.text)}`,
    );
  }
  if (host.granted?.heldBeforeGuest !== false) {
    throw new Error(
      `the host had ${GRANTED_PATH} open before the guest read it, so the read proves nothing`,
    );
  }
  log('the guest read a path the host never opened, and the host took the guest marker back');

  if (RECONNECT) {
    const markers = [MARKER_HOST, MARKER_GUEST, MARKER_HOST_2, MARKER_GUEST_2];
    const host2 = host.phase2?.text ?? '';
    const guest2 = guest.phase2?.text ?? '';
    if (host2 !== guest2 || !markers.every((marker) => host2.includes(marker))) {
      throw new Error(
        `the two replicas did not re-converge after the blip:\nhost  ${JSON.stringify(host2)}\nguest ${JSON.stringify(guest2)}`,
      );
    }
    log('the guest reconnected after its socket was cut, and both sides re-converged');
  }

  // `§5.1`: the fragment is the room key every frame is sealed under and the host's public key, and
  // a client **MUST NOT** log it. The host's companion ran with `SELVAGE_COMPANION_LOG` set to a
  // file in this run, so what is read here is the file a trace really is rather than one a test
  // built: the invite line has to be in it, and the keys have to be nowhere in it.
  const trace = readFileSync(hostTraceFile, 'utf8');
  const excerpt = trace.length > 600 ? `${trace.slice(0, 600)}…` : trace;
  if (!trace.includes('"state":"hosting"')) {
    throw new Error(`the trace does not hold the hosting status the invite travels in: ${excerpt}`);
  }
  for (const [what, secret] of [
    ["the invite's fragment", fragment],
    ['the room key', roomKey],
  ] as const) {
    if (secret !== '' && trace.includes(secret)) {
      throw new Error(`${what} is in the trace the host's companion wrote: ${excerpt}`);
    }
  }
  if (!trace.includes('#redacted')) {
    throw new Error(`the trace holds no redacted invite: ${excerpt}`);
  }
  log("the host's own companion traced the invite with its fragment redacted out");

  log(
    'PASSED: two real Neovim instances minted and joined one room through a real server, converged'
      + ' in both directions, a guest read a path the host never opened, and'
      + (RECONNECT ? ' a guest whose socket was cut reconnected and re-converged' : ' no blip was made'),
  );
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
  console.error('[e2e] FAILED:', error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  await stopAll();
}
