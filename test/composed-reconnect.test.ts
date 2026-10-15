/**
 * The reconnect repair the published engine brought: an UNKNOWN role's local edit, the clean
 * history a viewer resolution adopts, a promotion that keeps the speculation instead, and the
 * reciprocal request that carries back what a closing socket lost.
 *
 * Two layers, and both are real code. The first drives two `RelaySession`s — `vendor/engine/relay.ts`
 * and `peer.ts` as published — over {@link InProcessRoom}, which is where a *history* is
 * observable (`stateVector()`, the seam this adoption added). The second drives the nvim
 * companion and the vendored bridge, which is where the *adapter* is observable: the buffers a
 * front-end holds, the reports it is sent, and the words a person would see.
 *
 * Every wait here is a bounded poll of a real predicate (`waitFor`), and the frame a test loses
 * is lost by the room's own `lose`, not by sleeping.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { RelaySession } from '../vendor/engine/relay.ts';

import { Composed, FAST_KEEPALIVE, lastStatus, reportsOf } from './helpers/composed-client.ts';
import { InProcessRoom } from './helpers/in-process-room.ts';

const PATH = 'notes.txt';

/** `/meta` is not part of what these rooms are: nothing here reconnects through a grace. */
const noMeta: typeof fetch = () => Promise.reject(new Error('no /meta in this room'));

/** A bounded poll of a real predicate, so a test waits on the effect and not on a turn count. */
async function waitFor(
  what: string,
  predicate: () => boolean,
  timeoutMs = 5_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (predicate()) {
      return;
    }
    if (Date.now() >= deadline) {
      assert.fail(`waited ${timeoutMs}ms for ${what}`);
    }
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 2);
    });
  }
}

interface Pair {
  host: RelaySession;
  guest: RelaySession;
}

/**
 * A host and a guest on one room, both real sessions.
 *
 * `holdState` pauses the host's own seat before the guest joins, so the host never hears
 * `peer.joined` and publishes no state: what is left is exactly the UNKNOWN role a client is in
 * between its seat and the state that commits its key (§13.1's steps 4 and 6).
 */
async function pair(
  room: InProcessRoom,
  options: { guest?: 'guest' | 'viewer'; holdState?: boolean } = {},
): Promise<Pair> {
  const host = await RelaySession.host({
    baseUrl: 'ws://composed.test',
    displayName: 'Ada',
    listing: () => [PATH],
    keepalive: FAST_KEEPALIVE,
    webSocketFactory: room.factory,
    fetchImpl: noMeta,
  });
  if (options.holdState === true) {
    room.pause(host.sessionInfo().seat);
  }
  const invite = host.invite();
  assert.ok(invite !== undefined, 'the host has a link to hand on');
  const guest = await RelaySession.join({
    invite,
    displayName: 'Bob',
    ...(options.guest === undefined ? {} : { declaredRole: options.guest }),
    keepalive: FAST_KEEPALIVE,
    reconnect: { initialDelayMs: 15, maxDelayMs: 40 },
    webSocketFactory: room.factory,
    fetchImpl: noMeta,
  });
  return { host, guest };
}

/** Whether two replicas hold the same history, and not merely the same text. */
function converged(left: RelaySession, right: RelaySession, path: string): boolean {
  return (
    left.text(path) === right.text(path) &&
    Buffer.from(left.stateVector()).equals(Buffer.from(right.stateVector()))
  );
}

test('a viewer resolution adopts the clean history, and a local edit leaves no struct behind', async (t) => {
  const room = new InProcessRoom();
  t.after(() => room.stop());
  const { host, guest } = await pair(room, { guest: 'viewer', holdState: true });

  // The edit is made while no state commits this key: applied to the local replica, held back
  // from the room, and kept out of the publication history.
  guest.open(PATH);
  assert.equal(await guest.insert(PATH, 0, 'spec'), false, 'nothing is published while UNKNOWN');
  assert.equal(guest.text(PATH), 'spec', 'the local replica holds the uncommitted edit');
  assert.equal(host.text(PATH), '', 'and the room has heard nothing of it');

  // The host sees the seat and seals the state that commits this connection as the `viewer` it
  // announced. The state is what resolves the role, and the clean history is what it adopts.
  room.flush(host.sessionInfo().seat);
  await waitFor('the viewer role applied', () => guest.appliedRole() === 'viewer');

  assert.equal(guest.text(PATH), '', 'the speculative edit is not in the adopted history');
  assert.equal(host.text(PATH), '', 'and it never reached the room');
  assert.ok(
    converged(host, guest, PATH),
    'the viewer history is the room\'s, with no struct of its own left in it',
  );

  // A known viewer is refused before any history is made: the buffer keeps the room's text.
  assert.equal(await guest.insert(PATH, 0, 'more'), false);
  assert.equal(guest.text(PATH), '', 'a viewer\'s edit makes no history to export later');
  assert.ok(converged(host, guest, PATH), 'and the histories still agree');
});

test('a promotion keeps the held edit and publishes it once, and editing continues', async (t) => {
  const room = new InProcessRoom();
  t.after(() => room.stop());
  const { host, guest } = await pair(room, { holdState: true });

  guest.open(PATH);
  assert.equal(await guest.insert(PATH, 0, 'spec'), false);
  assert.equal(host.text(PATH), '');

  room.flush(host.sessionInfo().seat);
  await waitFor('the guest role applied', () => guest.appliedRole() === 'guest');
  await waitFor('the held edit published', () => host.text(PATH) === 'spec');

  assert.equal(guest.text(PATH), 'spec');
  assert.ok(converged(host, guest, PATH), 'the held edit is one history on both sides');

  assert.equal(await guest.insert(PATH, 4, ' more'), true);
  await waitFor('the next edit to land', () => host.text(PATH) === 'spec more');
  assert.ok(converged(host, guest, PATH));
});

test('a dropped writer keeps its history, and the reciprocal request repairs what was lost', async (t) => {
  const room = new InProcessRoom();
  t.after(() => room.stop());
  const { host, guest } = await pair(room);

  host.open(PATH);
  guest.open(PATH);
  await waitFor('the guest to be committed as a writer', () => guest.appliedRole() === 'guest');
  assert.equal(await host.insert(PATH, 0, 'abc'), true);
  await waitFor('the room\'s text to reach the guest', () => guest.text(PATH) === 'abc');

  // Everything this connection sends before its socket goes is lost with it — the closing
  // socket's own frames, whatever they carried. The replica keeps the edit; the room never
  // hears it, and nothing refuses it either: a lost update is silence, not a fault (§13.6).
  const lostSeat = guest.sessionInfo().seat;
  room.lose(lostSeat, 8);
  assert.equal(await guest.insert(PATH, 0, 'off '), true, 'it is published; the wire loses it');
  assert.equal(guest.text(PATH), 'off abc');
  assert.equal(host.text(PATH), 'abc', 'the update that carried `off ` never arrived');

  // The socket goes, and what this connection edits while it is away is its own history: it is
  // held back rather than published under a key the room has stopped committing (§9.1). The
  // edit depends on the struct the room never received, so the room cannot show it yet.
  room.drop(lostSeat);
  assert.equal(await guest.insert(PATH, 0, 'offline '), false, 'nothing goes out while detached');
  assert.equal(guest.text(PATH), 'offline off abc');

  await waitFor(
    'the guest to be seated again under a fresh key',
    () => guest.sessionInfo().seat !== lostSeat,
  );
  // The reciprocal request is what carries the lost history back: the host asks for what *it*
  // lacks once a committed writer's own request reaches it (§13.1's step 6 made reciprocal), and
  // this client's own held edits go out when the state commits its fresh key.
  await waitFor('the lost update and the offline edit to reach the room', () =>
    host.text(PATH) === 'offline off abc',
  );
  assert.ok(converged(host, guest, PATH), 'both sides hold one history, not two texts');

  // Editing continues on the repaired history.
  assert.equal(await guest.insert(PATH, 0, 'later: '), true);
  await waitFor('the later edit to land', () => host.text(PATH) === 'later: offline off abc');
  assert.ok(converged(host, guest, PATH));
});

test('the adapter is told what a resolution replaced, and a re-seat still reports the room', async (t) => {
  const composed = new Composed();
  t.after(async () => {
    await composed.stop();
  });
  const host = await composed.host({ listing: [PATH] });
  const invite = host.engine().inviteUrl();
  assert.ok(invite !== undefined, 'the host has a link to hand on');
  // The host is held before the guest joins, so the guest stands in the UNKNOWN role.
  composed.room.pause(host.seat());
  const viewer = await composed.join(invite, { declaredRole: 'viewer' });

  await viewer.openBuffer(PATH, '');
  await viewer.type(PATH, { start: 0, end: 0, text: 'spec' });
  await composed.waitFor('the speculative text in the buffer', () => viewer.buffer(PATH) === 'spec');
  assert.equal(host.text(PATH), '', 'the room has heard nothing of it');

  composed.room.flush(host.seat());
  await composed.waitFor('the viewer role applied', () => viewer.role() === 'viewer');
  await composed.waitFor('the adapter told its buffer is the room\'s', () => viewer.buffer(PATH) === '');

  assert.equal(viewer.text(PATH), '');
  assert.equal(host.text(PATH), '', 'the speculation never reached the room');
  assert.ok(
    viewer.events.some((event) => event.type === 'documentChanged' && event.path === PATH),
    'the bridge reported the path whose text the clean history replaced',
  );

  // The local key's role is the applied state's word, said once. The seat's own read is the
  // other fact, and it stays where the seat put it (`guest` for a key no state has committed).
  assert.deepEqual(viewer.roleReports(), ['viewer'], 'one report, when the state resolved the role');
  assert.equal(lastStatus(viewer)?.role, 'guest', 'the seat\'s read is not the state\'s word');

  // A room that moves without changing this connection's role says nothing more about it.
  const reports = viewer.roleReports().length;
  await viewer.engine().rename('Bob the second');
  await composed.waitFor('the room to name the new name', () =>
    host.engine().peers().some((peer) => peer.display_name === 'Bob the second'),
  );
  assert.equal(
    viewer.roleReports().length,
    reports,
    'a peers change is not a role change, and it is the state that gives a role',
  );

  // A re-seat is a fresh key and a new seat: the adapter is still told the room's documents, so a
  // surface bound to the room re-binds instead of trusting a set that happens to be the same.
  const named = viewer.documentsReport();
  const reported = reportsOf(viewer.sent, 'documents').length;
  const seat = viewer.seat();
  composed.room.drop(seat);
  await composed.waitFor(
    'the viewer seated again',
    () => viewer.seat() !== '' && viewer.seat() !== seat,
  );
  // The set can be exactly what it was before the blip, and it is reported all the same: an
  // adapter reading a document set as its all-clear is not left waiting for a change that is
  // not coming. A report is what this asserts, not a difference.
  await composed.waitFor('the room\'s documents reported again', () => {
    return (
      reportsOf(viewer.sent, 'documents').length > reported &&
      JSON.stringify(viewer.documentsReport()) === JSON.stringify(named)
    );
  });
});

test('a guest keeps its deferred open and its offline edits, and leaving unsubscribes it', async (t) => {
  const composed = new Composed();
  t.after(async () => {
    await composed.stop();
  });
  const host = await composed.host({ listing: [PATH] });
  const invite = host.engine().inviteUrl();
  assert.ok(invite !== undefined);
  const guest = await composed.join(invite);
  await composed.waitFor('the guest to be committed as a writer', () => guest.role() === 'guest');

  // A guest opens a buffer holding text of its own before the room has sent anything for the
  // path: nothing of that buffer reaches the room until the room's text is here.
  await guest.openBuffer(PATH, 'a guest copy\n');
  await composed.pump();
  assert.equal(
    guest.sent.filter((note) => note.type === 'applyEdit').length,
    0,
    'the guest buffer was not reconciled against a replica with nothing in it',
  );
  assert.equal(host.text(PATH), '', 'and none of it was published');

  await host.openBuffer(PATH, '');
  await host.type(PATH, { start: 0, end: 0, text: 'room\n' });
  await composed.waitFor('the room\'s text to land in the guest\'s buffer', () =>
    guest.buffer(PATH) === 'room\n',
  );
  await composed.waitFor('the room to hold it once', () => host.text(PATH) === 'room\n');
  assert.equal(guest.text(PATH), 'room\n', 'the room\'s text is the history, not the guest\'s copy');

  // The socket goes; the edit is made while the connection is away and belongs to this client's
  // history, which the state that commits the fresh key publishes.
  composed.room.drop(guest.seat());
  await guest.type(PATH, { start: 0, end: 0, text: 'offline ' });
  assert.equal(guest.buffer(PATH), 'offline room\n');
  await composed.waitFor('the offline edit to reach the room', () =>
    host.buffer(PATH) === 'offline room\n',
  );

  // Leaving unsubscribes this process from the engine: the room moving after it reaches nothing.
  await guest.companion.leave();
  const quiet = guest.sent.length;
  await host.type(PATH, { start: 0, end: 0, text: 'after leaving, still ' });
  await composed.waitFor('the room to move for the host', () =>
    host.buffer(PATH) === 'after leaving, still offline room\n',
  );
  // The host's own edit is on the wire; a listener left attached to the ended session would have
  // carried it here. One renewal window is the bound on the absence, and what is asserted is that
  // nothing arrived at all.
  await new Promise<void>((resolve) => {
    setTimeout(resolve, FAST_KEEPALIVE.awareness_renew_ms ?? 40);
  });
  assert.equal(guest.sent.length, quiet, 'the ended session still reached this front-end');
});
