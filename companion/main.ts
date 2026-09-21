/**
 * The companion process: newline-delimited JSON in on stdin, the same out on stdout.
 *
 * Run by the Lua front-end through `jobstart`, one per Neovim instance. Everything it can
 * say is in `ipc.ts`; everything it decides is in `vendor/bridge/`.
 */

import { appendFileSync } from 'node:fs';

import { Companion } from './session.ts';
import { LineReader, isRequest } from './ipc.ts';
import type { Notification, Request } from './ipc.ts';

/**
 * Every message, both ways, with the time it crossed — written only when
 * `SELVAGE_COMPANION_LOG` names a file. The two sides of this IPC are two processes, so the
 * order the messages actually crossed in is the one thing a log of either side alone cannot
 * show; this is where a convergence question gets answered.
 *
 * What crosses includes a host's `invite`, which carries the room's token: an invite is a bearer
 * credential for as long as the room lives, so the file is written for its owner alone. The mode
 * applies to a file this creates; one that is already there keeps the mode it has, and a trace a
 * person kept from an earlier session is theirs to leave as it is.
 */
const traceFile = process.env['SELVAGE_COMPANION_LOG'];

function trace(direction: '>' | '<', payload: unknown): void {
  if (traceFile === undefined || traceFile === '') {
    return;
  }
  try {
    appendFileSync(
      traceFile,
      `${new Date().toISOString()} ${String(process.pid)} ${direction} ${JSON.stringify(payload)}\n`,
      { mode: 0o600 },
    );
  } catch {
    // A trace that cannot be written is not worth failing a session over.
  }
}

function write(notification: Notification): void {
  trace('>', notification);
  process.stdout.write(`${JSON.stringify(notification)}\n`);
}

/**
 * Anything this process prints on stdout is a message, so a diagnostic goes to stderr —
 * where Neovim's `on_stderr` can show it — and never into the stream the front-end parses.
 */
function warn(message: string): void {
  process.stderr.write(`selvage-companion: ${message}\n`);
}

const companion = new Companion({ send: write });

// One message at a time, in the order they arrived: `open` after `host` is an order the
// front-end relies on, and two overlapping handlers would not keep it.
let queue: Promise<void> = Promise.resolve();

const reader = new LineReader((line) => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch (error: unknown) {
    warn(`ignoring a line that is not JSON: ${error instanceof Error ? error.message : line}`);
    return;
  }
  if (!isRequest(parsed)) {
    warn(`ignoring a message that is not a request: ${line}`);
    return;
  }
  const request: Request = parsed;
  trace('<', request);
  queue = queue.then(() => companion.handle(request)).catch((error: unknown) => {
    warn(`handling ${request.type} failed: ${error instanceof Error ? error.message : String(error)}`);
  });
}, (bytes) => {
  warn(`ignoring a line past ${bytes} bytes without a newline: dropping it`);
});

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk: string) => {
  reader.push(chunk);
});

// The front-end closing the pipe is the session ending: leave the room rather than letting
// the server hold it open until the grace period expires.
process.stdin.on('end', () => {
  queue = queue.then(() => companion.leave()).then(
    () => {
      process.exit(0);
    },
    () => {
      process.exit(1);
    },
  );
});
