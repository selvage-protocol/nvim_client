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
 *
 * A `selvage/2` invite carries more than the token. `§5.1`'s fragment is the room key every frame
 * of the room is sealed under and the host's public key, and a client **MUST NOT** log it: a trace
 * outlives the room, and a file holding the key decrypts whatever the operator kept beside it. The
 * keys are no part of what a trace is for — the order the messages crossed in needs the types, the
 * ids and the addresses — so the invite is written without its fragment.
 */
const traceFile = process.env['SELVAGE_COMPANION_LOG'];

/**
 * A link with its fragment taken off. `§5.1`'s keys are everything after the first `#`, encoded
 * or not, so nothing has to be decoded or guessed to remove them; a `#` no scheme precedes is
 * some other text — a document's own content, which a trace is for reading as it stands — and is
 * returned unchanged.
 */
function withoutFragment(text: string): string {
  const hash = text.indexOf('#');
  if (hash === -1 || !text.slice(0, hash).includes('://')) {
    return text;
  }
  return `${text.slice(0, hash)}#redacted`;
}

/**
 * A message as it is written to the trace: the one member either direction can carry a link in is
 * `invite`, and every other member is written as it stands. A document's text crosses this pipe
 * too, and a trace that rewrote it would misrepresent what the room holds.
 */
function redacted(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => redacted(item));
  }
  if (typeof value !== 'object' || value === null) {
    return value;
  }
  return Object.fromEntries(
    Object.entries(value).map(([name, item]) => [
      name,
      name === 'invite' && typeof item === 'string' ? withoutFragment(item) : redacted(item),
    ]),
  );
}

function trace(direction: '>' | '<', payload: unknown): void {
  if (traceFile === undefined || traceFile === '') {
    return;
  }
  try {
    appendFileSync(
      traceFile,
      `${new Date().toISOString()} ${String(process.pid)} ${direction} ${JSON.stringify(redacted(payload))}\n`,
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
    warn(
      `ignoring a line that is not JSON: ${error instanceof Error ? error.message : withoutFragment(line)}`,
    );
    return;
  }
  if (!isRequest(parsed)) {
    // The parsed value, redacted by member name, and not the line: `withoutFragment` reads the
    // first `#`, so a member before `invite` that carries one of its own leaves an invite's
    // fragment in the warning.
    warn(`ignoring a message that is not a request: ${JSON.stringify(redacted(parsed))}`);
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
