/**
 * What the front-end draws and says about the room, worked out by the editor host: the seats and
 * their colours, the session's identity, the host's absence counted down, and the fixed words.
 */

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';

import { NvimEditorHost } from '../companion/editor.ts';
import type { Clock } from '../companion/editor.ts';
import type { Notification } from '../companion/ipc.ts';
import { hostLeaveQuestion, words } from '../companion/room.ts';
import { HOST_LEAVE_QUESTION, SEAT_PALETTE, peerColour } from '../vendor/bridge/index.ts';
import type { Cursor } from '../vendor/bridge/index.ts';
import type { PeerInfo } from '../vendor/engine/index.ts';

interface Seat extends PeerInfo {
  roster: string;
  initials: string;
  colour: string;
}

interface RoomReport {
  kind: 'peers';
  peers: Seat[];
  self?: Seat;
  identity: string;
}

/** A clock a test moves by hand: `every` hands its tick to the test rather than to a timer. */
class HandClock implements Clock {
  time = 0;
  ticks: Array<() => void> = [];
  now = (): number => this.time;
  every = (_ms: number, tick: () => void): (() => void) => {
    this.ticks.push(tick);
    return () => {
      this.ticks = this.ticks.filter((one) => one !== tick);
    };
  };
  advance(ms: number): void {
    this.time += ms;
    for (const tick of [...this.ticks]) {
      tick();
    }
  }
}

function editor(self: PeerInfo, folder?: string): {
  host: NvimEditorHost;
  sent: Notification[];
  clock: HandClock;
  reports: () => Array<Record<string, unknown>>;
} {
  const sent: Notification[] = [];
  const clock = new HandClock();
  const host = new NvimEditorHost({ send: (notification) => sent.push(notification), clock });
  host.seated(() => self, folder);
  return {
    host,
    sent,
    clock,
    reports: () =>
      sent.flatMap((notification) =>
        notification.type === 'report' ? [notification.report as Record<string, unknown>] : [],
      ),
  };
}

function lastRoom(reports: Array<Record<string, unknown>>): RoomReport {
  const room = reports.filter((report) => report.kind === 'peers').at(-1);
  assert.ok(room !== undefined, 'no peers report was sent');
  return room as unknown as RoomReport;
}

const guest = (id: string, name: string): PeerInfo => ({ peer_id: id, display_name: name, role: 'guest' });

test('the host wears mauve, then your own seat, then the room in its order', () => {
  const it = editor(guest('p-me', 'Me'));
  it.host.report({
    kind: 'peers',
    peers: [guest('p-ann', 'Ann'), { peer_id: 'p-host', display_name: 'Hana', role: 'host' }, guest('p-bob', 'Bob')],
  });
  const room = lastRoom(it.reports());
  const colour = new Map([room.self, ...room.peers].map((seat) => [seat?.peer_id, seat?.colour]));
  assert.equal(colour.get('p-host'), '#cba6f7');
  assert.equal(colour.get('p-me'), SEAT_PALETTE[1]);
  assert.equal(colour.get('p-ann'), SEAT_PALETTE[2]);
  assert.equal(colour.get('p-bob'), SEAT_PALETTE[3]);
});

test('a seat past the thirteenth keeps the colour the peer id gives it', () => {
  const it = editor({ peer_id: 'p-host', display_name: 'Hana', role: 'host' });
  const others = Array.from({ length: 13 }, (_, index) => guest(`p-${index}`, `G${index}`));
  it.host.report({ kind: 'peers', peers: others });
  const room = lastRoom(it.reports());
  assert.equal(room.self?.colour, '#cba6f7');
  assert.equal(room.peers[11]?.colour, SEAT_PALETTE[12]);
  assert.equal(room.peers[12]?.colour, peerColour('p-12'));
});

test('two people with one name are told apart, and each seat carries its initials', () => {
  const it = editor(guest('p-me-0001', 'Ada Lovelace'));
  it.host.report({ kind: 'peers', peers: [guest('p-other-0002', 'Ada Lovelace'), guest('p-cy', '')] });
  const room = lastRoom(it.reports());
  assert.equal(room.self?.roster, 'Ada Lovelace · 0001');
  assert.equal(room.peers[0]?.roster, 'Ada Lovelace · 0002');
  assert.equal(room.self?.initials, 'Ad');
  assert.equal(room.peers[1]?.roster, 'p-cy', 'a peer with no name is known by its id');
});

test("the session is named after the host's folder, or the host", () => {
  const hosting = editor({ peer_id: 'p-host', display_name: 'Hana', role: 'host' }, '/home/hana/notes');
  hosting.host.report({ kind: 'peers', peers: [] });
  assert.equal(lastRoom(hosting.reports()).identity, 'Sharing “notes”');

  const joined = editor(guest('p-me', 'Me'));
  joined.host.report({ kind: 'peers', peers: [] });
  assert.equal(lastRoom(joined.reports()).identity, 'In a shared session');
  joined.host.report({ kind: 'peers', peers: [{ peer_id: 'p-host', display_name: 'Hana', role: 'host' }] });
  assert.equal(lastRoom(joined.reports()).identity, 'In Hana’s session');
  joined.host.report({ kind: 'peers', peers: [] });
  assert.equal(lastRoom(joined.reports()).identity, 'In Hana’s session', 'the host is still named once away');
});

test("a caret is drawn in its seat's colour", () => {
  const it = editor({ peer_id: 'p-host', display_name: 'Hana', role: 'host' });
  it.host.report({ kind: 'peers', peers: [guest('p-ann', 'Ann')] });
  const cursor: Cursor = {
    peerId: 'p-ann',
    label: 'Ann',
    role: 'guest',
    path: 'a.txt',
    anchor: 0,
    head: 0,
    colour: '#000000',
    fill: '#00000040',
  };
  it.host.renderCursors([cursor]);
  const presence = it.sent.findLast((notification) => notification.type === 'presence');
  assert.equal(presence?.type === 'presence' && presence.cursors[0]?.colour, SEAT_PALETTE[1]);
  assert.equal(presence?.type === 'presence' && presence.cursors[0]?.fill, '#94e2d540');
});

test("the host's absence is said once and counted down until the host is back", () => {
  const it = editor(guest('p-me', 'Me'));
  it.host.report({ kind: 'peers', peers: [{ peer_id: 'p-host', display_name: 'Hana', role: 'host' }] });
  it.host.report({ kind: 'hostDetached', graceMs: 30_000 });
  const detached = it.reports().at(-1);
  assert.equal(detached?.sentence, 'Hana left the session. The room disconnects in 30 seconds.');
  assert.equal(detached?.line, 'Hana left the session · Disconnecting in 30s');

  it.clock.advance(1000);
  it.clock.advance(1000);
  assert.deepEqual(it.reports().at(-1), { kind: 'hostAway', line: 'Hana left the session · Disconnecting in 28s' });

  it.host.report({ kind: 'hostAttached', peer: { peer_id: 'p-host', display_name: 'Hana', role: 'host' } });
  assert.equal(it.reports().at(-1)?.sentence, 'Hana is back. The session continues.');
  const count = it.sent.length;
  it.clock.advance(1000);
  assert.equal(it.sent.length, count, 'the countdown stops when the host is back');
});

test('the countdown stops when the room names its host again', () => {
  const it = editor(guest('p-me', 'Me'));
  it.host.report({ kind: 'hostDetached', graceMs: 30_000 });
  it.host.report({ kind: 'peers', peers: [{ peer_id: 'p-host', display_name: 'Hana', role: 'host' }] });
  const count = it.sent.length;
  it.clock.advance(1000);
  assert.equal(it.sent.length, count);
});

test('the countdown stops when the room is gone, and says why in a sentence', () => {
  const it = editor(guest('p-me', 'Me'));
  it.host.report({ kind: 'hostDetached', graceMs: 30_000 });
  it.host.report({ kind: 'roomGone', reason: 'the host has been away past its window' });
  assert.equal(it.reports().at(-1)?.sentence, 'The host was away too long, so the session ended.');
  const count = it.sent.length;
  it.clock.advance(1000);
  assert.equal(it.sent.length, count);
});

test('a rename is shown in the roster until the room has it too', () => {
  const self = guest('p-me', 'Me');
  const it = editor(self);
  it.host.report({ kind: 'peers', peers: [guest('p-ann', 'Ann')] });
  it.host.renamed('Grace');
  assert.equal(lastRoom(it.reports()).self?.roster, 'Grace');
  assert.equal(lastRoom(it.reports()).peers[0]?.roster, 'Ann');
});

test("the host's leave question leaves out the clause about keystrokes", () => {
  assert.notEqual(hostLeaveQuestion(), HOST_LEAVE_QUESTION, 'the clause this drops is still the one the web asks');
  assert.equal(hostLeaveQuestion(), 'Leaving ends the room for everyone and stops the invite link.');
});

test('the words carry each follow ending with a place for the name', () => {
  const said = words() as { followEnded: Record<string, string> };
  assert.deepEqual(said.followEnded, {
    typing: 'Stopped following %s because you started typing.',
    moving: 'Stopped following %s because you moved.',
    leaving: '%s left the room, so following stopped.',
    fileGone: 'Stopped following %s because the file is gone.',
  });
});

test('the companion says its words first', async () => {
  const child = spawn(process.execPath, [join(resolve(import.meta.dirname, '..'), 'companion', 'main.ts')], {
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  try {
    child.stdout.setEncoding('utf8');
    const first = await new Promise<string>((done, fail) => {
      let read = '';
      const deadline = setTimeout(() => fail(new Error('no line within 5 seconds')), 5000);
      child.stdout.on('data', (chunk: string) => {
        read += chunk;
        const newline = read.indexOf('\n');
        if (newline !== -1) {
          clearTimeout(deadline);
          done(read.slice(0, newline));
        }
      });
    });
    assert.deepEqual(JSON.parse(first), { type: 'words', words: words() });
  } finally {
    child.kill('SIGKILL');
  }
});

test("the Lua tests' words are the ones the companion sends", () => {
  const fixture = JSON.parse(readFileSync(join(resolve(import.meta.dirname), 'lua', 'words.json'), 'utf8')) as unknown;
  assert.deepEqual(fixture, words(), 'test/lua/words.json is out of date: write words() to it again');
});
