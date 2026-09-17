/**
 * The companion against a replica with no server behind it: what a front-end's message does
 * to the room, what the room asks a front-end to do, and the one race the local IPC has of
 * its own — a remote edit and a local one crossing in the pipe.
 */

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

import { LineReader, MAX_IPC_LINE_BYTES, isRequest } from '../companion/ipc.ts';
import type { Notification, Request } from '../companion/ipc.ts';
import { NvimEditorHost } from '../companion/editor.ts';
import { Companion } from '../companion/session.ts';
import { ProtocolError } from '../vendor/engine/index.ts';
import type { PeerInfo } from '../vendor/engine/envelope.ts';

import { MAX_GRANT_FILE_BYTES } from '../vendor/bridge/index.ts';
import { FakeEngine } from './helpers/fake-engine.ts';

/**
 * The editor host the harness hands the companion, recording what the bridge asks it to read and
 * which folder the front-end pointed it at. A path the room asks for reaches this host's disk
 * through `readGrantedFile` and nowhere else, and the call is made with the event that names the
 * path — so the count is a fact about the ask, not a sample of work still in flight (a read that
 * does happen resolves several turns later). The recorded folder is the same kind of fact: the
 * host is pointed at one as the session is built, before any listing is worked out.
 */
class RecordingHost extends NvimEditorHost {
  readonly reads: string[] = [];
  readonly folders: Array<string | undefined> = [];

  override sharedFolder(root: string | undefined): void {
    this.folders.push(root);
    super.sharedFolder(root);
  }

  override readGrantedFile(path: string): Promise<string | undefined> {
    this.reads.push(path);
    return super.readGrantedFile(path);
  }
}

interface Harness {
  companion: Companion;
  /** The editor host the companion was built with: `reads` is every ask that reached the disk. */
  editor: RecordingHost;
  /** The replica in use: the last one a `host` or `join` opened. */
  readonly engine: FakeEngine;
  sent: Notification[];
  /** Every server a `host` was asked for, in order: a second entry is a second room. */
  hosts: string[];
  /** Every invite a `join` was asked for, in the same order. */
  joins: string[];
  /** The `applyEdit`s asked for so far. */
  applies: Array<Extract<Notification, { type: 'applyEdit' }>>;
}

function harness(
  role: 'host' | 'guest' = 'host',
  documents: string[] = [],
  peers: PeerInfo[] = [],
  options: {
    defaultAutoSave?: boolean;
    granted?: string[];
    grantError?: Error;
    enumerate?: (root: string) => Promise<string[]>;
  } = {},
): Harness {
  const sent: Notification[] = [];
  const send = (notification: Notification): void => {
    sent.push(notification);
  };
  const hosts: string[] = [];
  const joins: string[] = [];
  const engines: FakeEngine[] = [];
  const open = (): FakeEngine => {
    const engine = new FakeEngine(role, documents, peers);
    engine.granted = [...(options.granted ?? [])];
    engine.grantError = options.grantError;
    engines.push(engine);
    return engine;
  };
  const editor = new RecordingHost({ send });
  const companion = new Companion({
    send,
    editor,
    autoSave: options.defaultAutoSave ?? false,
    enumerate: options.enumerate,
    engines: {
      host: (serverUrl) => {
        hosts.push(serverUrl);
        return Promise.resolve(open());
      },
      join: (invite) => {
        joins.push(invite);
        return Promise.resolve(open());
      },
    },
  });
  return {
    companion,
    editor,
    sent,
    hosts,
    joins,
    get engine(): FakeEngine {
      const engine = engines.at(-1);
      assert.ok(engine !== undefined, 'no session was opened');
      return engine;
    },
    get applies() {
      return sent.filter(
        (notification): notification is Extract<Notification, { type: 'applyEdit' }> =>
          notification.type === 'applyEdit',
      );
    },
  };
}

/** An `applyEdit` as a front-end sees it: the range, the text, and the version it is offered
 * against. */
function change(
  apply: Extract<Notification, { type: 'applyEdit' }> | undefined,
): { start: number; end: number; text: string; version: number } {
  assert.notEqual(apply, undefined, 'no such applyEdit');
  return {
    start: apply?.start ?? -1,
    end: apply?.end ?? -1,
    text: apply?.text ?? '',
    version: apply?.version ?? -1,
  };
}

/** Lets every already-resolved promise the bridge chained settle. */
async function settle(): Promise<void> {
  for (let turn = 0; turn < 8; turn += 1) {
    await Promise.resolve();
  }
}

/** A change as the text it names would take it. */
function apply(text: string, change: { start: number; end: number; text: string }): string {
  return text.slice(0, change.start) + change.text + text.slice(Math.max(change.end, change.start));
}

/**
 * The positions in `text` that are one half of a surrogate pair without the other — a code
 * unit the front-end's `vim.json.decode` refuses when it arrives as a `\uD800`–`\uDFFF`
 * escape, dropping the whole line and never answering the message it was in. Node's
 * `JSON.parse` accepts such an escape, so decoding the line is not the whole check; this is
 * the one thing the two decoders disagree on, and it is what a `text` has to be free of.
 */
function loneSurrogates(text: string): number[] {
  const found: number[] = [];
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        index += 1;
      } else {
        found.push(index);
      }
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      found.push(index);
    }
  }
  return found;
}

/** A message as the companion writes it: `main.ts`'s one JSON object per line. */
function wire(notification: Notification): string {
  return `${JSON.stringify(notification)}\n`;
}

/**
 * The front-end's half of the version protocol, as `lua/selvage/document.lua` applies it: a
 * buffer, a count of the changes it has taken, and the refusal of an `applyEdit` whose version
 * is not this document's own.
 *
 * Only the counting is modelled, in the companion's own text: where a range lands in a real
 * buffer is the Lua side's arithmetic, and `test/lua/document.lua` is where that is tested.
 * What cannot be tested there is the companion's half of the protocol, which is only observable
 * against a front-end that counts and refuses the way this one does.
 */
class FrontEnd {
  text: string;
  version = 0;
  private readonly toCompanion: Request[];

  constructor(toCompanion: Request[], text: string) {
    this.toCompanion = toCompanion;
    this.text = text;
  }

  /** A local edit: the buffer takes it, the count moves, and the companion is told. */
  edit(path: string, change: { start: number; end: number; text: string }): void {
    this.text = apply(this.text, change);
    this.version += 1;
    this.toCompanion.push({ type: 'change', path, ...change });
  }

  /** One message from the companion. A local change and an applied remote edit are one each. */
  receive(notification: Notification): void {
    if (notification.type !== 'applyEdit') {
      return;
    }
    if (notification.version !== this.version) {
      this.toCompanion.push({ type: 'applied', id: notification.id, ok: false });
      return;
    }
    this.text = apply(this.text, notification);
    this.version += 1;
    this.toCompanion.push({ type: 'applied', id: notification.id, ok: true });
  }
}

test('hosting reports the invite and the room', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  const status = it.sent.filter((notification) => notification.type === 'status');
  // A `host` opens a session; it does not end one first. Which session is given up is the
  // front-end's to ask about — see "a second host is refused".
  assert.deepEqual(
    status.map((entry) => entry.state),
    ['connecting', 'hosting'],
  );
  assert.equal(status[1]?.roomId, 'r-test');
  assert.match(status[1]?.invite ?? '', /room=r-test&token=t-test/);
});

test('a second host is refused rather than minting a second room', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  const before = it.sent.length;

  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:elsewhere' });

  assert.deepEqual(it.hosts, ['ws://127.0.0.1:0'], 'the room in hand is the only one opened');
  assert.equal(it.engine.disconnected, false, 'and it is still open');
  assert.equal(it.engine.text('notes.txt'), 'hello\n', 'with its documents where they were');
  assert.deepEqual(
    it.sent.slice(before),
    [{ type: 'refused', what: 'host', roomId: 'r-test' }],
    'the refusal names the room that stands, and says nothing else',
  );
});

test('a join while a session is live is refused the same way', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  const before = it.sent.length;

  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  assert.deepEqual(it.joins, []);
  assert.equal(it.engine.disconnected, false);
  assert.deepEqual(it.sent.slice(before), [
    { type: 'refused', what: 'join', roomId: 'r-test' },
  ]);
});

test("a joining client is told the room's peers the handshake carried", async () => {
  const peers: PeerInfo[] = [
    { peer_id: 'p-bob', display_name: 'Bob', role: 'guest' },
    { peer_id: 'p-ann', display_name: '', role: 'guest' },
  ];
  const it = harness('guest', ['notes.txt'], peers);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  const reports = it.sent
    .filter((notification) => notification.type === 'report')
    .map((notification) => notification.report as { kind: string });
  assert.deepEqual(
    reports.find((report) => report.kind === 'peers'),
    { kind: 'peers', peers },
    'who is in the room arrives with the rest of the handshake, not only when someone moves',
  );
});

test('a remote change is written when the front-end asks for it', async () => {
  const it = harness('host', [], [], { defaultAutoSave: true });
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });

  it.engine.remote('notes.txt', 'hello, world\n');

  await until("the room's change to be written", () => {
    return it.sent.some((notification) => notification.type === 'save');
  });
});

test('a remote change is not written when the front-end says not to', async () => {
  const it = harness('host', [], [], { defaultAutoSave: true });
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', autoSave: false });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });

  it.engine.remote('notes.txt', 'hello, world\n');
  // The bridge writes a settled document, and its settle window is 500ms: a write this session
  // was going to schedule has been scheduled by the end of this wait, and the sibling test
  // above shows the same stimulus reaching the write when the front-end asks for it.
  await delay(1200);
  assert.deepEqual(
    it.sent.filter((notification) => notification.type === 'save'),
    [],
    "the front-end said not to write it, and that is the front-end's setting, not this default",
  );
  assert.equal(it.engine.text('notes.txt'), 'hello, world\n', 'the room still reached the replica');
});

test('a room that is gone ends the session', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  const before = it.sent.length;

  it.engine.emit({ type: 'roomGone', reason: 'host did not return' });

  await until('the session to be given up', () =>
    it.sent.some((notification) => notification.type === 'status' && notification.state === 'idle'),
  );
  assert.deepEqual(
    it.sent.slice(before),
    [
      { type: 'report', report: { kind: 'roomGone', reason: 'host did not return' } },
      { type: 'status', state: 'idle' },
    ],
    'the reason reaches the front-end, and then the session is over rather than only reported',
  );
  assert.equal(it.engine.disconnected, true, 'the engine goes with the room');
});

test('a connection the engine gave up on leaves the next session free', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });

  it.engine.emit({ type: 'disconnected' });

  await until('the session to be given up', () =>
    it.sent.some((notification) => notification.type === 'status' && notification.state === 'idle'),
  );
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  assert.deepEqual(it.hosts.length, 2, 'a session the engine ended is not one to refuse the next for');
});

/**
 * Waits for `check` with a deadline, reporting what `seen` observed when it expires. A test that
 * sampled an asynchronous effect instead would pass or fail on how the scheduler ran that day.
 */
async function until(
  label: string,
  check: () => boolean,
  seen?: () => unknown,
): Promise<void> {
  const deadline = Date.now() + 2000;
  for (;;) {
    if (check()) {
      return;
    }
    if (Date.now() >= deadline) {
      const observed = seen === undefined ? '' : `; observed ${JSON.stringify(seen())}`;
      assert.fail(`timed out after 2000ms waiting for ${label}${observed}`);
    }
    await delay(10);
  }
}

test('a joining client is told the room documents the handshake carried', async () => {
  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  const reports = it.sent
    .filter((notification) => notification.type === 'report')
    .map((notification) => notification.report as { kind: string });
  assert.deepEqual(
    reports.find((report) => report.kind === 'documents'),
    { kind: 'documents', documents: ['notes.txt'] },
  );
});

test("a joining client is told the room's grant the handshake carried", async () => {
  const it = harness('guest', [], [], { granted: ['src/main.rs', 'notes.txt'] });

  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  const reports = it.sent.filter((notification) => notification.type === 'report');
  // The grant comes first, and the order is the front-end's to rely on: a guest materialises the
  // listing as a directory and names a document's buffer after the file it was materialised at, so
  // the listing has to be in front of the front-end before the first document is opened.
  assert.deepEqual(
    reports.map((notification) => (notification.report as { kind: string }).kind),
    ['grant', 'documents', 'peers'],
  );
  assert.deepEqual(reports[0]?.report, {
    kind: 'grant',
    paths: ['src/main.rs', 'notes.txt'],
  });
});

test('a host seeds the buffer it opens, and only once', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  assert.equal(it.engine.text('notes.txt'), 'hello\n');
  assert.deepEqual(it.engine.opened, ['notes.txt']);

  await it.companion.handle({ type: 'close', path: 'notes.txt' });
  await settle();
  assert.deepEqual(
    it.engine.closed,
    ['notes.txt'],
    'the path is released in the room, not just dropped here',
  );
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'something else\n' });
  assert.equal(it.engine.text('notes.txt'), 'hello\n');
});

test('a guest does not seed, and is filled from the replica', async () => {
  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  it.engine.texts.set('notes.txt', 'from the room\n');
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: '' });
  assert.equal(it.engine.text('notes.txt'), 'from the room\n');
  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 0, end: 0, text: 'from the room\n', version: 0 },
  ]);
});

test('a guest does not reconcile a buffer against a replica that has not arrived', async () => {  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  // The handshake names the room's documents; their text arrives with the sync, which is a
  // later message. Until it does the replica holds nothing for the path, and a buffer
  // reconciled against nothing is asked to hold the empty document — while the room may yet
  // send a seed, which the buffer would publish as its own content.
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: '' });
  assert.deepEqual(it.applies, [], 'nothing is asked of a buffer with no replica to be reconciled with');
  assert.deepEqual(
    it.engine.opened,
    ['notes.txt'],
    'and it is held in the room, which is what makes its arrival something this process hears',
  );

  // The room's text lands, and the buffer is opened against it: the edit is the seed, newline
  // and all — an empty buffer holds the empty text, so the room's text arrives whole.
  it.engine.remote('notes.txt', 'from the room\n');
  await settle();
  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 0, end: 0, text: 'from the room\n', version: 0 },
  ]);
});

test('a guest whose text arrived before the hold was answered is opened too', async () => {
  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  // The hold goes out against a replica that has nothing, and the answer to it and the sync
  // that carries the text are two messages on one connection: which arrives first is the
  // server's to decide. This is the text arriving first — the engine has nothing left to report
  // an arrival for, so the answer to the hold is the moment the document is opened.
  const opened = it.companion.handle({ type: 'open', path: 'notes.txt', text: '' });
  it.engine.texts.set('notes.txt', 'from the room\n');
  await opened;
  await settle();

  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 0, end: 0, text: 'from the room\n', version: 0 },
  ]);
});
test("a guest's edit before the room's text arrives keeps the two counts together", async () => {
  const it = harness('guest', ['notes.txt']);
  const toCompanion: Request[] = [];
  const front = new FrontEnd(toCompanion, '');
  let delivered = 0;

  /** Runs the two sides against each other until neither has anything left to say. */
  const drain = async (): Promise<void> => {
    for (let turn = 0; turn < 32; turn += 1) {
      await settle();
      if (toCompanion.length === 0 && delivered === it.sent.length) {
        return;
      }
      while (toCompanion.length > 0) {
        await it.companion.handle(toCompanion.shift() as Request);
      }
      while (delivered < it.sent.length) {
        front.receive(it.sent[delivered] as Notification);
        delivered += 1;
      }
    }
    assert.fail('the companion and the front-end never settled');
  };

  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: front.text });
  await drain();

  // The user types into the buffer before the room's text arrives. The front-end counts the
  // edit the moment it makes it, and the companion is told a moment later.
  front.edit('notes.txt', { start: 0, end: 0, text: 'x' });
  await drain();
  assert.equal(front.version, 1, 'the front-end has counted the edit');

  // The room's text lands. The count the companion offers the seed against has to be the
  // front-end's own, or the range is refused — and a range refused at a version the mirror
  // has already reached cannot be rebased, so the buffer never takes the room's text and the
  // next keystroke publishes the buffer's difference from the replica into the room.
  it.engine.remote('notes.txt', 'from the room\n');
  await drain();

  assert.equal(it.applies.length, 1, 'the buffer is seeded once the text arrives');
  assert.deepEqual(
    change(it.applies[0]),
    { start: 0, end: 1, text: 'from the room\n', version: 1 },
    "the seed is offered against the count the front-end's own document has reached",
  );
  const complaints = it.sent.filter(
    (notification) =>
      notification.type === 'report' &&
      ['applyRefused', 'divergence'].includes((notification.report as { kind: string }).kind),
  );
  assert.deepEqual(complaints, [], 'the buffer takes the room\'s text without a complaint');
  assert.equal(front.text, 'from the room\n');
  assert.equal(it.engine.text('notes.txt'), 'from the room\n');

  // A keystroke after the arrival is a keystroke: the buffer already holds the room's text, so
  // what reaches the room is the user's edit and not the buffer's difference from it.
  front.edit('notes.txt', { start: 0, end: 0, text: 'y' });
  await drain();
  assert.equal(it.engine.text('notes.txt'), 'yfrom the room\n');
  assert.equal(front.text, 'yfrom the room\n');
});

test('a local change reaches the replica as the smallest edit', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  await it.companion.handle({
    type: 'change',
    path: 'notes.txt',
    start: 5,
    end: 5,
    text: ', world',
  });
  assert.equal(it.engine.text('notes.txt'), 'hello, world\n');
});

test('a remote change is asked for as a range, not a whole document', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  it.engine.remote('notes.txt', 'hello, world\n');
  await settle();
  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 5, end: 5, text: ', world', version: 0 },
  ]);

  // The front-end applied it: the mirror moves with the buffer, and nothing further is asked.
  await it.companion.handle({ type: 'applied', id: 1, ok: true });
  await settle();
  assert.equal(it.applies.length, 1);
});

test('an astral edit reaches the front-end as whole characters it can decode', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'a\u{1F601}b\n' });

  // A peer replaces one emoji with another. The two share a high surrogate, and a diff that
  // walked one code unit at a time left the change boundary between the halves: the range was
  // `[2, 3)` and its text a lone `\ude00`. That is not an edit any editor can make, and the
  // front-end never saw it — `vim.json.decode` refuses the escape, drops the line, and the
  // `applyEdit` is never answered, so the bridge holds that document for the rest of the
  // session, taking no remote edits and publishing no local ones. The change gives up one code
  // unit at each end instead and carries the whole character.
  it.engine.remote('notes.txt', 'a\u{1F600}b\n');
  await settle();
  assert.deepEqual(
    change(it.applies[0]),
    { start: 1, end: 3, text: '\u{1F600}', version: 0 },
    'one replacement of the whole character, not half of one',
  );

  // The same edit as the front-end receives it: the serialized line, not the object, decoded
  // the way the newline-delimited reader hands it on. It has to be JSON a decoder takes, and
  // its text whole characters — the shape the bug broke and this test exists to keep.
  const notification = it.applies[0];
  assert.ok(notification);
  const line = wire(notification);
  const decoded = JSON.parse(line) as { start: number; end: number; text: string };
  assert.deepEqual(loneSurrogates(decoded.text), [], 'no half character reaches the decoder');
  assert.equal(
    apply('a\u{1F601}b\n', decoded),
    'a\u{1F600}b\n',
    'and the decoded change is the one that gets there',
  );
});

test('an edit the front-end refused is offered again where its buffer has it', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });

  // A peer's edit: the companion asks for it against version 0 ...
  it.engine.remote('notes.txt', 'hello, world\n');
  await settle();
  assert.deepEqual(change(it.applies[0]), { start: 5, end: 5, text: ', world', version: 0 });

  // ... while the user's own edit was already in the pipe, so the front-end's count has
  // moved on and it refuses the range it was handed: that range is in the coordinates of a
  // text its buffer no longer holds.
  await it.companion.handle({ type: 'change', path: 'notes.txt', start: 0, end: 0, text: '> ' });
  await it.companion.handle({ type: 'applied', id: 1, ok: false });
  await settle();

  // The refusal is not the editor saying it cannot hold the edit; it is the editor saying the
  // range no longer fits, and the companion knows by how much: the mirror has taken a change
  // the front-end counted after the apply was computed. The same edit is offered again, moved
  // through that change, so that it lands where the buffer now has the text it was computed
  // from.
  assert.deepEqual(
    change(it.applies[1]),
    { start: 7, end: 7, text: ', world', version: 1 },
    'the peer\'s edit, moved by the two characters the user typed before it',
  );

  await it.companion.handle({ type: 'applied', id: 2, ok: true });
  await settle();

  // Two things now hold that did not before: the room has the user's edit, and the buffer
  // still has it. The keystroke made inside the IPC round trip is merged with the room's
  // rather than annihilated by it.
  assert.equal(it.engine.text('notes.txt'), '> hello, world\n');
});

test('a refusal the buffer has no room for is worked out again from the mirror', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });

  it.engine.remote('notes.txt', 'hello, world\n');
  await settle();
  assert.deepEqual(change(it.applies[0]), { start: 5, end: 5, text: ', world', version: 0 });

  // The user's edit replaced the text the peer's range lands in, so there is no position to
  // move it to: what the peer wrote and what the user wrote are about the same characters,
  // and nothing short of a merge can keep both. The room's text is what the buffer ends on,
  // and the local edit is superseded rather than mangled into the room — the honest outcome
  // for a genuine conflict, and the one the backstop would reach anyway.
  await it.companion.handle({ type: 'change', path: 'notes.txt', start: 3, end: 6, text: 'p' });
  await it.companion.handle({ type: 'applied', id: 1, ok: false });
  await settle();

  assert.deepEqual(change(it.applies[1]), { start: 3, end: 4, text: 'lo, world\n', version: 1 });
  await it.companion.handle({ type: 'applied', id: 2, ok: true });
  await settle();
  assert.equal(it.engine.text('notes.txt'), 'hello, world\n');
});

test('an unmatched edit is reported rather than retried for ever', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  it.engine.remote('notes.txt', 'hello, world\n');
  await settle();
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await it.companion.handle({ type: 'applied', id: attempt, ok: false });
    await settle();
  }
  assert.equal(it.applies.length, 3);
  assert.deepEqual(
    it.sent.filter((notification) => notification.type === 'report').at(-1)?.report,
    { kind: 'applyRefused', path: 'notes.txt' },
  );
});

test('a selection is published in the replica offsets', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  await it.companion.handle({ type: 'selection', path: 'notes.txt', anchor: 1, head: 3 });
  assert.deepEqual(it.engine.selections, [
    { path: 'notes.txt', selection: { anchor: 1, head: 3 } },
  ]);
});

test('a document opened after a peer moved draws the peer', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  // The peer's awareness and the caret it resolves to are both already here; only the
  // document is missing, so `cursors()` skips the peer until it opens.
  it.engine.presences = [
    {
      clientId: 2,
      peer: { peer_id: 'p-bob', display_name: 'Bob', role: 'guest' },
      state: { path: 'notes.txt', selection: { anchor: { assoc: 0 }, head: { assoc: 0 } } },
    },
  ];
  it.engine.resolved.set('notes.txt', { anchor: 0, head: 2 });
  assert.equal(it.sent.filter((notification) => notification.type === 'presence').length, 0);

  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  const presence = it.sent.filter((notification) => notification.type === 'presence').at(-1);
  assert.equal(presence?.cursors.length, 1);
  assert.equal(presence?.cursors[0]?.label, 'Bob');
  assert.equal(presence?.cursors[0]?.path, 'notes.txt');
  assert.equal(presence?.cursors[0]?.head, 2);
});

test('a mid-session rename reaches the engine and moves no document', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  const opened = [...it.engine.opened];

  await it.companion.handle({ type: 'rename', displayName: 'Ada' });
  assert.deepEqual(it.engine.renamed, ['Ada']);
  assert.deepEqual(it.engine.opened, opened, 'a name is not a document: nothing is opened');
  assert.deepEqual(it.engine.closed, [], 'and nothing is closed');
  assert.deepEqual(
    it.sent.filter(
      (notification) =>
        notification.type === 'report' &&
        (notification.report as { kind: string }).kind === 'sessionError',
    ),
    [],
    'an accepted rename is not an error',
  );
});

test('a refused rename is reported and leaves the session running', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  const refused = 'x'.repeat(33);
  it.engine.renameError = new ProtocolError(
    'bad_params',
    'display_name is longer than 32 UTF-16 code units',
  );

  await it.companion.handle({ type: 'rename', displayName: refused });
  await settle();

  assert.deepEqual(
    it.sent.filter(
      (notification) =>
        notification.type === 'report' &&
        (notification.report as { kind: string }).kind === 'sessionError',
    ),
    [
      {
        type: 'report',
        report: {
          kind: 'sessionError',
          code: 'bad_params',
          message: `the server refused the display name "${refused}": display_name is longer than 32 UTF-16 code units`,
        },
      },
    ],
    'the refusal is the server declining the name, said as a session error',
  );
  assert.equal(it.engine.disconnected, false, 'a refused name does not end the session');
});

test('leaving disconnects and forgets the documents', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  await it.companion.handle({ type: 'leave' });
  assert.equal(it.engine.disconnected, true);
  assert.equal(it.sent.at(-1)?.type, 'status');

  // Nothing arrives for a document the session no longer has.
  const before = it.sent.length;
  it.engine.remote('notes.txt', 'changed\n');
  await settle();
  assert.equal(it.sent.length, before);
});

test('the line reader reassembles a message split across chunks', () => {
  const lines: string[] = [];
  const reader = new LineReader((line) => lines.push(line));
  reader.push('{"type":"le');
  reader.push('ave"}\n{"type":"clo');
  assert.deepEqual(lines, ['{"type":"leave"}']);
  reader.push('se","path":"a"}\n\n');
  assert.deepEqual(lines, ['{"type":"leave"}', '{"type":"close","path":"a"}']);
});

test('a line past the bound is shed with a word, and the next line still arrives', () => {
  // A whole-document `open` is one JSON line, so the bound has to clear real work; a runaway
  // write past it is shed to its newline instead of growing the buffer — and re-scanning
  // it per chunk — for the life of the process.
  const lines: string[] = [];
  const drops: number[] = [];
  const reader = new LineReader(
    (line) => lines.push(line),
    (bytes) => drops.push(bytes),
  );
  const overlong = 'x'.repeat(MAX_IPC_LINE_BYTES + 1);
  reader.push(`${overlong}\n{"type":"leave"}\n`.slice(0, MAX_IPC_LINE_BYTES + 1));
  reader.push(`${overlong}\n{"type":"leave"}\n`.slice(MAX_IPC_LINE_BYTES + 1));
  assert.equal(drops.length, 1, 'the runaway line was shed once');
  assert.deepEqual(lines, ['{"type":"leave"}'], 'and the line after it arrived');
});

test('the bound counts UTF-8 bytes, not code units', () => {
  // `String.length` counts UTF-16 code units and stdin is decoded as UTF-8: 12M `€` are
  // 12M units but 36M bytes on the wire — under a unit-counted bound, over a byte one.
  const lines: string[] = [];
  const drops: number[] = [];
  const reader = new LineReader(
    (line) => lines.push(line),
    (bytes) => drops.push(bytes),
  );
  reader.push(`${'€'.repeat(12 * 1024 * 1024)}\n{"type":"leave"}\n`);
  assert.equal(drops.length, 1, 'the wide line was shed');
  assert.ok(drops[0] as number > MAX_IPC_LINE_BYTES, 'and told in bytes');
  assert.deepEqual(lines, ['{"type":"leave"}'], 'and the line after it arrived');
});

// -- the IPC mouth, both directions ----------------------------------------------------
//
// A misshapen message answered blindly is a crash down the line, where the failure names
// nothing about the message that caused it. The stdin mouth drops what is not a request;
// `handle` drops it too, for the caller that did not come through stdin.

test('a line that is not a request is refused before it is queued', () => {
  // A notification echoed back, a newer front-end's new message, a `host` with nowhere to
  // host, a `change` whose offsets are strings, a line that decoded to a bare value.
  for (const line of [
    '{"type":"presence","cursors":[]}',
    '{"type":"frobnicate"}',
    '{"type":"host"}',
    '{"type":"change","path":"a","start":"0","end":1,"text":"x"}',
    '{"type":"save","id":7}',
    '7',
    '"leave"',
    '{}',
  ]) {
    assert.equal(isRequest(JSON.parse(line) as unknown), false, line);
  }
  assert.equal(
    isRequest({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: 'proj' }),
    true,
    'a whole request still passes',
  );
  assert.equal(isRequest({ type: 'leave' }), true, 'and a bare one too');
});

test('a misshapen request handled directly is dropped, not answered', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host' } as unknown as Request);
  assert.deepEqual(it.hosts, [], 'no room was opened for a host with no server');
  assert.deepEqual(it.sent, [], 'and nothing was answered');
});

// -- the grant, host-side ------------------------------------------------------------
//
// The folder the front-end names with `host` is the one a path a peer asks for is read out of.
// Every tree here is built under this checkout's `.tmp/`, never the host's own, so that a
// symbolic link can be put in the way of a guess.

/** Writes a file, making its directories. */
function tree(root: string, path: string, body = 'x\n'): void {
  const absolute = join(root, path);
  mkdirSync(join(absolute, '..'), { recursive: true });
  writeFileSync(absolute, body);
}

const SCRATCH = resolve(import.meta.dirname, '..', '.tmp');

/** A folder of its own for one test, cleaned up with it. */
function folder(t: { after: (fn: () => void) => void }): string {
  mkdirSync(SCRATCH, { recursive: true });
  const root = mkdtempSync(join(SCRATCH, 'companion-grant-'));
  t.after(() => {
    rmSync(root, { recursive: true, force: true });
  });
  return root;
}

/** The session errors reported so far. */
function refusals(it: Harness): string[] {
  return it.sent
    .filter(
      (notification): notification is Extract<Notification, { type: 'report' }> =>
        notification.type === 'report' &&
        (notification.report as { kind: string }).kind === 'sessionError',
    )
    .map((notification) => (notification.report as { message: string }).message);
}

// The read is real file system work, which lands on a later turn of the event loop than a drain
// of the microtask queue ever reaches: `until` is the wait for it, and `settle` is only enough
// for work that is already resolved.

test('a path the room asks for is read off the folder and put into the replica', async (t) => {
  const root = folder(t);
  tree(root, 'never-opened.txt', 'the host never opened this\n');
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });

  // A peer opened it: the room's document set moves, and the host is what supplies content.
  it.engine.emit({ type: 'documentsChanged', documents: ['never-opened.txt'] });
  await until(
    'the path to be seeded from the folder',
    () => it.engine.has('never-opened.txt'),
    () => it.engine.text('never-opened.txt'),
  );

  assert.equal(it.engine.text('never-opened.txt'), 'the host never opened this\n');
  assert.deepEqual(refusals(it), []);
});

test('a path the room asks for is read once, however often the room asks', async (t) => {
  const root = folder(t);
  tree(root, 'never-opened.txt', 'the host never opened this\n');
  tree(root, 'asked-again.txt', 'the room asked for this one too\n');
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });

  it.engine.emit({ type: 'documentsChanged', documents: ['never-opened.txt'] });
  await until(
    'the path to be seeded once',
    () => it.engine.has('never-opened.txt'),
    () => it.engine.text('never-opened.txt'),
  );
  assert.deepEqual(it.editor.reads, ['never-opened.txt'], 'the path was read off the folder');

  // The room restates its open-document set, with a name in it this window has not been asked
  // for — and the first name's file is gone, so a read of it could only end in a refusal to
  // report. The new name's read is real file system work, so the wait below is for this emit to
  // have been handled rather than for a number of turns.
  rmSync(join(root, 'never-opened.txt'));
  it.engine.emit({
    type: 'documentsChanged',
    documents: ['never-opened.txt', 'asked-again.txt'],
  });
  await until(
    'the name that is new to be seeded',
    () => it.engine.has('asked-again.txt'),
    () => it.engine.text('asked-again.txt'),
  );

  // Whether the disk was gone back to for the first name is settled with the event rather than
  // after it: `seedRequested` consults the guard it recorded the path in *before* it asks the
  // host for anything, and the recording of the read is that ask. There is no turn to wait for,
  // and a count taken here cannot be one taken too early.
  assert.deepEqual(
    it.editor.reads,
    ['never-opened.txt', 'asked-again.txt'],
    'the path the room had already been answered for was read again',
  );
  assert.equal(
    it.engine.text('never-opened.txt'),
    'the host never opened this\n',
    'the repeat ask put something else into the room',
  );
  assert.deepEqual(refusals(it), [], 'the repeat ask reported a refusal for a read it did not make');
});

test('a path outside the folder is dropped silently, never read and never reported', async (t) => {
  const root = folder(t);
  const outside = join(root, 'outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'not inside the folder\n');
  const walled = join(root, 'walled');
  mkdirSync(walled, { recursive: true });
  tree(walled, 'wall.txt', 'ordinary\n');

  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: walled });

  // A path the grant would never publish — `..`, an excluded name, an over-long one — is
  // not something a peer can talk the room into: it is dropped before any read, so a
  // guessed secret buys no dialog confirming it, and a bogus listing buys no read at all.
  it.engine.emit({ type: 'documentsChanged', documents: ['../outside/secret.txt', 'wall.txt'] });
  await until(
    'the grantable path to be seeded from the folder',
    () => it.engine.has('wall.txt'),
    () => it.engine.text('wall.txt'),
  );

  assert.equal(it.engine.text('../outside/secret.txt'), '', 'nothing was shared for it');
  assert.deepEqual(it.editor.reads, ['wall.txt'], 'the path outside the folder was never read');
  assert.deepEqual(refusals(it), [], 'the path outside the folder was never reported');
});

test('a path through a directory link is refused and reported', async (t) => {
  const root = folder(t);
  const outside = join(root, 'outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'a readable plain file, outside the folder\n');
  const shared = join(root, 'shared');
  mkdirSync(shared, { recursive: true });
  symlinkSync(outside, join(shared, 'escape'));

  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: shared });
  it.engine.emit({ type: 'documentsChanged', documents: ['escape/secret.txt'] });
  await until(
    'the refusal to be reported',
    () => refusals(it).length > 0,
    () => refusals(it),
  );

  assert.equal(it.engine.text('escape/secret.txt'), '', 'nothing was shared for it');
  assert.deepEqual(refusals(it), [
    'could not share escape/secret.txt: it is not a readable file in the folder this window shares (it may have been deleted after the listing was published); nothing was shared for it',
  ]);
});

test('one bogus listing is one dialog, never one per path', async (t) => {
  const root = folder(t);
  const walled = join(root, 'walled');
  mkdirSync(walled, { recursive: true });

  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: walled });

  it.engine.emit({
    type: 'documentsChanged',
    documents: ['gone-1.txt', 'gone-2.txt', 'gone-3.txt', '../evil', '.env'],
  });
  await until(
    'the aggregated refusal to be reported',
    () => refusals(it).length === 1,
    () => refusals(it),
  );

  // One report for the whole event, however many paths failed it: a listing of N unknown
  // paths is one dialog, never N.
  assert.match(refusals(it)[0] ?? '', /could not share 3 paths the room asked for/);
  assert.match(refusals(it)[0] ?? '', /nothing was shared for them/);
  // The ungrantable two were dropped silently: never read, never reported.
  assert.deepEqual(it.editor.reads, ['gone-1.txt', 'gone-2.txt', 'gone-3.txt']);

  // One failure on its own still reads as it always did: the sentence this client shares
  // with the other one, pinned word for word.
  it.engine.emit({ type: 'documentsChanged', documents: ['gone-4.txt'] });
  await until(
    'the single refusal to be reported',
    () => refusals(it).length === 2,
    () => refusals(it),
  );
  assert.equal(
    refusals(it)[1],
    'could not share gone-4.txt: it is not a readable file in the folder this window shares (it may have been deleted after the listing was published); nothing was shared for it',
  );
});

test('a locally opened file the grant excludes is refused once, not seeded', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: '.env', text: 'SECRET=1\n' });

  // A file the user opened is still one the room has to carry: the grant's own rule gates
  // it exactly as it gates a peer's request, so opening it shares nothing. The refusal is
  // said once per path, out loud, rather than seeded as an empty document.
  assert.deepEqual(refusals(it), [
    'will not share .env with the room: it is not a path the room shares (excluded from the grant, or escaping the folder); nothing was shared for it',
  ]);
  assert.equal(it.engine.has('.env'), false, 'a refused file entered the replica');
  assert.deepEqual(it.engine.opened, [], 'a refused file was held in the room');

  // The editor re-fires the open event on focus or split, and that must not nag.
  await it.companion.handle({ type: 'open', path: '.env', text: 'SECRET=1\n' });
  assert.equal(refusals(it).length, 1, 'reopening a refused file nagged again');
});

test('a locally opened file over the size a session carries is refused', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  const big = `${'x'.repeat(MAX_GRANT_FILE_BYTES + 1)}\n`;
  await it.companion.handle({ type: 'open', path: 'big.log', text: big });

  assert.equal(refusals(it).length, 1);
  assert.match(refusals(it)[0] ?? '', /will not share big\.log with the room/);
  assert.match(refusals(it)[0] ?? '', /over the 1048576 bytes a session will carry/);
  assert.match(refusals(it)[0] ?? '', /nothing was shared for it/);
  assert.equal(it.engine.has('big.log'), false, 'an oversized file entered the replica');
});
test('a host publishes the listing of the folder the session started in', async (t) => {
  const root = folder(t);
  tree(root, 'notes.txt', 'a note\n');
  tree(root, 'src/main.rs', 'fn main() {}\n');
  tree(root, '.env', 'TOKEN=1\n');
  tree(root, 'node_modules/left-pad/index.js', 'module.exports = 1;\n');

  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the listing to reach the engine',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );

  assert.deepEqual(it.engine.grants, [['notes.txt', 'src/main.rs']]);
});

test('a host with no folder publishes nothing at all', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  await settle();

  // A listing is a reading of a folder, and this session never named one: the host is pointed at a
  // folder as the session is built, and a listing is only ever worked out for a folder that is.
  // The replica's own listing cannot say that much — nothing arriving is also what a reading that
  // has not landed yet looks like — so the host's folder is what settles it.
  assert.deepEqual(it.editor.folders, [], 'a front-end that named no folder pointed the host at none');
  assert.deepEqual(it.engine.grants, [], 'a front-end that named no folder has no listing');
  assert.deepEqual(refusals(it), [], 'and nothing to say about one');
});

test('a server that does not know doc.grant is a room with no grant, not a fault', async (t) => {
  const root = folder(t);
  const it = harness('host', [], [], {
    grantError: new ProtocolError('unknown_method', 'doc.grant is not a method here'),
  });

  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the listing to reach the engine',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );

  assert.equal(it.engine.grants.length, 1, 'the listing was sent');
  assert.deepEqual(refusals(it), [], 'and the answer ended there');
  assert.equal(it.engine.disconnected, false, 'the session goes on');
});

test('a refused listing is reported and changes nothing', async (t) => {
  const root = folder(t);
  const it = harness('host', [], [], {
    grantError: new ProtocolError('bad_params', 'the listing is too long'),
  });

  await it.companion.handle({
    type: 'host',
    serverUrl: 'ws://127.0.0.1:0',
    root,
  });
  await until(
    'the refusal to be reported',
    () => refusals(it).length > 0,
    () => refusals(it),
  );

  assert.deepEqual(refusals(it), [
    'the server refused the listing of the folder this session shares: the listing is too long',
  ]);
  assert.equal(it.engine.disconnected, false, 'a refused listing does not end the session');
});

// -- the folder watched while hosting --------------------------------------------------
//
// The room's grant is a listing of the folder the session shares, and a file created, deleted or
// renamed under it is a change to that listing. A host watches the folder while it hosts — a guest
// has no folder to publish — and republishes when it changes, once per burst and only when the
// listing actually differs. A watcher that outlives its session is as much a defect as a listing
// that never moves: it would republish the folder of a room nobody is in.

/** The window a burst of changes is gathered in, as `companion/session.ts` sets it. */
const SETTLE_MS = 250;

/** How long a test waits to say that nothing is owed: longer than any burst could schedule. */
const QUIET_MS = 3 * SETTLE_MS;

/** A host with a folder of its own, waiting until the initial listing has reached the engine. */
async function hosting(
  t: { after: (fn: () => void) => void },
  files: Record<string, string> = { 'notes.txt': 'a note\n' },
  options: { grantError?: Error } = {},
): Promise<{ root: string; it: Harness }> {
  const root = folder(t);
  for (const [path, body] of Object.entries(files)) {
    tree(root, path, body);
  }
  const it = harness('host', [], [], options);
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the folder to be published as the session starts',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );
  return { root, it };
}

test('a file created under the host root is republished', async (t) => {
  const { root, it } = await hosting(t);

  tree(root, 'created.txt', 'made while hosting\n');

  await until(
    'the created path to be published',
    () => it.engine.grants.at(-1)?.includes('created.txt') === true,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [['notes.txt'], ['created.txt', 'notes.txt']]);
});

test('a file created in a subdirectory is republished', async (t) => {
  // `fs.watch` honours `recursive` only on macOS and Windows: on Linux a watcher on the
  // root alone never fires for anything under a subdirectory, so the room's listing would go
  // stale for the whole tree below it.
  const { root, it } = await hosting(t, { 'notes.txt': 'a note\n', 'src/main.rs': 'fn main() {}\n' });
  assert.deepEqual(it.engine.grants, [['notes.txt', 'src/main.rs']]);

  tree(root, 'src/created.rs', 'made while hosting\n');

  await until(
    'the created path to be published',
    () => it.engine.grants.at(-1)?.includes('src/created.rs') === true,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [
    ['notes.txt', 'src/main.rs'],
    ['notes.txt', 'src/created.rs', 'src/main.rs'],
  ]);
});

test('a directory created while hosting is watched', async (t) => {
  // A directory that did not exist when the session started has no watcher yet: the mkdir
  // fires its parent, the republish that follows learns the new directory, and only a watcher
  // set rebuilt after that republish sees what lands inside it afterwards.
  const { root, it } = await hosting(t);

  mkdirSync(join(root, 'later'));
  await delay(QUIET_MS);
  assert.deepEqual(it.engine.grants, [['notes.txt']], 'an empty directory names no paths');

  tree(root, 'later/inside.rs', 'made after the directory\n');

  await until(
    'the path in the new directory to be published',
    () => it.engine.grants.at(-1)?.includes('later/inside.rs') === true,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [['notes.txt'], ['later/inside.rs', 'notes.txt']]);
});

test('a file deleted under the host root is republished', async (t) => {
  const { root, it } = await hosting(t, { 'notes.txt': 'a note\n', 'gone.txt': 'to be deleted\n' });
  assert.deepEqual(it.engine.grants, [['gone.txt', 'notes.txt']]);

  rmSync(join(root, 'gone.txt'));

  await until(
    'the deleted path to leave the listing',
    () => it.engine.grants.length > 1 && it.engine.grants.at(-1)?.includes('gone.txt') === false,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [['gone.txt', 'notes.txt'], ['notes.txt']]);
});

test('a burst of changes is one republish', async (t) => {
  const { root, it } = await hosting(t);

  // A `git checkout` or a build looks like this: many changes, spread over a moment. Each write is
  // given its turn, so the events are delivered as the files land rather than after them — without
  // the window each of them would be its own walk of the tree and its own frame.
  const burst = 20;
  for (let index = 0; index < burst; index += 1) {
    tree(root, `burst-${String(index).padStart(2, '0')}.txt`);
    await delay(1);
  }

  await until(
    'the burst to be published',
    () => it.engine.grants.at(-1)?.includes('burst-19.txt') === true,
    () => it.engine.grants.length,
  );
  assert.equal(it.engine.grants.length, 2, 'the burst was gathered into one listing');
  assert.equal(it.engine.grants[1]?.length, burst + 1, 'and that listing holds every created path');
});

test('an unchanged folder is republished to no one', async (t) => {
  const { root, it } = await hosting(t);

  // Nothing touches the folder, so nothing is owed. Nothing arriving is only evidence once the
  // window a burst could schedule a republish in has certainly passed, so the change below is
  // what keeps this from passing because the watcher never worked at all.
  await delay(QUIET_MS);
  assert.deepEqual(it.engine.grants, [['notes.txt']], 'a folder that did not change published once');

  tree(root, 'after.txt');
  await until(
    'the watcher to still be alive after the quiet window',
    () => it.engine.grants.length === 2,
    () => it.engine.grants,
  );
});

test('a change that leaves the listing as it was is not republished', async (t) => {
  const { root, it } = await hosting(t);

  // Content is not in the listing: writing over a file the listing already names is an event, and
  // a republish that ran on it would hand the room the listing it already has. What is compared is
  // the listing, not the event.
  tree(root, 'notes.txt', 'the same path, different content\n');

  await delay(QUIET_MS);
  assert.deepEqual(
    it.engine.grants,
    [['notes.txt']],
    'the listing was unchanged, so there was nothing to publish',
  );
});

test('the folder is published again by the next session', async (t) => {
  const { root, it } = await hosting(t);
  const first = it.engine;

  await it.companion.handle({ type: 'leave' });
  tree(root, 'after-leave.txt');

  // The watcher belonged to the session that opened it. A file arriving after it has ended is a
  // change to a folder nobody is sharing, and publishing it would offer the room a listing the
  // session that left had no business reading.
  await delay(QUIET_MS);
  assert.deepEqual(first.grants, [['notes.txt']], 'a session that ended published nothing further');

  // And a session that starts after it publishes the folder rather than comparing it with the
  // listing the one before it sent: the folder is back to exactly what it was.
  rmSync(join(root, 'after-leave.txt'));
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the next session to publish the folder',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );
  assert.notEqual(it.engine, first, 'a second session is a second room');
  assert.deepEqual(it.engine.grants, [['notes.txt']]);
});

test('a folder a session has left is not published by the next one', async (t) => {
  const shared = folder(t);
  tree(shared, 'a.txt');
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: shared });
  await until('the first folder to be published', () => it.engine.grants.length > 0, () => it.engine.grants);

  await it.companion.handle({ type: 'leave' });

  const second = folder(t);
  tree(second, 'b.txt');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: second });
  const session = it.engine;
  await until('the second folder to be published', () => session.grants.length > 0, () => session.grants);
  assert.deepEqual(session.grants, [['b.txt']]);

  // The folder the first session shared changes, and nobody is sharing it anymore. A watcher that
  // outlived its session would read it and publish it into the room the second session is hosting.
  tree(shared, 'later.txt');
  await delay(QUIET_MS);
  assert.deepEqual(session.grants, [['b.txt']], 'a folder a session has left was published');
});

test('a reading that finishes after a later one does not publish', async (t) => {
  const root = folder(t);
  tree(root, 'notes.txt', 'a note\n');

  // A real walk of a folder this size takes a few milliseconds and never overlaps itself, which is
  // exactly why the guard needs a walk the test holds open: the two readings have to be in flight
  // at once for the one that started first to be able to finish last.
  const readings: Array<(paths: string[]) => void> = [];
  const it = harness('host', [], [], {
    enumerate: () =>
      new Promise((resolve) => {
        readings.push(resolve);
      }),
  });

  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until('the first reading of the folder to start', () => readings.length === 1, () => readings.length);

  // A change while that reading is in flight: the window passes, the timer fires, and the reading
  // it starts is the one that finishes first — the folder as it is now.
  tree(root, 'created.txt', 'made while hosting\n');
  await until('a second reading to start', () => readings.length === 2, () => readings.length);
  readings[1]?.(['created.txt', 'notes.txt']);
  await until(
    'the later reading to reach the room',
    () => it.engine.grants.length === 1,
    () => it.engine.grants,
  );

  // The reading that started first now finishes, with the folder as it was before the change. It
  // is older than the one the room was given, and nothing would put the room right until the
  // folder changed again.
  readings[0]?.(['notes.txt']);
  await delay(QUIET_MS);
  assert.deepEqual(
    it.engine.grants,
    [['created.txt', 'notes.txt']],
    'the reading that started first published the folder as it was',
  );
});

test('a guest watches nothing and publishes no listing', async () => {
  const it = harness('guest');
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  await delay(QUIET_MS);
  assert.deepEqual(it.engine.grants, [], 'a guest has no folder of its own to publish');
});

test('a folder that cannot be watched is reported and the session goes on', async (t) => {
  // A NUL byte is the one folder this platform's real `fs.watch` refuses outright; no
  // arrangement of directories makes a recursive watch of an existing tree fail here.
  const root = `${folder(t)}/unwatchable\u0000name`;
  const it = harness('host');

  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });
  await until('the refusal to be reported', () => refusals(it).length > 0, () => refusals(it));

  assert.match(
    refusals(it)[0] ?? '',
    /^could not watch the folder this session shares: /,
    'the report names the folder and the reason',
  );
  assert.equal(it.engine.disconnected, false, 'a folder that cannot be watched does not end the session');
});

