/**
 * The companion against a replica with no server behind it: what a front-end's message does
 * to the room, what the room asks a front-end to do, and the one race the local IPC has of
 * its own — a remote edit and a local one crossing in the pipe.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { LineReader } from '../companion/ipc.ts';
import type { Notification } from '../companion/ipc.ts';
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
