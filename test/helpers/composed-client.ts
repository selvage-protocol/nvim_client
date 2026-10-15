/**
 * The nvim companion, a real session and the real bridge, over {@link InProcessRoom}.
 *
 * The composition is the one a person runs: `companion/session.ts` drives
 * `vendor/bridge/peer-engine.ts`, which drives `vendor/engine/relay.ts` and
 * `vendor/engine/peer.ts`; `NvimEditorHost` is this adapter's own host, and the notifications it
 * sends are the ones the plugin would answer. Nothing here is a stub of the engine — the frames,
 * the seals, the room state and the role the state assigns are the real ones — and what a test
 * supplies is only the transport the room is behind and the front-end that answers it.
 *
 * `FrontEnd` is the plugin's half of the version protocol, as `lua/selvage/document.lua` applies
 * it: a count of the changes a buffer has taken, and the refusal of an `applyEdit` whose version
 * is not that buffer's own. `waitFor` polls a real predicate with a deadline and reports what it
 * observed, so a test waits on the effect rather than on a number of turns.
 */

import assert from 'node:assert/strict';
import { mkdirSync } from 'node:fs';
import { join as joinPath } from 'node:path';

import { NvimEditorHost } from '../../companion/editor.ts';
import type { GrantEnumeration } from '../../companion/grant.ts';
import type { Notification, Request } from '../../companion/ipc.ts';
import { Companion } from '../../companion/session.ts';
import type { EngineFactory } from '../../companion/session.ts';
import { PeerEngine } from '../../vendor/bridge/index.ts';
import type { EngineEvent, Keepalive, Role } from '../../vendor/engine/index.ts';

import { InProcessRoom } from './in-process-room.ts';

/** The engine's own clocks, in milliseconds: a renewal a test can wait a few of. */
export const FAST_KEEPALIVE: Partial<Keepalive> = {
  awareness_renew_ms: 40,
  awareness_expire_ms: 4_000,
};

/** The base a host mints on. Nothing dials it: the room's factory answers every address. */
export const COMPOSED_BASE = 'ws://composed.test';

/** A keystroke, as the plugin's `change` states one. */
export interface TextChange {
  start: number;
  end: number;
  text: string;
}

export interface ComposedSide {
  readonly what: 'host' | 'guest';
  readonly companion: Companion;
  /** The adapter's own host: its buffer text is what the front-end holds. */
  readonly editor: NvimEditorHost;
  /** Every notification the companion sent, in order. */
  readonly sent: Notification[];
  /** Every event the bridge raised, in order. */
  readonly events: EngineEvent[];
  /** The live session. Throws before one is open. */
  engine(): PeerEngine;
  /** The role the applied state gave this connection's key (`§13.4`). */
  role(): Role | undefined;
  /** The replica's text for a path. */
  text(path: string): string;
  /** What the front-end's buffer holds for a path, `undefined` when it holds none. */
  buffer(path: string): string | undefined;
  /** The seat the room gave this connection, which a re-seat changes (`§9.1`). */
  seat(): string;
  /** `report {kind: 'role'}` payloads, in order: what this front-end was told, and when. */
  roleReports(): string[];
  /** The room's open-document set as the last `documents` report named it. */
  documentsReport(): string[] | undefined;
  /** Puts a buffer in front of the session, as the plugin's `open` does. */
  openBuffer(path: string, text: string): Promise<void>;
  /** A keystroke in a buffer, as the plugin's `change` does. */
  type(path: string, change: TextChange): Promise<void>;
  /** Answers what the companion has asked of this front-end. */
  pump(): Promise<void>;
}

/** What the front-end's documents hold and how many changes each has taken. */
class FrontEnd {
  private readonly sent: Notification[];
  private readonly companion: Companion;
  private readonly versions = new Map<string, number>();
  private delivered = 0;
  /** The applies this front-end refused, by path. Empty is the ordinary case. */
  readonly refused: string[] = [];

  constructor(sent: Notification[], companion: Companion) {
    this.sent = sent;
    this.companion = companion;
  }

  /** A buffer is in front of the user and its count starts here. */
  opened(path: string): void {
    this.versions.set(path, 0);
  }

  /** A local keystroke: the plugin's own count moves when the user types. */
  typed(path: string): void {
    this.versions.set(path, (this.versions.get(path) ?? 0) + 1);
  }

  /** Answers every request the companion owes an answer for, and everything that follows. */
  async pump(): Promise<void> {
    for (let round = 0; round < 1_024; round += 1) {
      const note = this.sent[this.delivered];
      if (note === undefined) {
        return;
      }
      this.delivered += 1;
      const answer = this.answer(note);
      if (answer !== undefined) {
        await this.companion.handle(answer);
      }
    }
    assert.fail('the companion and this front-end never stopped answering each other');
  }

  private answer(note: Notification): Request | undefined {
    if (note.type === 'applyEdit') {
      const version = this.versions.get(note.path) ?? 0;
      if (note.version !== version) {
        this.refused.push(note.path);
        return { type: 'applied', id: note.id, ok: false };
      }
      this.versions.set(note.path, version + 1);
      return { type: 'applied', id: note.id, ok: true };
    }
    if (note.type === 'save') {
      return { type: 'saved', id: note.id, ok: true };
    }
    return undefined;
  }
}

export interface HostOptions {
  displayName?: string;
  /** The working tree the room is handed, as the host's own reading of it would be. */
  listing?: string[];
  /** The folder this session shares. Defaults to a scratch directory of the suite's own. */
  root?: string;
  autoSave?: boolean;
}

export interface JoinOptions {
  displayName?: string;
  /** What this connection announces, which is what the host commits its key as (`§13.4`). */
  declaredRole?: 'guest' | 'viewer';
  autoSave?: boolean;
}

export class Composed {
  readonly room = new InProcessRoom();
  private readonly sides: ComposedSide[] = [];
  private readonly fronts = new Map<ComposedSide, FrontEnd>();
  private readonly folder: string;

  constructor() {
    // `AGENTS.md` §5: scratch stays inside the checkout. Nothing here needs the folder to hold
    // anything — the listing is the test's own — but the host's watcher is handed a real one.
    this.folder = joinPath(process.cwd(), '.tmp', 'composed-room');
    mkdirSync(this.folder, { recursive: true });
  }

  /** A host, seated on the in-process room with this suite's listing. */
  async host(options: HostOptions = {}): Promise<ComposedSide> {
    const listing = [...(options.listing ?? [])];
    const side = this.side('host', undefined, listing);
    await side.companion.handle({
      type: 'host',
      serverUrl: COMPOSED_BASE,
      displayName: options.displayName ?? 'Ada',
      root: options.root ?? this.folder,
      autoSave: options.autoSave ?? false,
    });
    return side;
  }

  /** A guest, joining the room an invite names. */
  async join(invite: string, options: JoinOptions = {}): Promise<ComposedSide> {
    const side = this.side('guest', options.declaredRole, []);
    await side.companion.handle({
      type: 'join',
      invite,
      displayName: options.displayName ?? 'Bob',
      autoSave: options.autoSave ?? false,
    });
    return side;
  }

  /** Answers every side's front-end, so a frame a test delivered is taken in. */
  async pump(): Promise<void> {
    for (const side of this.sides) {
      const front = this.fronts.get(side);
      assert.ok(front !== undefined);
      await front.pump();
    }
  }

  /**
   * Polls a predicate with a deadline, pumping both ends each turn.
   *
   * The deadline reports what it saw rather than the predicate's own name alone, because a
   * regression that changes *what* arrives is the one this is looking for.
   */
  async waitFor(
    what: string,
    predicate: () => boolean,
    timeoutMs = 5_000,
  ): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      await this.pump();
      if (predicate()) {
        return;
      }
      if (Date.now() >= deadline) {
        assert.fail(`waited ${timeoutMs}ms for ${what}; saw ${this.describe()}`);
      }
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 2);
      });
    }
  }

  /** Ends every session and the room under them. */
  async stop(): Promise<void> {
    this.room.stop();
    for (const side of this.sides) {
      await side.companion.leave();
    }
  }

  /** What the sides hold, for a deadline's own report. */
  private describe(): string {
    return this.sides
      .map(
        (side) =>
          `${side.what} seat=${side.seat()} role=${String(side.role())} ` +
            `events=${side.events.length} buffers=${JSON.stringify(
              side.sent
                .filter(
                  (note): note is Extract<Notification, { type: 'applyEdit' }> =>
                    note.type === 'applyEdit',
                )
                .map((note) => note.path),
            )}`,
      )
      .join('; ');
  }

  private side(
    what: 'host' | 'guest',
    declaredRole: 'guest' | 'viewer' | undefined,
    listing: string[],
  ): ComposedSide {
    const room = this.room;
    const sent: Notification[] = [];
    const events: EngineEvent[] = [];
    const editor = new NvimEditorHost({ send: (notification) => sent.push(notification) });
    let open: PeerEngine | undefined;
    const keep = (engine: PeerEngine): PeerEngine => {
      open = engine;
      engine.on((event) => events.push(event));
      return engine;
    };
    const engines: EngineFactory = {
      host: async (serverUrl, displayName, source) =>
        keep(
          await PeerEngine.host({
            baseUrl: serverUrl,
            displayName,
            listing: source,
            webSocketFactory: room.factory,
            keepalive: FAST_KEEPALIVE,
            client: 'selvage-nvim',
          }),
        ),
      join: async (invite, displayName) =>
        keep(
          await PeerEngine.join({
            invite,
            displayName,
            ...(declaredRole === undefined ? {} : { declaredRole }),
            webSocketFactory: room.factory,
            keepalive: FAST_KEEPALIVE,
            // §9.1's bounded retry, at a delay a test can wait out rather than the production one.
            reconnect: { initialDelayMs: 15, maxDelayMs: 40 },
            client: 'selvage-nvim',
          }),
        ),
    };
    const companion = new Companion({
      send: (notification) => sent.push(notification),
      editor,
      engines,
      enumerate: async (): Promise<GrantEnumeration> => ({ paths: listing, cut: undefined }),
      autoSave: false,
      displayName: what === 'host' ? 'Ada' : 'Bob',
    });
    const front = new FrontEnd(sent, companion);
    const side: ComposedSide = {
      what,
      companion,
      editor,
      sent,
      events,
      engine(): PeerEngine {
        assert.ok(open !== undefined, `${what} has no open session`);
        return open;
      },
      role(): Role | undefined {
        return open?.appliedRole();
      },
      text(path: string): string {
        return open?.text(path) ?? '';
      },
      buffer(path: string): string | undefined {
        return editor.text(path);
      },
      seat(): string {
        return open?.session().peer.peer_id ?? '';
      },
      roleReports(): string[] {
        return reportsOf(sent, 'role').map((report) => String(report['role']));
      },
      documentsReport(): string[] | undefined {
        const last = reportsOf(sent, 'documents').at(-1);
        const documents = last?.['documents'];
        return Array.isArray(documents) ? documents.map((path) => String(path)) : undefined;
      },
      async openBuffer(path: string, text: string): Promise<void> {
        front.opened(path);
        await companion.handle({ type: 'open', path, text });
      },
      async type(path: string, change: TextChange): Promise<void> {
        front.typed(path);
        await companion.handle({ type: 'change', path, ...change });
      },
      async pump(): Promise<void> {
        await front.pump();
      },
    };
    this.sides.push(side);
    this.fronts.set(side, front);
    return side;
  }
}

/** The `report` notifications of one kind, as the records they carry. */
export function reportsOf(
  sent: readonly Notification[],
  kind: string,
): Array<Record<string, unknown>> {
  const found: Array<Record<string, unknown>> = [];
  for (const notification of sent) {
    if (notification.type !== 'report') {
      continue;
    }
    const report = notification.report;
    if (typeof report !== 'object' || report === null) {
      continue;
    }
    const record = report as Record<string, unknown>;
    if (record['kind'] === kind) {
      found.push(record);
    }
  }
  return found;
}

/** The last status this companion sent, or `undefined` before it said one. */
export function lastStatus(
  side: ComposedSide,
): Extract<Notification, { type: 'status' }> | undefined {
  const statuses = side.sent.filter(
    (notification): notification is Extract<Notification, { type: 'status' }> =>
      notification.type === 'status',
  );
  return statuses.at(-1);
}
