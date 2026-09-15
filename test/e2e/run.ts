/**
 * The two-real-instance convergence proof: two independent headless Neovim processes, each
 * loading the real plugin out of this checkout and starting its own real companion process,
 * one hosting and one joining over a real `selvaged`, editing the same document.
 *
 * Nothing here is a stub. The only things this file does itself are start the server, hand the
 * two Neovims a scratch directory and a file to pass the invite through, and compare what they
 * each ended up holding.
 *
 * A `DropProxy` sits in front of the server and the guest is routed through it, holding the
 * guest's own bytes back by `SELVAGE_E2E_LAG_MS`. On loopback the window between a guest being
 * told which documents the room has and the text of those documents arriving is about a
 * millisecond, and a driver can only make a keystroke in it if it is wider than that.
 *
 * The reconnect phase (skipped with `SELVAGE_E2E_RECONNECT=0`) proves the engine's bounded
 * backoff for real: cutting the same proxy's sockets is a real TCP close the guest has to
 * recover from on its own — unlike killing the server, which would take the room with it.
 *
 * Run it with `scripts/e2e/run-two-instance.sh`. It is not part of `npm test` or CI: it needs
 * a `nvim`, a built `selvaged` and a network path between them.
 */

import { spawn } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

import { RealServer } from '../helpers/selvaged.ts';

const ROOT = resolve(import.meta.dirname, '..', '..');
const TMP = resolve(ROOT, '.tmp');
const RUN_DIR = resolve(TMP, 'e2e-run');

const MARKER_HOST = '[[HOST-EDIT]]';
const MARKER_GUEST = '[[GUEST-EDIT]]';
const MARKER_HOST_2 = '[[HOST-EDIT-2]]';
const MARKER_GUEST_2 = '[[GUEST-EDIT-2]]';
// The guest's second edit to the granted path, made in its mirror and saved there: what proves the
// save reached the room is that the host's own working copy ends up holding it.
const MARKER_MIRROR = '[[MIRROR-EDIT]]';
// The names the two instances join under. The host's is handed to the guest too, so the guest
// knows which peer's caret it is waiting for.
const HOST_DISPLAY_NAME = 'Ada';
const GUEST_DISPLAY_NAME = 'Bob';
const SEED_PATH = 'notes.txt';
// Deliberately not ASCII: every offset on the wire is a UTF-16 code unit and every offset in
// Neovim is a byte, and a document made only of ASCII would not tell the two apart.
const SEED_TEXT = 'a dokument twö real editors are about to share \u{1f9f5}\n';
// The room's own text, as the host wrote it to disk. It has to be in the final text: a guest
// that opens its buffer before this text arrives must not publish its own over the room's, and
// convergence alone would not notice — both sides would still agree on whatever they ended up
// with, which is exactly how the overwrite stayed invisible.
const SEED_LINE = SEED_TEXT.trimEnd();
// A file the host writes down when the run starts and never opens. The guest opens it, so its
// text can only have arrived because the host read its own working copy on the guest's request.
const GRANTED_PATH = 'granted/never-opened.txt';
const GRANTED_TEXT = 'a file the host never opens in its own window\n';

const RECONNECT = process.env['SELVAGE_E2E_RECONNECT'] !== '0';
const DEADLINE_MS = Number(process.env['SELVAGE_E2E_DEADLINE_MS'] ?? '20000');
const RECONNECT_DEADLINE_MS = Number(process.env['SELVAGE_E2E_RECONNECT_DEADLINE_MS'] ?? '60000');
const NVIM = process.env['SELVAGE_NVIM'] ?? 'nvim';
/** How long the relay holds the guest's own bytes back, widening the pre-arrival window. */
const LAG_MS = Number(process.env['SELVAGE_E2E_LAG_MS'] ?? '300');

function log(...parts: unknown[]): void {
  console.log('[e2e]', ...parts);
}

/** A TCP relay a test can cut without touching the process on either end of it — the same idea
 * as `reference_server/crates/harness`'s `DropProxy`. The guest reaches the server only through
 * its invite URL, so rewriting that URL to point here is all it takes to put the relay in the
 * guest's path and leave the host's alone.
 *
 * It can also hold the guest's own bytes back for a beat. A client names the room's documents
 * from the handshake and receives their text a message later, and on loopback that window is
 * about a millisecond; delaying what the guest sends widens it, so a driver can make a
 * keystroke in it every run rather than once in a while.
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

  static async start(targetHost: string, targetPort: number, lagMs = 0): Promise<DropProxy> {
    return new Promise((resolvePromise, reject) => {
      const sockets = new Set<net.Socket>();
      const server = net.createServer((client) => {
        const upstream = net.connect(targetPort, targetHost);
        sockets.add(client);
        sockets.add(upstream);
        upstream.pipe(client);
        if (lagMs === 0) {
          client.pipe(upstream);
        } else {
          // One timer per chunk, all with the same delay: they fire in the order they were made,
          // so the bytes reach the server in the order the guest wrote them.
          client.on('data', (chunk: Buffer) => {
            setTimeout(() => {
              upstream.write(chunk);
            }, lagMs);
          });
          client.on('end', () => {
            upstream.end();
          });
        }
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
          reject(new Error('proxy has no port'));
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

interface InstanceOutcome {
  role: string;
  phase1?: { text: string };
  phase2?: { text: string };
  /** What the granted path held in this editor, and whether the host had it open too early. */
  granted?: { text: string; heldBeforeGuest?: boolean };
  /**
   * The mirror's own phase: what the granted path's file held after a save in the mirror. On the
   * guest that file is the mirror's, and `root` is the directory the room was materialised into,
   * with `rgFound` saying whether ripgrep read it; on the host it is the working copy's own file.
   */
  mirror?: { text: string; root?: string; rgFound?: boolean };
  error?: string;
}

function readOutcome(resultFile: string): InstanceOutcome | undefined {
  try {
    return JSON.parse(readFileSync(resultFile, 'utf8')) as InstanceOutcome;
  } catch {
    return undefined;
  }
}

async function pollFor<T>(label: string, check: () => T | undefined, deadlineMs: number): Promise<T> {
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    const value = check();
    if (value !== undefined) {
      return value;
    }
    if (Date.now() >= deadline) {
      throw new Error(`orchestrator: timed out after ${deadlineMs}ms waiting for ${label}`);
    }
    await delay(200);
  }
}

/** One real headless Neovim, running one of the driver scripts. */
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

/** What this run started, held where the failure handler can reach it too: a run that dies on
 * the way has still started a server and a relay that belong to it. */
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

  const [, hostPort] = /:(\d+)$/.exec(server.address) ?? [];
  if (hostPort === undefined) {
    throw new Error(`could not parse a port out of ${server.address}`);
  }
  const guestRelay = await DropProxy.start('127.0.0.1', Number(hostPort), LAG_MS);
  relay = guestRelay;
  log(
    `relay listening on 127.0.0.1:${guestRelay.port} -> ${server.address}, holding the guest's own ` +
      `bytes back by ${LAG_MS}ms`,
  );

  const hostWorkspace = mkdtempSync(join(RUN_DIR, 'host-'));
  const guestWorkspace = mkdtempSync(join(RUN_DIR, 'guest-'));
  writeFileSync(join(hostWorkspace, SEED_PATH), SEED_TEXT);
  mkdirSync(join(hostWorkspace, dirname(GRANTED_PATH)), { recursive: true });
  writeFileSync(join(hostWorkspace, GRANTED_PATH), GRANTED_TEXT);

  const inviteFile = resolve(RUN_DIR, 'invite.txt');
  const joinedFile = resolve(RUN_DIR, 'joined.txt');
  const ackFile = resolve(RUN_DIR, 'ack');
  const grantedDoneFile = resolve(RUN_DIR, 'granted-done.txt');
  const mirrorDoneFile = resolve(RUN_DIR, 'mirror-done.txt');
  const controlFile = RECONNECT ? resolve(RUN_DIR, 'blip-done.txt') : undefined;
  const hostResultFile = resolve(RUN_DIR, 'host-result.json');
  const guestResultFile = resolve(RUN_DIR, 'guest-result.json');

  const sharedEnv: Record<string, string> = {
    SELVAGE_E2E_PLUGIN_ROOT: ROOT,
    SELVAGE_E2E_SEED_PATH: SEED_PATH,
    SELVAGE_E2E_INVITE_FILE: inviteFile,
    SELVAGE_E2E_JOINED_FILE: joinedFile,
    SELVAGE_E2E_ACK_FILE: ackFile,
    SELVAGE_E2E_MARKER_HOST: MARKER_HOST,
    SELVAGE_E2E_MARKER_GUEST: MARKER_GUEST,
    SELVAGE_E2E_MARKER_HOST_2: MARKER_HOST_2,
    SELVAGE_E2E_MARKER_GUEST_2: MARKER_GUEST_2,
    SELVAGE_E2E_MARKER_MIRROR: MARKER_MIRROR,
    SELVAGE_E2E_MIRROR_DONE_FILE: mirrorDoneFile,
    SELVAGE_E2E_DEADLINE_MS: String(DEADLINE_MS),
    SELVAGE_E2E_RECONNECT_DEADLINE_MS: String(RECONNECT_DEADLINE_MS),
    SELVAGE_E2E_HOST_DISPLAY_NAME: HOST_DISPLAY_NAME,
    SELVAGE_E2E_GRANTED_PATH: GRANTED_PATH,
    SELVAGE_E2E_GRANTED_TEXT: GRANTED_TEXT,
    SELVAGE_E2E_GRANTED_DONE_FILE: grantedDoneFile,
    ...(controlFile === undefined ? {} : { SELVAGE_E2E_CONTROL_FILE: controlFile }),
  };

  log('launching both real Neovim instances');
  const hostRun = runInstance(
    'host',
    hostWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: hostResultFile,
      SELVAGE_E2E_SERVER_URL: server.wsBase,
      SELVAGE_DISPLAY_NAME: HOST_DISPLAY_NAME,
    },
    resolve(RUN_DIR, 'host.log'),
  );
  const guestRun = runInstance(
    'guest',
    guestWorkspace,
    {
      ...sharedEnv,
      SELVAGE_E2E_RESULT_FILE: guestResultFile,
      SELVAGE_DISPLAY_NAME: GUEST_DISPLAY_NAME,
      SELVAGE_E2E_PROXY_ADDR: `127.0.0.1:${guestRelay.port}`,
    },
    resolve(RUN_DIR, 'guest.log'),
  );

  // The blip only means anything once phase 1 has actually landed in both editors.
  await pollFor(
    'both instances to report phase 1 converged',
    () => {
      const hostOutcome = readOutcome(hostResultFile);
      const guestOutcome = readOutcome(guestResultFile);
      return hostOutcome?.phase1 !== undefined && guestOutcome?.phase1 !== undefined ? true : undefined;
    },
    DEADLINE_MS + 20_000,
  ).catch(async (error: unknown) => {
    // The instances keep their own logs, which is where a run that never got to the blip
    // says what it saw.
    await Promise.race([Promise.all([hostRun, guestRun]), delay(5000)]);
    throw error;
  });
  log('phase 1 converged in both editors');

  // The guest opens a granted path the host never opened. The guest writes the control file once
  // its own copy of that file's text has arrived and it has written into it, so the host's half
  // of the proof — opening the file and finding the guest's marker in the room's copy — starts
  // only after the guest has read what the host supplied on request.
  await pollFor(
    'the guest to converge on a granted path the host never opened',
    () => (existsSync(grantedDoneFile) ? true : undefined),
    DEADLINE_MS + 20_000,
  ).catch(async (error: unknown) => {
    await Promise.race([Promise.all([hostRun, guestRun]), delay(5000)]);
    throw error;
  });
  log('the guest has the granted path; the host will now open the file it never opened');

  // The host's half of that phase is done when it says the guest's marker landed in its own copy,
  // which is also the moment both instances are free for the blip.
  await pollFor(
    'the host to take the guest marker into the granted path',
    () => (existsSync(ackFile + '.granted') ? true : undefined),
    DEADLINE_MS + 20_000,
  ).catch(async (error: unknown) => {
    await Promise.race([Promise.all([hostRun, guestRun]), delay(5000)]);
    throw error;
  });

  // The guest then opens the mirrored file, checks that ripgrep reads it, and saves an edit into
  // it — and the host confirms its own working copy took that edit. The blip must not land in the
  // middle of that, so this waits for the host's half before cutting anything.
  await pollFor(
    'the guest to save an edit in its mirror and the host to take it',
    () => (existsSync(ackFile + '.mirror') ? true : undefined),
    DEADLINE_MS + 20_000,
  ).catch(async (error: unknown) => {
    await Promise.race([Promise.all([hostRun, guestRun]), delay(5000)]);
    throw error;
  });
  log('the guest\'s mirror held the room, ripgrep read it, and its save reached the host');

  if (RECONNECT && controlFile !== undefined) {
    log('cutting the guest relay (a real TCP close)');
    guestRelay.dropAll();
    await delay(2000);
    writeFileSync(controlFile, 'go');
    log('blip signalled; waiting for the guest to reconnect and both sides to re-converge');
  }

  const [hostCode, guestCode] = await Promise.all([hostRun, guestRun]);

  const hostOutcome = readOutcome(hostResultFile);
  const guestOutcome = readOutcome(guestResultFile);
  log('host outcome:', JSON.stringify(hostOutcome));
  log('guest outcome:', JSON.stringify(guestOutcome));

  const summary = {
    phase1: {
      converged:
        hostOutcome?.phase1 !== undefined &&
        guestOutcome?.phase1 !== undefined &&
        hostOutcome.phase1.text === guestOutcome.phase1.text &&
        hostOutcome.phase1.text.includes(MARKER_HOST) &&
        hostOutcome.phase1.text.includes(MARKER_GUEST) &&
        hostOutcome.phase1.text.includes(SEED_LINE),
      hostText: hostOutcome?.phase1?.text,
      guestText: guestOutcome?.phase1?.text,
    },
    phase2: RECONNECT
      ? {
          converged:
            hostOutcome?.phase2 !== undefined &&
            guestOutcome?.phase2 !== undefined &&
            hostOutcome.phase2.text === guestOutcome.phase2.text &&
            [MARKER_HOST, MARKER_GUEST, MARKER_HOST_2, MARKER_GUEST_2, SEED_LINE].every((marker) =>
              hostOutcome.phase2?.text.includes(marker),
            ),
          hostText: hostOutcome?.phase2?.text,
          guestText: guestOutcome?.phase2?.text,
        }
      : undefined,
    granted: {
      // The guest read a file the host never opened, and the host then opened it and found the
      // guest's marker in the room's copy: content travelled both ways over a path that was
      // only ever a name until somebody asked for it.
      converged:
        hostOutcome?.granted !== undefined &&
        guestOutcome?.granted !== undefined &&
        guestOutcome.granted.text === GRANTED_TEXT + MARKER_GUEST + '\n' &&
        hostOutcome.granted.text === GRANTED_TEXT + MARKER_GUEST + '\n' &&
        hostOutcome.granted.heldBeforeGuest === false,
      hostText: hostOutcome?.granted?.text,
      guestText: guestOutcome?.granted?.text,
      heldBeforeGuest: hostOutcome?.granted?.heldBeforeGuest,
    },
    mirror: {
      // The guest's mirror is a real directory holding the room's shape before anything is
      // fetched, the guest's file holds the room's text after the path was opened, ripgrep read
      // that file from outside this editor, and a save made in it reached the host's own copy.
      // The expected text is what the host's file must hold at the end of it.
      converged:
        guestOutcome?.mirror?.text === GRANTED_TEXT + MARKER_GUEST + '\n' + MARKER_MIRROR + '\n' &&
        guestOutcome?.mirror?.root !== undefined &&
        guestOutcome?.mirror?.rgFound === true &&
        hostOutcome?.mirror?.text === GRANTED_TEXT + MARKER_GUEST + '\n' + MARKER_MIRROR + '\n',
      guestFile: guestOutcome?.mirror?.text,
      guestMirrorRoot: guestOutcome?.mirror?.root,
      guestRgFound: guestOutcome?.mirror?.rgFound,
      hostFile: hostOutcome?.mirror?.text,
    },
    exitCodes: { host: hostCode, guest: guestCode },
  };
  writeFileSync(resolve(RUN_DIR, 'summary.json'), JSON.stringify(summary, null, 2));
  log('summary:', JSON.stringify(summary, null, 2));

  // What this file started is stopped before the verdict is passed, so that the summary above is
  // on disk either way.
  await stopAll();

  if (!summary.phase1.converged) {
    throw new Error('the two real Neovim instances did not converge on the shared document');
  }
  if (!summary.granted.converged) {
    throw new Error('the guest did not converge on a granted path the host supplied on request');
  }
  if (!summary.mirror.converged) {
    throw new Error(
      'the guest did not mirror the room: a file was not materialised empty, opened as a real path, ' +
        'read by ripgrep, or saved back to the host',
    );
  }
  if (RECONNECT && summary.phase2?.converged !== true) {
    throw new Error('the reconnect phase did not converge after the simulated network blip');
  }
  if (hostCode !== 0 || guestCode !== 0) {
    throw new Error(`an instance exited non-zero: host ${hostCode}, guest ${guestCode}`);
  }
  log(
    'PASSED: two real Neovim instances converged on the shared document, a guest read a granted path the host never opened, ' +
      'and a save in the guest\'s mirror of that grant reached the host' +
      (RECONNECT ? ', and again after a simulated network blip' : ''),
  );
}

main().catch(async (error: unknown) => {
  console.error('[e2e] FAILED:', error);
  // A run that never reached its verdict has still started a server and a relay. Stop them here
  // too, then leave: a run that hangs instead of reporting a failure is worse than a red run.
  await stopAll();
  process.exit(1);
});
