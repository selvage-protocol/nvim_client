/**
 * A replica with no server behind it: enough of `Engine` for the bridge to run against, and
 * a way for a test to move the replica the way a peer would.
 */

import type { PeerInfo, Role } from '../../vendor/engine/envelope.ts';
import type { EngineEvent, EngineEventListener } from '../../vendor/engine/events.ts';
import type { SessionInfo } from '../../vendor/engine/engine.ts';
import type {
  AwarenessState,
  OffsetSelection,
  Presence,
  Selection,
} from '../../vendor/engine/presence.ts';
import type { CompanionEngine } from '../../companion/session.ts';

export class FakeEngine implements CompanionEngine {
  readonly texts = new Map<string, string>();
  readonly opened: string[] = [];
  readonly closed: string[] = [];
  readonly renamed: string[] = [];
  /** When set, the next `rename` rejects with it — the way a refused name reaches a caller. */
  renameError: Error | undefined;
  readonly selections: Array<{ path: string; selection: OffsetSelection }> = [];
  /** What `presence()` reports, and how `resolveSelection` answers: a test sets both to make
   * the bridge resolve a real cursor. */
  presences: Presence[] = [];
  readonly resolved = new Map<string, OffsetSelection>();
  disconnected = false;

  private readonly listeners = new Set<EngineEventListener>();
  private readonly info: SessionInfo;

  constructor(role: Role = 'host', documents: string[] = [], peers: PeerInfo[] = []) {
    const peer: PeerInfo = {
      peer_id: 'p-local',
      display_name: 'neovim',
      role,
    };
    this.info = {
      roomId: 'r-test',
      role,
      peer,
      peers: [...peers],
      documents,
      capabilities: [],
      keepalive: {
        ping_interval_ms: 30_000,
        awareness_renew_ms: 15_000,
        awareness_expire_ms: 30_000,
      },
      baseUrl: 'ws://127.0.0.1:0',
      ...(role === 'host' ? { token: 't-test' } : {}),
    };
  }

  /** Moves the replica the way a peer's edit would, and tells the bridge.
   *
   * Only a document this replica holds is reported: the engine attaches its observer to a
   * document when this client holds it — content can arrive for a path before then, and the
   * hold is what turns its presence into an event — so a document nobody has opened has nobody
   * to tell. An edit that brings a text in still reports it for a held document: that is a
   * document arriving, which is the one thing a client that opened before the room sent
   * anything has to hear.
   */
  remote(path: string, text: string): void {
    this.texts.set(path, text);
    if (this.opened.includes(path)) {
      this.emit({ type: 'documentChanged', path });
    }
  }

  emit(event: EngineEvent): void {
    for (const listener of [...this.listeners]) {
      listener(event);
    }
  }

  session(): SessionInfo {
    return this.info;
  }

  inviteUrl(): string | undefined {
    return this.info.role === 'host'
      ? `ws://127.0.0.1:0/session?room=${this.info.roomId}&token=t-test`
      : undefined;
  }

  disconnect(): Promise<void> {
    this.disconnected = true;
    return Promise.resolve();
  }

  text(path: string): string {
    return this.texts.get(path) ?? '';
  }

  has(path: string): boolean {
    return this.texts.has(path);
  }

  open(path: string): Promise<void> {
    this.opened.push(path);
    return Promise.resolve();
  }

  close(path: string): Promise<void> {
    this.closed.push(path);
    return Promise.resolve();
  }

  rename(displayName: string): Promise<void> {
    this.renamed.push(displayName);
    const error = this.renameError;
    this.renameError = undefined;
    return error === undefined ? Promise.resolve() : Promise.reject(error);
  }

  insert(path: string, index: number, text: string): void {
    const current = this.texts.get(path) ?? '';
    this.texts.set(path, current.slice(0, index) + text + current.slice(index));
  }

  delete(path: string, index: number, length: number): void {
    const current = this.texts.get(path) ?? '';
    this.texts.set(path, current.slice(0, index) + current.slice(index + length));
  }

  setSelection(path: string, selection: OffsetSelection): void {
    this.selections.push({ path, selection });
  }

  setAwareness(_state: AwarenessState | null): void {}

  presence(): Presence[] {
    return this.presences;
  }

  resolveSelection(path: string, _selection: Selection): OffsetSelection | undefined {
    return this.resolved.get(path);
  }

  on(listener: EngineEventListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
}
