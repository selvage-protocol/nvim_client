/**
 * The companion against a replica with no server behind it: what a front-end's message does
 * to the room, what the room asks a front-end to do, and the one race the local IPC has of
 * its own — a remote edit and a local one crossing in the pipe.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { LineReader } from '../companion/ipc.ts';
import type { Notification, Request } from '../companion/ipc.ts';
import { Companion } from '../companion/session.ts';

import { FakeEngine } from './helpers/fake-engine.ts';

interface Harness {
  companion: Companion;
  engine: FakeEngine;
  sent: Notification[];
  /** The `applyEdit`s asked for so far. */
  applies: Array<Extract<Notification, { type: 'applyEdit' }>>;
}

function harness(role: 'host' | 'guest' = 'host', documents: string[] = []): Harness {
  const engine = new FakeEngine(role, documents);
  const sent: Notification[] = [];
  const companion = new Companion({
    send: (notification) => sent.push(notification),
    autoSave: false,
    engines: {
      host: () => Promise.resolve(engine),
      join: () => Promise.resolve(engine),
    },
  });
  return {
    companion,
    engine,
    sent,
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
  assert.deepEqual(
    status.map((entry) => entry.state),
    ['idle', 'connecting', 'hosting'],
  );
  assert.equal(status[2]?.roomId, 'r-test');
  assert.match(status[2]?.invite ?? '', /room=r-test&token=t-test/);
});

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
