/**
 * A mid-session rename through the real session and the vendored engine, over the in-process
 * room: the reply's `id` is what settles `session.rename` (`§4.2`), not the send. What a refused
 * name must not do is relabel this connection's roster — the room's own word is the name in
 * force — and what a refused one must do is reach the front-end as a `sessionError` it can react
 * to, the way a refused `open` is reported.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { Composed, reportsOf } from './helpers/composed-client.ts';
import type { ComposedSide } from './helpers/composed-client.ts';

/** The `sessionError` reports a side sent, each with its code and sentence. */
function errorsOf(side: ComposedSide): Array<{ code: string; message: string }> {
  return reportsOf(side.sent, 'sessionError').map((report) => ({
    code: String(report['code']),
    message: String(report['message']),
  }));
}

/** What the front-end was last told this connection's roster names. */
function lastRoster(side: ComposedSide): string | undefined {
  return reportsOf(side.sent, 'peers')
    .map((report) => (report['self'] as { roster: string } | undefined)?.roster)
    .at(-1);
}

test('a rename the room refuses is reported and never relabels the roster', async (t) => {
  const composed = new Composed();
  t.after(() => composed.stop());
  const host = await composed.host();
  const invite = host.engine().inviteUrl();
  assert.ok(invite !== undefined, 'the host has a link to hand on');
  const guest = await composed.join(invite);
  await composed.pump();

  const refused = errorsOf(host).length;
  const roster = lastRoster(host);

  await host.companion.handle({ type: 'rename', displayName: 'Ada\u0007bel' });
  await composed.pump();

  const errors = errorsOf(host);
  assert.ok(errors.length > refused, 'the refusal never reached the front-end');
  assert.deepEqual(
    errors.at(-1),
    {
      code: 'bad_params',
      message:
        'the server refused the display name "Ada\u0007bel": display_name contains control characters',
    },
    'the refusal is said with the code and sense the server gave it',
  );
  assert.equal(
    lastRoster(host),
    roster,
    'a refused name leaves the roster as the room last drew it',
  );

  // The room never took the name either, and so the other side heard nothing of it.
  await composed.waitFor(
    'the room to hold the old name',
    () => guest.engine().peers().some((peer) => peer.display_name === 'Ada'),
  );
  assert.ok(
    guest.engine().peers().every((peer) => peer.display_name === 'Ada'),
    'a seat still holds a name the room never took',
  );
});

test('a rename the room accepts relabels the roster on the room\'s word', async (t) => {
  const composed = new Composed();
  t.after(() => composed.stop());
  const host = await composed.host();
  const invite = host.engine().inviteUrl();
  assert.ok(invite !== undefined, 'the host has a link to hand on');
  const guest = await composed.join(invite);
  await composed.pump();

  await host.companion.handle({ type: 'rename', displayName: 'Ada the Second' });
  await composed.waitFor(
    'the room to carry the new name',
    () => guest.engine().peers().at(-1)?.display_name === 'Ada the Second',
  );
  await composed.pump();
  assert.equal(errorsOf(host).length, 0, 'an accepted rename is not an error');
  assert.ok(
    lastRoster(host)?.startsWith('Ada the Second') ?? false,
    'the roster confirms the name the room took',
  );
});
