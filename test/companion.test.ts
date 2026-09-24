/**
 * The companion against a replica with no server behind it: what a front-end's message does
 * to the room, what the room asks a front-end to do, and the one race the local IPC has of
 * its own — a remote edit and a local one crossing in the pipe.
 *
 * Every `host` here pins `selvage/1`, which is the deliberate way to the readable wire and the
 * room these tests were written as. An unpinned host takes its version from what the server's
 * `/meta` seats, and reaching a real server is not something this file does — the section below
 * on the version decision is where that rule is driven, with the answer supplied.
 */

import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

import { LineReader, MAX_IPC_LINE_BYTES, isRequest } from '../companion/ipc.ts';
import type { Notification, Request } from '../companion/ipc.ts';
import { NvimEditorHost } from '../companion/editor.ts';
import { enumerateGrant } from '../companion/grant.ts';
import { Companion, WIRE_VERSION_REFUSED, realWire2 } from '../companion/session.ts';
import type { MetaReader } from '../companion/session.ts';
import { ProtocolError, parseInvite } from '../vendor/engine/index.ts';
import type { PeerInfo } from '../vendor/engine/index.ts';

import { MAX_GRANT_FILE_BYTES } from '../vendor/bridge/index.ts';
import type { GrantedRead } from '../vendor/bridge/index.ts';
import { INVITE_REFUSED, wireVersionOf } from '../companion/relay.ts';

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

  override readGrantedFile(path: string): Promise<GrantedRead> {
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
  /** The same, on the encrypted wire: which of the two factories a host went through is what
   * the version decision amounts to. */
  hosts2: string[];
  /** Every invite a `join` was asked for, in the same order. */
  joins: string[];
  /** The same, on the encrypted wire. A join's version is the link's to say, so which factory
   * an invite reached is the routing decision itself, and one shared array could not tell them
   * apart. */
  joins2: string[];
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
    /**
     * What the server's `/meta` answers. The default is a body that could not be read: this
     * process is the one that dials it, and a process in a test should not reach the network — a
     * test about what this companion does with an answer supplies the answer.
     */
    meta?: MetaReader;
    /**
     * When set, every `selvage/2` mint this harness is asked for throws it, the way a dead
     * address or a server that refuses the version-2 hello reaches the session. No engine is
     * built for a mint that did not happen.
     */
    wire2MintFails?: Error;
    /**
     * Whether the replica echoes a published listing back the way a real server's `doc.granted`
     * does. Off by default: a test that is not about the grant report should not be handed one.
     */
    echoGrants?: boolean;
  } = {},
): Harness {
  const sent: Notification[] = [];
  const send = (notification: Notification): void => {
    sent.push(notification);
  };
  const hosts: string[] = [];
  const hosts2: string[] = [];
  const joins: string[] = [];
  const joins2: string[] = [];
  const engines: FakeEngine[] = [];
  const open = (): FakeEngine => {
    const engine = new FakeEngine(role, documents, peers);
    engine.granted = [...(options.granted ?? [])];
    engine.grantError = options.grantError;
    engine.echoGrants = options.echoGrants ?? false;
    engines.push(engine);
    return engine;
  };
  const editor = new RecordingHost({ send });
  const companion = new Companion({
    send,
    editor,
    autoSave: options.defaultAutoSave ?? false,
    enumerate: options.enumerate,
    meta: options.meta ?? (() => Promise.resolve(undefined)),
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
    // The version-2 half of the same seam. It records which factory was reached rather than the
    // arguments alone, because that is the whole of what a host's version decision amounts to.
    wire2: {
      host: (serverUrl) => {
        hosts2.push(serverUrl);
        if (options.wire2MintFails !== undefined) {
          return Promise.reject(options.wire2MintFails);
        }
        return Promise.resolve(open());
      },
      join: (invite) => {
        joins2.push(invite);
        return Promise.resolve(open());
      },
    },
  });
  return {
    companion,
    editor,
    sent,
    hosts,
    hosts2,
    joins,
    joins2,
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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

// -- which version a host mints ---------------------------------------------------------
//
// `PROTOCOL.md` §2: a client that can speak `selvage/2` mints it where the server seats it, and
// where `/meta` answered without it the client refuses before it dials anything — falling back to
// `selvage/1` would mint a room whose contents the server reads, which is the room the version
// exists to make impossible. A `/meta` that could not be read is no answer at all: the handshake
// is where that one is refused, and loudly. A pin is the deliberate way to the readable wire, and
// one the server does not seat is refused rather than fallen back from. A join is none of this —
// it speaks the version its invite names (§5.1).

/** A `/meta` body as a server writes it, as the reader this companion is handed. */
function metaOffers(...versions: string[]): MetaReader {
  return () => Promise.resolve({ wire_versions: versions });
}

/** A `/meta` that could not be read: unreachable, not JSON, or no fetch at all. */
const noMeta: MetaReader = () => Promise.resolve(undefined);

/** The statuses this companion sent, in the order it sent them. */
function statuses(it: Harness): Array<Extract<Notification, { type: 'status' }>> {
  return it.sent.filter(
    (notification): notification is Extract<Notification, { type: 'status' }> =>
      notification.type === 'status',
  );
}

function refusalStatus(it: Harness): Extract<Notification, { type: 'status' }> {
  const heard = statuses(it);
  assert.deepEqual(
    heard.map((entry) => entry.state),
    ['error'],
    'a refused host never said it was connecting, because it never dialled',
  );
  const refusal = heard[0];
  assert.notEqual(refusal, undefined, 'no status at all');
  return refusal as Extract<Notification, { type: 'status' }>;
}

test('an unpinned host mints the version the server seats', async () => {
  const it = harness('host', [], [], { meta: metaOffers('selvage/1', 'selvage/2') });
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });

  assert.deepEqual(it.hosts, [], 'a server seating both does not move a host off the encrypted wire');
  assert.deepEqual(it.hosts2, ['ws://127.0.0.1:0'], 'it mints the encrypted one');
  assert.deepEqual(
    statuses(it).map((entry) => entry.state),
    ['connecting', 'hosting'],
  );
});

// Two versions end a dropped connection differently (`§9.1`): a `selvage/1` host reclaims its
// room and a `selvage/2` host cannot, because the host return is a fresh room state signed by the
// host key and this client writes no host store. The front-end is the one that says it, so the
// seat has to carry which version it is.
test('the seat tells the front-end which wire version it speaks', async () => {
  const sealed = harness('host', [], [], { meta: metaOffers('selvage/1', 'selvage/2') });
  await sealed.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });
  assert.equal(statuses(sealed).at(-1)?.wire, 'selvage/2');

  const readable = harness('host');
  await readable.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  assert.equal(statuses(readable).at(-1)?.wire, 'selvage/1');

  const guest = harness('guest');
  await guest.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  assert.equal(statuses(guest).at(-1)?.wire, 'selvage/1', 'a link with no fragment is the readable wire');
});

test('a server that does not seat selvage/2 is refused before anything is dialled', async () => {
  const it = harness('host', [], [], { meta: metaOffers('selvage/1') });
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });

  assert.deepEqual(it.hosts, [], 'no room was minted');
  assert.deepEqual(it.hosts2, [], 'and none on the encrypted wire either');
  const refusal = refusalStatus(it);
  assert.equal(refusal.code, WIRE_VERSION_REFUSED);
  assert.equal(
    refusal.message,
    'ws://127.0.0.1:0 does not seat selvage/2, the encrypted wire — its /meta offers selvage/1 — so a room hosted there would be one the server can read.',
  );
});

test('a /meta that could not be read is no answer, so the host attempts selvage/2', async () => {
  const it = harness('host', [], [], { meta: noMeta });
  await it.companion.handle({ type: 'host', serverUrl: 'ws://127.0.0.1:0' });

  // The endpoint is advisory: a server that seats no `selvage/2` refuses the hello with
  // `unsupported_version`, which is loud, and refusing to try would be a client inventing an
  // answer out of an unreachable endpoint.
  assert.deepEqual(it.hosts, []);
  assert.deepEqual(it.hosts2, ['ws://127.0.0.1:0']);
});

test('a pin decides the version, and a server seating both does not move it', async () => {
  const it = harness('host', [], [], { meta: metaOffers('selvage/1', 'selvage/2') });
  await it.companion.handle({
    type: 'host',
    wire: 'selvage/1',
    serverUrl: 'ws://127.0.0.1:0',
  });

  assert.deepEqual(it.hosts, ['ws://127.0.0.1:0'], 'the deliberate way to a room the server can read');
  assert.deepEqual(it.hosts2, []);
});

test('a pin the server does not seat is refused rather than fallen back from', async () => {
  // Both directions, because the guard is one membership test either way and a test that seeded
  // only one of them would not know which half of it ran.
  const wants2 = harness('host', [], [], { meta: metaOffers('selvage/1') });
  await wants2.companion.handle({
    type: 'host',
    wire: 'selvage/2',
    serverUrl: 'ws://127.0.0.1:0',
  });
  assert.deepEqual(wants2.hosts, [], 'the readable wire is not a fall back from a pin');
  assert.deepEqual(wants2.hosts2, []);
  const refused2 = refusalStatus(wants2);
  assert.equal(refused2.code, WIRE_VERSION_REFUSED);
  assert.equal(
    refused2.message,
    'the wire version is pinned to selvage/2, and ws://127.0.0.1:0 does not seat it — its /meta offers selvage/1 — so hosting there is refused rather than fallen back from.',
  );

  const wants1 = harness('host', [], [], { meta: metaOffers('selvage/2') });
  await wants1.companion.handle({
    type: 'host',
    wire: 'selvage/1',
    serverUrl: 'ws://127.0.0.1:0',
  });
  assert.deepEqual(wants1.hosts, []);
  assert.deepEqual(wants1.hosts2, []);
  const refused1 = refusalStatus(wants1);
  assert.equal(refused1.code, WIRE_VERSION_REFUSED);
  assert.equal(
    refused1.message,
    'the wire version is pinned to selvage/1, and ws://127.0.0.1:0 does not seat it — its /meta offers selvage/2 — so hosting there is refused rather than fallen back from.',
  );
});

test('a link the client will not read is refused with the engine\'s own sentence', async () => {
  // The real version-2 factories: a link whose fragment does not read is refused before anything is
  // dialled, so this test opens no socket and needs no server — which is the property being
  // pinned. The failure carries no code of the protocol's, and a front-end handed it as a
  // connection that failed would replace the engine's sentence with one about a server.
  const sent: Notification[] = [];
  const companion = new Companion({
    send: (notification) => sent.push(notification),
    wire2: realWire2,
  });

  for (const invite of [
    // Both names, a value that is not a key: the link asks for `selvage/2` and cannot be joined.
    'ws://127.0.0.1:1/session?room=r&token=t#k=short&h=short',
    // The same fragment on the page form a host hands on, which the engine resolves first.
    'https://127.0.0.1:1/?room=r&token=t#k=short&h=short',
  ]) {
    sent.length = 0;
    await companion.handle({ type: 'join', invite });
    const heard = sent.filter(
      (notification): notification is Extract<Notification, { type: 'status' }> =>
        notification.type === 'status',
    );
    assert.deepEqual(
      heard.map((status) => status.state),
      ['connecting', 'error'],
      `the refusal is a failed join rather than nothing at all: ${invite}`,
    );
    assert.equal(heard[1]?.code, INVITE_REFUSED, `the refusal carries a code: ${invite}`);
    assert.equal(
      heard[1]?.message,
      "`k` is not a 32-byte key in the fragment's encoding",
      `and the engine's own sentence for it: ${invite}`,
    );
  }
});

test('a join consults neither the setting nor the server: the link is the version', async () => {
  // A reader that fails the test rather than answering one: a join has nothing to ask, so a join
  // that asked would be the defect.
  const unread: MetaReader = () => {
    throw new Error('a join read /meta');
  };
  const sealed =
    'ws://127.0.0.1:0/session?room=r&token=t#k=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&h=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  const bySealedLink = harness('guest', [], [], { meta: unread });
  await bySealedLink.companion.handle({ type: 'join', invite: sealed });
  assert.deepEqual(bySealedLink.joins, [], 'a sealed link never reaches the readable factory');
  assert.deepEqual(bySealedLink.joins2, [sealed], 'it joins on the encrypted wire');

  const plain = 'ws://127.0.0.1:0/session?room=r&token=t';
  const byPlainLink = harness('guest', [], [], { meta: unread });
  await byPlainLink.companion.handle({ type: 'join', invite: plain });
  assert.deepEqual(byPlainLink.joins, [plain], 'and a link with no fragment on the readable one');
  assert.deepEqual(byPlainLink.joins2, [], 'never on the encrypted one');
});

test('a fragment is read with §5.1\'s decoding, as the engine reads it', async () => {
  // A name written `%6b` is `k`: the engine's fragment reader percent-decodes a name before it
  // looks for one, so a chooser reading the raw spelling would send the link to the readable wire
  // and the room it names would not be there. The two readers are asked the same question here,
  // and a link with only one of the two names is still a version-1 link, as it always was.
  // A key is 32 bytes in `§5.1`'s base64url, and 43 `A`s is one: 43 `a`s is not, because the final
  // character's padding bits are not zero, so the value would be refused for the wrong reason.
  const key = 'A'.repeat(43);
  const encoded = `ws://127.0.0.1:1/session?room=r&token=t#%6b=${key}&h=${key}`;
  assert.equal(
    parseInvite(encoded).ok,
    true,
    'the engine reads a percent-encoded room key, which is what the chooser has to agree with',
  );
  assert.equal(wireVersionOf(encoded), 'selvage/2');
  assert.equal(wireVersionOf(`ws://h/session?room=r&token=t#k=${key}&h=${key}`), 'selvage/2');
  assert.equal(wireVersionOf(`ws://h/session?room=r&token=t#k=${key}`), 'selvage/1');
  assert.equal(wireVersionOf('ws://h/session?room=r&token=t'), 'selvage/1');
  assert.equal(wireVersionOf('ws://h/session?room=r&token=t#%zz=x&h=y'), 'selvage/1');

  const it = harness('guest');
  await it.companion.handle({ type: 'join', invite: encoded });
  assert.deepEqual(it.joins2, [encoded], 'the link reached the encrypted wire');
  assert.deepEqual(it.joins, [], 'and never the readable one');
});

test('a role the state gives this connection after the seat reaches the front-end', async () => {
  // `§13.4`: the role is the applied state's word about this connection's key, and the state that
  // commits the key is published after the connection announced it — so the status sent at the seat
  // reads the `?? 'guest'` default and a viewer that stopped there would keep an editable buffer,
  // which for `§13.9` is worse than a refusal. The role is read where it can change instead.
  const it = harness('guest', ['notes.txt']);
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  const seat = statuses(it).at(-1);
  assert.equal(seat?.state, 'joined');
  assert.equal(seat?.role, 'guest', 'the seat is before any state has committed this key');
  assert.deepEqual(roleReports(it), [], 'so no role has been reported yet');

  // The room's state arrives and seats this connection as a viewer.
  it.engine.setRole('viewer');
  it.engine.emit({ type: 'peersChanged', peers: [] });
  assert.deepEqual(roleReports(it), ['viewer'], 'the change reached the front-end');

  // The room's content arriving is an event of its own, and the role is read at each one: a state
  // that relabelled this connection with no peer of its own to relabel raises no other event.
  it.engine.emit({ type: 'documentChanged', path: 'notes.txt' });
  assert.deepEqual(roleReports(it), ['viewer'], 'and nothing was said twice');

  // What the state gives, it can take away.
  it.engine.setRole('guest');
  it.engine.emit({ type: 'peersChanged', peers: [] });
  assert.deepEqual(roleReports(it), ['viewer', 'guest']);
});

test('a second host is refused rather than minting a second room', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  const before = it.sent.length;

  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:elsewhere' });

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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  const before = it.sent.length;

  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  assert.deepEqual(it.joins, []);
  assert.deepEqual(it.joins2, []);
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });

  it.engine.remote('notes.txt', 'hello, world\n');

  await until("the room's change to be written", () => {
    return it.sent.some((notification) => notification.type === 'save');
  });
});

test('a remote change is not written when the front-end says not to', async () => {
  const it = harness('host', [], [], { defaultAutoSave: true });
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', autoSave: false });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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

test('a refused connect carries the code, a dead socket carries no code', async () => {
  // The front-end says a refusal by its code rather than by the server's message, which names
  // the room it could not find: the code is the same fact without the value. A socket that
  // never reached a handshake has no code at all, which is how a front-end tells the two
  // apart.
  const sent: Notification[] = [];
  const companion = new Companion({
    send: (notification) => sent.push(notification),
    editor: new NvimEditorHost({ send: () => undefined }),
    autoSave: false,
    engines: {
      host: () => Promise.reject(new ProtocolError('room_unknown', 'no such room: r-4f2a91')),
      join: () => Promise.reject(new Error('the WebSocket reported an error')),
    },
  });

  await companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  await companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  assert.deepEqual(
    sent.filter((notification) => notification.type === 'status'),
    [
      { type: 'status', state: 'connecting' },
      {
        type: 'status',
        state: 'error',
        message: 'no such room: r-4f2a91',
        code: 'room_unknown',
      },
      { type: 'status', state: 'connecting' },
      {
        type: 'status',
        state: 'error',
        message: 'the WebSocket reported an error',
      },
    ],
    'a refusal the protocol named carries its code; nothing named a dead socket',
  );
  await companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  assert.equal(
    sent.some((notification) => notification.type === 'refused'),
    false,
    'a connect that failed leaves no session behind for the next one to be refused by',
  );
});

test('a connection the engine gave up on leaves the next session free', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });

  it.engine.emit({ type: 'disconnected' });

  await until('the session to be given up', () =>
    it.sent.some((notification) => notification.type === 'status' && notification.state === 'idle'),
  );
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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

test('a listing naming paths no host would publish says which, and is otherwise the room\'s', async () => {
  // §6.3 has a receiver replace its grant with the room's `paths` whole, so the listing is not
  // trimmed; §12 leaves every path on the wire unvalidated, so the ones the grant's own rules would
  // never let a host publish are named beside it, for the mirror not to put on disk. A `.git/`
  // materialised in a guest's mirror is a repository every git-aware plugin runs `git` in.
  const listing = ['.git/config', '.git/HEAD', 'a/../b', 'src/main.rs'];
  const it = harness('guest', [], [], { granted: listing });
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });

  const grant = (report: unknown): report is { kind: 'grant' } =>
    (report as { kind: string }).kind === 'grant';
  const reports = it.sent
    .filter((notification) => notification.type === 'report')
    .map((notification) => notification.report)
    .filter(grant);
  assert.deepEqual(reports, [
    { kind: 'grant', paths: listing, unsafe: ['.git/config', '.git/HEAD', 'a/../b'] },
  ]);

  // The bridge's own report of a later listing is annotated the same way.
  it.engine.granted = ['.envrc', 'notes.txt'];
  it.engine.emit({ type: 'grantChanged', paths: ['.envrc', 'notes.txt'] });
  await settle();
  const later = it.sent
    .filter((notification) => notification.type === 'report')
    .map((notification) => notification.report)
    .filter(grant);
  assert.deepEqual(later.at(-1), {
    kind: 'grant',
    paths: ['.envrc', 'notes.txt'],
    unsafe: ['.envrc'],
  });
});

test('a guest join waits for the listing the handshake carried', async () => {
  const it = harness('guest');
  const joining = it.companion.handle({
    type: 'join',
    invite: 'ws://127.0.0.1:0/session?room=r&token=t',
  });
  // The room's listing may land a turn after `join()` resolves: the server queues `doc.granted`
  // after `room.joined`, and the engine reads the two frames separately. The join waits for the
  // frame rather than reporting an empty listing the front-end would then never mention, and the
  // bridge's own report of it is what the front-end hears — the snapshot stands down.
  await new Promise((resolve) => setImmediate(resolve));
  it.engine.granted = ['src/main.rs', 'notes.txt'];
  it.engine.emit({ type: 'grantChanged', paths: ['src/main.rs', 'notes.txt'] });
  await joining;

  const reports = it.sent.filter((notification) => notification.type === 'report');
  assert.deepEqual(
    reports.map((notification) => (notification.report as { kind: string }).kind),
    ['grant', 'documents', 'peers'],
  );
  assert.deepEqual(reports[0]?.report, { kind: 'grant', paths: ['src/main.rs', 'notes.txt'] });
});

test('a host seeds the buffer it opens, and only once', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  await it.companion.handle({ type: 'open', path: 'notes.txt', text: 'hello\n' });
  await it.companion.handle({ type: 'selection', path: 'notes.txt', anchor: 1, head: 3 });
  assert.deepEqual(it.engine.selections, [
    { path: 'notes.txt', selection: { anchor: 1, head: 3 } },
  ]);
});

test('a document opened after a peer moved draws the peer', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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

test('a line that arrives over many chunks is read whole, once', () => {
  // A whole-document `open` is one line and arrives in pipe-sized pieces: each piece is searched
  // for its newline once, and the pieces are joined once, when the newline comes — a reader that
  // re-searched the whole line on every piece cost the square of the line's length.
  const lines: string[] = [];
  const reader = new LineReader((line) => lines.push(line));
  const piece = `${'a'.repeat(64 * 1024 - 1)}€`;
  for (let index = 0; index < 64; index += 1) {
    reader.push(piece);
  }
  assert.deepEqual(lines, [], 'nothing is handed on before the newline');
  reader.push('\n{"type":"leave"}\n{"type":"selectionCleared"}\n{"type":"clo');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], piece.repeat(64), 'the long line arrived whole and in order');
  assert.deepEqual(lines.slice(1), ['{"type":"leave"}', '{"type":"selectionCleared"}']);
  reader.push('se","path":"a"}\n');
  assert.equal(lines.at(-1), '{"type":"close","path":"a"}', 'and the tail carried over');
});

test('a line past the bound over many chunks is shed once, and the next line still arrives', () => {
  const lines: string[] = [];
  const drops: number[] = [];
  const reader = new LineReader(
    (line) => lines.push(line),
    (bytes) => drops.push(bytes),
  );
  const piece = 'x'.repeat(1024 * 1024);
  const pieces = Math.ceil(MAX_IPC_LINE_BYTES / piece.length) + 3;
  for (let index = 0; index < pieces; index += 1) {
    reader.push(piece);
  }
  reader.push('tail\n{"type":"leave"}\n');
  assert.equal(drops.length, 1, 'the runaway line was said once');
  assert.ok((drops[0] as number) > MAX_IPC_LINE_BYTES, 'in bytes past the bound');
  assert.deepEqual(lines, ['{"type":"leave"}'], 'its tail was shed with it, and the next line arrived');
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

/** The `grant` listings the front-end was handed, in the order the companion reported them. */
function grantReports(it: Harness): string[][] {
  return it.sent
    .filter(
      (notification): notification is Extract<Notification, { type: 'report' }> =>
        notification.type === 'report' &&
        (notification.report as { kind: string }).kind === 'grant',
    )
    .map((notification) => (notification.report as { paths: string[] }).paths);
}

/** The roles the companion reported as this connection's own, in the order it reported them. */
function roleReports(it: Harness): string[] {
  return it.sent
    .filter(
      (notification): notification is Extract<Notification, { type: 'report' }> =>
        notification.type === 'report' &&
        (notification.report as { kind: string }).kind === 'role',
    )
    .map((notification) => (notification.report as { role: string }).role);
}

// The read is real file system work, which lands on a later turn of the event loop than a drain
// of the microtask queue ever reaches: `until` is the wait for it, and `settle` is only enough
// for work that is already resolved.

test('a path the room asks for is read off the folder and put into the replica', async (t) => {
  const root = folder(t);
  tree(root, 'never-opened.txt', 'the host never opened this\n');
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });

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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });

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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root: walled });

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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root: shared });
  it.engine.emit({ type: 'documentsChanged', documents: ['escape/secret.txt'] });
  await until(
    'the refusal to be reported',
    () => refusals(it).length > 0,
    () => refusals(it),
  );

  assert.equal(it.engine.text('escape/secret.txt'), '', 'nothing was shared for it');
  assert.deepEqual(refusals(it), [
    'could not share escape/secret.txt: it is not a plain file in the folder this session shares (a directory, a link, or something else that cannot be read as one); nothing was shared for it',
  ]);
});

test('a binary file the room asks for is refused as binary, not as deleted', async (t) => {
  const root = folder(t);
  // A zip, as it is on disk: a local file header, which has a NUL in its first bytes. The
  // listing names it — the walk rules on a file's type and the size a session carries, and
  // does not read it — so the refusal is where a person learns why it cannot be shared, and
  // it has to be about what the file is rather than about a deletion nobody made.
  writeFileSync(
    join(root, 'logs_96234608913.zip'),
    new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00]),
  );

  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  it.engine.emit({ type: 'documentsChanged', documents: ['logs_96234608913.zip'] });
  await until(
    'the refusal to be reported',
    () => refusals(it).length > 0,
    () => refusals(it),
  );

  assert.equal(it.engine.text('logs_96234608913.zip'), '', 'nothing was shared for it');
  assert.deepEqual(refusals(it), [
    'could not share logs_96234608913.zip: it is a binary file, and a room carries text, so this is not a file that can be shared at all; nothing was shared for it',
  ]);
});

test('one bogus listing is one dialog, never one per path', async (t) => {
  const root = folder(t);
  const walled = join(root, 'walled');
  mkdirSync(walled, { recursive: true });

  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root: walled });

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
    'could not share gone-4.txt: there is no readable file there any more (it may have been deleted after the listing was published); nothing was shared for it',
  );
});

test('a locally opened file the grant excludes is refused once, not seeded', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the listing to reach the engine',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );

  assert.deepEqual(it.engine.grants, [['notes.txt', 'src/main.rs']]);
});

test('a host with no folder publishes nothing at all', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
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

  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
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
    wire: 'selvage/1',
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
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

test('saving a file the listing already names walks nothing', async (t) => {
  // While a guest types, the room's autosave writes the document about twice a second, and a
  // walk of the tree per write kept a large host walking for the whole session. A write that
  // leaves the file a listing names as one it still names cannot move the listing.
  const root = folder(t);
  tree(root, 'notes.txt', 'a note\n');
  let walks = 0;
  const it = harness('host', [], [], {
    enumerate: async (at) => {
      walks += 1;
      return enumerateGrant(at);
    },
  });
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until('the first listing', () => it.engine.grants.length > 0, () => it.engine.grants);
  const first = walks;

  for (let index = 0; index < 5; index += 1) {
    tree(root, 'notes.txt', `saved ${String(index)}\n`);
    await delay(20);
  }
  await delay(QUIET_MS);
  assert.equal(walks, first, 'a save of a listed file walked the folder');

  // A change under a directory no listing names is not a change to the listing either.
  mkdirSync(join(root, 'node_modules'));
  await delay(QUIET_MS);
  const settled = walks;
  tree(root, 'node_modules/dep/index.js', 'module.exports = 1;\n');
  await delay(QUIET_MS);
  assert.equal(walks, settled, 'a write under node_modules walked the folder');

  // A write that takes a listed file past the size a listing carries is one that moves it.
  tree(root, 'notes.txt', 'x'.repeat(MAX_GRANT_FILE_BYTES + 1));
  await until(
    'the grown file to leave the listing',
    () => it.engine.grants.at(-1)?.includes('notes.txt') === false,
    () => it.engine.grants,
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
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the next session to publish the folder',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );
  assert.notEqual(it.engine, first, 'a second session is a second room');
  assert.deepEqual(it.engine.grants, [['notes.txt']]);
});

test('a version-2 mint that failed leaves no listing behind for the next host', async (t) => {
  const root = folder(t);
  tree(root, 'one.txt', 'one\n');
  tree(root, 'two.txt', 'two\n');

  // The first attempt walks the folder and then dies at the mint — a dead address, or a server
  // that refuses the version-2 hello. It never opened a room, so the walk is not a listing
  // anything holds.
  const failed = harness('host', [], [], {
    wire2MintFails: new Error('the WebSocket reported an error'),
    echoGrants: true,
  });
  await failed.companion.handle({ type: 'host', wire: 'selvage/2', serverUrl: 'ws://127.0.0.1:1', root });
  assert.deepEqual(failed.hosts2, ['ws://127.0.0.1:1'], 'the version-2 attempt reached the mint');
  assert.deepEqual(
    statuses(failed).map((status) => status.state),
    ['connecting', 'error'],
    'a mint that threw is reported and leaves nothing standing',
  );

  // The recovery a person follows: pin version 1 and host the same folder again. The room is
  // minted, so it has to be told what it shares — and the listing the room echoes back is what
  // the guest sees.
  await failed.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the folder this host shares to reach the room',
    () => failed.engine.grants.length > 0,
    () => ({ listed: failed.engine.grants, reported: grantReports(failed) }),
  );
  assert.deepEqual(failed.engine.grants, [['one.txt', 'two.txt']], 'the room was told nothing');
  // The first report is the handshake's own, before the listing was published; the second is the
  // listing the room echoed back, which is what a guest's front-end is handed. A host that sent no
  // `doc.grant` leaves the guest looking at an empty room and the front-end with the first alone.
  assert.deepEqual(
    grantReports(failed),
    [[], ['one.txt', 'two.txt']],
    'and the front-end was handed no listing either',
  );

  // The control: the same single version-1 host with no failed attempt before it publishes the
  // same listing, so the assertions above are about the failed mint and not about the harness.
  const control = harness('host', [], [], { echoGrants: true });
  await control.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the control host to publish the folder',
    () => control.engine.grants.length > 0,
    () => control.engine.grants,
  );
  assert.deepEqual(control.engine.grants, [['one.txt', 'two.txt']]);
  assert.deepEqual(grantReports(control), [[], ['one.txt', 'two.txt']]);
});

test('a folder a session has left is not published by the next one', async (t) => {
  const shared = folder(t);
  tree(shared, 'a.txt');
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root: shared });
  await until('the first folder to be published', () => it.engine.grants.length > 0, () => it.engine.grants);

  await it.companion.handle({ type: 'leave' });

  const second = folder(t);
  tree(second, 'b.txt');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root: second });
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

  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
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

// -- a host that reseats after a drop ---------------------------------------------------
//
// A host that dropped reclaims its room rather than minting a new one, and the room kept the
// listing it had while this process was gone. A reconnect seats again under a new peer id in
// the same room, so the first seat report under that id is the reclaim rather than later room
// news — and the host publishes the folder as it stands then instead of leaving the dead
// listing advertised.

test('a host that reseats after a drop publishes its current listing', async (t) => {
  const root = folder(t);
  let listing = ['old.txt'];
  const it = harness('host', [], [], {
    enumerate: async () => [...listing],
  });
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the starting listing to be published',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [['old.txt']]);

  // The folder moves while the room still names the old listing — the shape a reclaim meets
  // when the working copy changed under a dead socket.
  listing = ['new.txt'];
  it.engine.reseat('p-again');
  it.engine.emit({ type: 'documentsChanged', documents: [] });

  await until(
    'the current listing to be published after the reseat',
    () => it.engine.grants.length > 1,
    () => it.engine.grants,
  );
  assert.deepEqual(it.engine.grants, [['old.txt'], ['new.txt']]);
});

test('later room news under the same peer id publishes nothing again', async (t) => {
  const root = folder(t);
  let listing = ['old.txt'];
  const it = harness('host', [], [], {
    enumerate: async () => [...listing],
  });
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until(
    'the starting listing to be published',
    () => it.engine.grants.length > 0,
    () => it.engine.grants,
  );

  listing = ['new.txt'];
  it.engine.reseat('p-again');
  it.engine.emit({ type: 'documentsChanged', documents: [] });
  await until(
    'the current listing to be published after the reseat',
    () => it.engine.grants.length > 1,
    () => it.engine.grants,
  );

  // An open elsewhere is room news under the same peer, not a second reclaim: the folder
  // has nothing new to say, and the room is not told twice.
  it.engine.emit({ type: 'documentsChanged', documents: ['new.txt'] });
  it.engine.emit({ type: 'peersChanged', peers: [] });
  await delay(QUIET_MS);
  assert.deepEqual(it.engine.grants, [['old.txt'], ['new.txt']]);
});

test('a guest that reseats after a drop publishes nothing and keeps its role', async () => {
  const it = harness('guest');
  await it.companion.handle({ type: 'join', invite: 'ws://127.0.0.1:0/session?room=r&token=t' });
  await settle();
  assert.equal(it.engine.session().role, 'guest');

  it.engine.reseat('p-again');
  it.engine.emit({ type: 'documentsChanged', documents: [] });
  it.engine.emit({ type: 'peersChanged', peers: [] });

  // A publish the re-seat owed would already be resolved work, so `settle` is enough to
  // have seen it; `QUIET_MS` is what says the watcher owed nothing either.
  await delay(QUIET_MS);
  assert.deepEqual(it.engine.grants, [], 'a reseated guest published a listing');
  assert.equal(it.engine.session().role, 'guest', 'a reconnect drifted toward host');
});

// -- what a drop says while the retry runs ------------------------------------------------
//
// `§9.1`'s bounded retry is `reconnecting`: its own event, so an adapter shows the drop instead
// of inferring it from silence. The bridge forwards it to the editor host and the front-end's row
// is where it is read — this is the seam a re-vendor can break — and the session it belongs to has
// to go on, because the re-seat carries the same engine, the same replica and the same seam.

test('a dropped connection is reported as a retry, and does not end the session', async () => {
  const it = harness('host');
  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0' });
  await settle();

  const before = it.sent.length;
  it.engine.emit({ type: 'reconnecting' });
  await settle();

  const heard = it.sent.slice(before);
  assert.deepEqual(
    heard.filter((notification) => notification.type === 'report'),
    [{ type: 'report', report: { kind: 'reconnecting' } }],
    'the retry did not reach the front-end as its own report',
  );
  assert.equal(
    heard.some((notification) => notification.type === 'status' && notification.state === 'idle'),
    false,
    'the session ended at the drop instead of waiting for the retry',
  );
  assert.equal(it.engine.disconnected, false, 'the companion let the engine go');
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

  await it.companion.handle({ type: 'host', wire: 'selvage/1', serverUrl: 'ws://127.0.0.1:0', root });
  await until('the refusal to be reported', () => refusals(it).length > 0, () => refusals(it));

  assert.match(
    refusals(it)[0] ?? '',
    /^could not watch the folder this session shares: /,
    'the report names the folder and the reason',
  );
  assert.equal(it.engine.disconnected, false, 'a folder that cannot be watched does not end the session');
});

/** How long a companion started for a test is given to leave on its own before it is killed. */
const COMPANION_EXIT_MS = 15_000;

/** Waits for a child to exit, killing it and failing when the deadline passes instead. */
async function exit_of(child: ChildProcess): Promise<number> {
  // The deadline is cleared when the child goes, so a test that passes leaves no timer holding
  // the runner open behind it.
  const expired = new AbortController();
  try {
    return await Promise.race([
      new Promise<number>((resolve_exit, reject) => {
        child.once('error', reject);
        child.once('exit', (code) => resolve_exit(code ?? -1));
      }),
      delay(COMPANION_EXIT_MS, undefined, { signal: expired.signal }).then(() => {
        child.kill('SIGKILL');
        throw new Error(`the companion did not exit within ${COMPANION_EXIT_MS} ms`);
      }),
    ]);
  } finally {
    expired.abort();
  }
}

test(
  'the trace file is written for its owner alone',
  { timeout: 30_000 },
  async () => {
    // What crosses the pipe includes a host's invite, which carries the room's token: a bearer
    // credential, so a file that holds it is not left for another account on the machine to read.
    // The umask is asked for a permissive one, because a strict umask would hide an unfixed
    // companion behind a 0600 file created by accident and this would pass for the wrong reason.
    const scratch = mkdtempSync(join(SCRATCH, 'trace-'));
    const file = join(scratch, 'companion.log');
    const umask = process.umask(0o022);
    const child = spawn(process.execPath, [join(resolve(import.meta.dirname, '..'), 'companion', 'main.ts')], {
      env: { ...process.env, SELVAGE_COMPANION_LOG: file },
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    try {
      child.stdin.end('{"type":"leave"}\n');
      assert.equal(await exit_of(child), 0, 'the companion left when its input ended');
      assert.equal((statSync(file).mode & 0o777).toString(8), '600', 'the trace is readable by others');
    } finally {
      process.umask(umask);
      child.kill('SIGKILL');
      rmSync(scratch, { recursive: true, force: true });
    }
  },
);


test(
  "the trace never holds an invite's fragment",
  { timeout: 30_000 },
  async () => {
    // `§5.1`: a `selvage/2` invite's fragment carries the room key and the host's public key, and a
    // client **MUST NOT** log it. The invite crosses this pipe twice — the front-end's `join` and
    // the host's own `status` — and both are written through the same redaction, keyed on the
    // member a link travels in, so a real link sent in is the whole of what this pins.
    const scratch = mkdtempSync(join(SCRATCH, 'trace-'));
    const file = join(scratch, 'companion.log');
    const roomKey = 'FgWuVJM2nsQn9DqDaRVQ4c2LmdmK3XWbczlKBUHu57A';
    const hostKey = 'dQAm9nhUso4fDxMD3qDBfVQ9kojiU03k4PonWTjEla4';
    const invite = `ws://127.0.0.1:1/session?room=r-trace&token=t#k=${roomKey}&h=${hostKey}`;
    const child = spawn(
      process.execPath,
      [join(resolve(import.meta.dirname, '..'), 'companion', 'main.ts')],
      {
        env: { ...process.env, SELVAGE_COMPANION_LOG: file },
        stdio: ['pipe', 'pipe', 'ignore'],
      },
    );
    try {
      // A document's own text crosses this pipe too, and one of its `#`es is not a link's: what the
      // trace records about a document has to be the text the room holds.
      const carried = 'a # b';
      child.stdin.end(
        `${JSON.stringify({ type: 'open', path: 'notes.md', text: carried })}\n` +
          `${JSON.stringify({ type: 'join', invite })}\n`,
      );
      assert.equal(await exit_of(child), 0, 'the companion left when its input ended');

      const written = readFileSync(file, 'utf8');
      assert.notEqual(written.includes(roomKey), true, 'the room key reached the trace');
      assert.notEqual(written.includes(hostKey), true, "the host's public key reached the trace");
      // The link itself is still there: what a trace is for is the order the messages crossed in,
      // and an invite's address and token are part of that record.
      assert.equal(
        written.includes(`"invite":"ws://127.0.0.1:1/session?room=r-trace&token=t#redacted"`),
        true,
        `the invite is not in the trace as a redacted link:\n${written}`,
      );
      assert.equal(
        written.includes(`"text":${JSON.stringify(carried)}`),
        true,
        `a document's own text was rewritten by the redaction:\n${written}`,
      );
    } finally {
      child.kill('SIGKILL');
      rmSync(scratch, { recursive: true, force: true });
    }
  },
);

// -- a warning about a refused line ----------------------------------------------------
//
// A line that is JSON but not a request is refused with a word, and what that word is for is
// naming which member or type was wrong — not recording what the line held. A `selvage/2`
// invite's fragment is the room's key (§5.1) and a client **MUST NOT** log it, so the warning
// prints the parsed value through the same member-keyed redaction the trace uses.
// `withoutFragment` reads only the first `#`, so a member before `invite` that carries one of
// its own left the fragment standing.

test(
  "a warning about a refused line never carries an invite's fragment",
  { timeout: 30_000 },
  async () => {
    const roomKey = 'FgWuVJM2nsQn9DqDaRVQ4c2LmdmK3XWbczlKBUHu57A';
    const hostKey = 'dQAm9nhUso4fDxMD3qDBfVQ9kojiU03k4PonWTjEla4';
    const invite = `ws://127.0.0.1:1/session?room=r-warn&token=t#k=${roomKey}&h=${hostKey}`;
    // `display_name` comes before `invite` and carries a `#` of its own, which is what
    // `withoutFragment` reads as the fragment's start: it returns the line unchanged, fragment
    // and all, and the invite is not a request.
    const line = JSON.stringify({ display_name: 'a#b', invite });
    const child = spawn(
      process.execPath,
      [join(resolve(import.meta.dirname, '..'), 'companion', 'main.ts')],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    let said = '';
    child.stderr?.setEncoding('utf8');
    child.stderr?.on('data', (chunk: string) => {
      said += chunk;
    });
    try {
      child.stdin?.write(`${line}\n`);
      await until(
        'the refusal to be said',
        () => said.includes('ignoring a message that is not a request: '),
        () => said,
      );

      assert.notEqual(said.includes(roomKey), true, `the room key reached the warning:\n${said}`);
      assert.notEqual(
        said.includes(hostKey),
        true,
        `the host's public key reached the warning:\n${said}`,
      );
      // The link is still there, as in the trace: the address is what names the message that was
      // wrong, and it is not the secret.
      assert.equal(
        said.includes(`"invite":"ws://127.0.0.1:1/session?room=r-warn&token=t#redacted"`),
        true,
        `the refused line was not reported with its address:\n${said}`,
      );

      child.stdin?.end();
      assert.equal(await exit_of(child), 0, 'the companion left when its input ended');
    } finally {
      child.kill('SIGKILL');
    }
  },
);
