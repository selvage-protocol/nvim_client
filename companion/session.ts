/**
 * The companion's session: one engine, one bridge, one editor host, driven by the messages
 * the front-end sends.
 *
 * Nothing here decides anything about a document — `vendor/bridge/` does that. What is here
 * is the lifecycle the front-end's commands name (host, join, leave) and the routing of one
 * message to one method.
 */

import { SessionBridge } from '../vendor/bridge/index.ts';
import type { Engine } from '../vendor/bridge/index.ts';
import { SelvageEngine } from '../vendor/engine/index.ts';

import { NvimEditorHost } from './editor.ts';
import type { Notification, Request } from './ipc.ts';

/** The engine, plus the two members the lifecycle needs and the bridge does not. */
export interface CompanionEngine extends Engine {
  inviteUrl(): string | undefined;
  disconnect(): Promise<void>;
}

/** How a session is opened. A test supplies its own; the default opens a real one. */
export interface EngineFactory {
  host(serverUrl: string, displayName: string): Promise<CompanionEngine>;
  join(invite: string, displayName: string): Promise<CompanionEngine>;
}

export const realEngines: EngineFactory = {
  host: (serverUrl, displayName) => SelvageEngine.host(serverUrl, displayName),
  join: (invite, displayName) => SelvageEngine.join(invite, displayName),
};

export interface CompanionOptions {
  send: (notification: Notification) => void;
  engines?: EngineFactory;
  displayName?: string;
  /** Passed to the bridge; a test turns it off to keep the save policy out of the way. */
  autoSave?: boolean;
}

export class Companion {
  private readonly send: (notification: Notification) => void;
  private readonly engines: EngineFactory;
  private readonly editor: NvimEditorHost;
  private readonly defaultName: string;
  private readonly autoSave: boolean;
  private engine?: CompanionEngine;
  private bridge?: SessionBridge;

  constructor(options: CompanionOptions) {
    this.send = options.send;
    this.engines = options.engines ?? realEngines;
    this.defaultName = options.displayName ?? 'neovim';
    this.autoSave = options.autoSave ?? true;
    this.editor = new NvimEditorHost({ send: this.send });
  }

  /**
   * Handles one message. The caller runs these one at a time: `open` after `host` is an
   * order the front-end relies on, and an overlapping `handle` would not keep it.
   */
  async handle(request: Request): Promise<void> {
    switch (request.type) {
      case 'host': {
        await this.connect(() =>
          this.engines.host(request.serverUrl, request.displayName ?? this.defaultName),
        );
        break;
      }
      case 'join': {
        await this.connect(() =>
          this.engines.join(request.invite, request.displayName ?? this.defaultName),
        );
        break;
      }
      case 'leave': {
        await this.leave();
        break;
      }
      case 'open': {
        this.editor.opened(request.path, request.text);
        this.bridge?.documentOpened(request.path);
        break;
      }
      case 'close': {
        this.bridge?.documentClosed(request.path);
        this.editor.closed(request.path);
        break;
      }
      case 'change': {
        const applied = this.editor.changed(request.path, {
          start: request.start,
          end: request.end,
          text: request.text,
        });
        if (applied) {
          this.bridge?.documentChanged(request.path);
        }
        break;
      }
      case 'applied': {
        this.editor.settleApply(request.id, request.ok);
        break;
      }
      case 'saved': {
        this.editor.settleSave(request.id, request.ok);
        break;
      }
      case 'selection': {
        this.bridge?.selectionChanged(request.path, {
          anchor: request.anchor,
          head: request.head,
        });
        break;
      }
      case 'selectionCleared': {
        this.bridge?.selectionCleared();
        break;
      }
    }
  }

  /** Ends the session, if there is one. */
  async leave(): Promise<void> {
    this.bridge?.dispose();
    this.bridge = undefined;
    const engine = this.engine;
    this.engine = undefined;
    this.editor.reset();
    if (engine !== undefined) {
      await engine.disconnect();
    }
    this.send({ type: 'status', state: 'idle' });
  }

  private async connect(open: () => Promise<CompanionEngine>): Promise<void> {
    await this.leave();
    this.send({ type: 'status', state: 'connecting' });
    let engine: CompanionEngine;
    try {
      engine = await open();
    } catch (error: unknown) {
      this.send({
        type: 'status',
        state: 'error',
        message: error instanceof Error ? error.message : String(error),
      });
      return;
    }
    this.engine = engine;
    this.bridge = new SessionBridge({
      engine,
      host: this.editor,
      autoSave: this.autoSave,
    });
    const session = engine.session();
    const invite = engine.inviteUrl();
    this.send({
      type: 'status',
      state: session.role === 'host' ? 'hosting' : 'joined',
      role: session.role,
      roomId: session.roomId,
      ...(invite === undefined ? {} : { invite }),
    });
    // The room's open-document set at the moment of joining arrives in the handshake rather
    // than as an event, so a guest would otherwise hear about the room's documents only if
    // one changed after it arrived.
    this.send({
      type: 'report',
      report: { kind: 'documents', documents: session.documents },
    });
  }
}
