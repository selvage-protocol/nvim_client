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
  readonly selections: Array<{ path: string; selection: OffsetSelection }> = [];
  disconnected = false;

  private readonly listeners = new Set<EngineEventListener>();
  private readonly info: SessionInfo;

  constructor(role: Role = 'host', documents: string[] = []) {
    const peer: PeerInfo = {
      peer_id: 'p-local',
      display_name: 'neovim',
      role,
    };
    this.info = {
      roomId: 'r-test',
      role,
      peer,
      peers: [],
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

  /** Moves the replica the way a peer's edit would, and tells the bridge. */
  remote(path: string, text: string): void {
    this.texts.set(path, text);
    this.emit({ type: 'documentChanged', path });
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
    return [];
  }

  resolveSelection(_path: string, _selection: Selection): OffsetSelection | undefined {
    return undefined;
  }

  on(listener: EngineEventListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
}
