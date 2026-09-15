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

import { LineReader } from '../companion/ipc.ts';
import type { Notification, Request } from '../companion/ipc.ts';
import { Companion } from '../companion/session.ts';
import { ProtocolError } from '../vendor/engine/index.ts';
import type { PeerInfo } from '../vendor/engine/envelope.ts';

import { FakeEngine } from './helpers/fake-engine.ts';

interface Harness {
  companion: Companion;
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
  options: { defaultAutoSave?: boolean } = {},
): Harness {
  const sent: Notification[] = [];
  const hosts: string[] = [];
  const joins: string[] = [];
  const engines: FakeEngine[] = [];
  const open = (): FakeEngine => {
    const engine = new FakeEngine(role, documents, peers);
    engines.push(engine);
    return engine;
  };
  const companion = new Companion({
    send: (notification) => sent.push(notification),
    autoSave: options.defaultAutoSave ?? false,
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
    .map((notification) => notification.report);
  assert.deepEqual(reports[0], { kind: 'documents', documents: ['notes.txt'] });
  assert.deepEqual(
    reports[1],
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
  const reports = it.sent.filter((notification) => notification.type === 'report');
  assert.deepEqual(reports[0]?.report, { kind: 'documents', documents: ['notes.txt'] });
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
  // reconciled against nothing is asked to hold the empty document — which a Neovim buffer
  // cannot, because its text always ends in a newline.
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: '\n' });
  assert.deepEqual(it.applies, [], 'nothing is asked of a buffer with no replica to be reconciled with');
  assert.deepEqual(
    it.engine.opened,
    ['notes.txt'],
    'and it is held in the room, which is what makes its arrival something this process hears',
  );

  // The room's text lands, and the buffer is opened against it: the edit is the seed, not a
  // removal of the newline the buffer has and the room's document does not.
  it.engine.remote('notes.txt', 'from the room\n');
  await settle();
  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 0, end: 0, text: 'from the room', version: 0 },
  ]);
});

test('a guest whose text arrived before the hold was answered is opened too', async () => {
  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  // The hold goes out against a replica that has nothing, and the answer to it and the sync
  // that carries the text are two messages on one connection: which arrives first is the
  // server's to decide. This is the text arriving first — the engine has nothing left to report
  // an arrival for, so the answer to the hold is the moment the document is opened.
  const opened = it.companion.handle({ type: 'open', path: 'notes.txt', text: '\n' });
  it.engine.texts.set('notes.txt', 'from the room\n');
  await opened;
  await settle();

  assert.deepEqual(it.applies, [
    { type: 'applyEdit', id: 1, path: 'notes.txt', start: 0, end: 0, text: 'from the room', version: 0 },
  ]);
});
test("a guest's edit before the room's text arrives keeps the two counts together", async () => {
  const it = harness('guest', ['notes.txt']);
  const toCompanion: Request[] = [];
  const front = new FrontEnd(toCompanion, '\n');
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
    { start: 0, end: 1, text: 'from the room', version: 1 },
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
  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root });

  it.engine.emit({ type: 'documentsChanged', documents: ['never-opened.txt'] });
  await until(
    'the path to be seeded once',
    () => it.engine.has('never-opened.txt'),
    () => it.engine.text('never-opened.txt'),
  );
  // The file goes away, so a second read could only end in a refusal to report.
  rmSync(join(root, 'never-opened.txt'));
  it.engine.emit({ type: 'documentsChanged', documents: ['never-opened.txt'] });
  await settle();

  assert.equal(it.engine.text('never-opened.txt'), 'the host never opened this\n');
  assert.deepEqual(refusals(it), [], 'the path was asked for once and not gone back to disk for');
});

test('a path outside the folder is refused and reported, not seeded empty', async (t) => {
  const root = folder(t);
  const outside = join(root, 'outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'secret.txt'), 'not inside the folder\n');
  const walled = join(root, 'walled');
  mkdirSync(walled, { recursive: true });

  const it = harness('host');
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0', root: walled });
  it.engine.emit({ type: 'documentsChanged', documents: ['../outside/secret.txt'] });
  await until(
    'the refusal to be reported',
    () => refusals(it).length > 0,
    () => refusals(it),
  );

  assert.equal(it.engine.text('../outside/secret.txt'), '', 'nothing was shared for it');
  assert.deepEqual(refusals(it), [
    'the room asked for ../outside/secret.txt, which is not a readable file in the folder this window shares; nothing was shared for it',
  ]);
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
    'the room asked for escape/secret.txt, which is not a readable file in the folder this window shares; nothing was shared for it',
  ]);
});
