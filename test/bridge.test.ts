/**
 * The vendored bridge against this adapter's own host: the real `NvimEditorHost` in front of it,
 * the fake replica behind it, and the front-end's `applied` answers coming back over the IPC.
 *
 * `vscode_client` tests this code against its own fake editor. What is left for here is the case
 * this adapter's host puts in front of it and that one does not — a guest document whose room
 * text has not arrived — which is the corruption the guest deferral in `vendor/bridge/` is for.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { NvimEditorHost } from '../companion/editor.ts';
import type { Notification } from '../companion/ipc.ts';
import { SessionBridge } from '../vendor/bridge/index.ts';

import { FakeEngine } from './helpers/fake-engine.ts';

/** Lets every already-resolved promise the bridge chained settle. */
async function settle(): Promise<void> {
  for (let turn = 0; turn < 8; turn += 1) {
    await Promise.resolve();
  }
}

/**
 * The front-end's half of the version protocol, as `lua/selvage/document.lua` applies it: a count
 * of the changes a document has taken, and the refusal of an `applyEdit` whose version is not that
 * document's own. Where a range lands is the Lua side's arithmetic; what the bridge settles against
 * is the answer, so only the counting is modelled.
 */
class FrontEnd {
  private readonly host: NvimEditorHost;
  private readonly sent: Notification[];
  private readonly versions = new Map<string, number>();
  private delivered = 0;

  constructor(host: NvimEditorHost, sent: Notification[]) {
    this.host = host;
    this.sent = sent;
  }

  /** A buffer is in front of the user, holding `text`, and its count starts here. */
  open(path: string, text: string): void {
    this.versions.set(path, 0);
    this.host.opened(path, text);
  }

  /** Answers every message this front-end has not answered, until neither side has more to say. */
  async drain(): Promise<void> {
    for (let turn = 0; turn < 32; turn += 1) {
      await settle();
      if (this.delivered === this.sent.length) {
        return;
      }
      while (this.delivered < this.sent.length) {
        this.receive(this.sent[this.delivered] as Notification);
        this.delivered += 1;
      }
    }
    assert.fail('the bridge and the front-end never settled');
  }

  private receive(notification: Notification): void {
    if (notification.type !== 'applyEdit') {
      return;
    }
    const version = this.versions.get(notification.path) ?? 0;
    if (notification.version !== version) {
      this.host.settleApply(notification.id, false);
      return;
    }
    this.versions.set(notification.path, version + 1);
    this.host.settleApply(notification.id, true);
  }
}

interface Harness {
  bridge: SessionBridge;
  engine: FakeEngine;
  host: NvimEditorHost;
  front: FrontEnd;
  /** The `applyEdit`s asked for so far. */
  readonly applies: Array<Extract<Notification, { type: 'applyEdit' }>>;
}

function harness(role: 'host' | 'guest'): Harness {
  const engine = new FakeEngine(role);
  const sent: Notification[] = [];
  const host = new NvimEditorHost({ send: (notification) => sent.push(notification) });
  const bridge = new SessionBridge({ engine, host, autoSave: false });
  return {
    bridge,
    engine,
    host,
    front: new FrontEnd(host, sent),
    get applies() {
      return sent.filter(
        (notification): notification is Extract<Notification, { type: 'applyEdit' }> =>
          notification.type === 'applyEdit',
      );
    },
  };
}

test("a guest's own buffer is held back until the room's text arrives", async () => {
  const it = harness('guest');

  // A guest opens a buffer holding text of its own — a document kept across a session, a tab the
  // user had open — while this replica has received nothing for the path. The handshake names the
  // room's documents; the sync carrying their text is a later message.
  it.front.open('notes.txt', 'a guest disk copy\n');
  it.bridge.documentOpened('notes.txt');
  await it.front.drain();

  // Nothing of that buffer goes in front of the bridge until the text is here. A buffer reconciled
  // against an empty replica is asked to hold the empty document, which a Neovim buffer cannot —
  // its text always ends in a newline, so the buffer would keep one the room does not have — and
  // whatever it still holds when that lands is the buffer's own content rather than the user's
  // edit. The hold is what makes the room send the text.
  assert.deepEqual(it.applies, [], 'the guest buffer was reconciled against an empty replica');
  assert.deepEqual(it.engine.opened, ['notes.txt'], 'the path is held in the room');
  assert.equal(it.engine.text('notes.txt'), '', 'the guest published its own buffer');

  // The room's text arrives, the buffer adopts it, and the room holds it once.
  it.engine.remote('notes.txt', 'from the room\n');
  await it.front.drain();
  assert.equal(it.host.text('notes.txt'), 'from the room\n');
  assert.equal(
    it.engine.text('notes.txt'),
    'from the room\n',
    'the room ended up holding the text twice',
  );
});
