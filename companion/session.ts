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
import { SelvageEngine, isProtocolError } from '../vendor/engine/index.ts';

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
  /** Documents the front-end has opened whose text the room has not sent yet, by their own text. */
  private readonly unarrived = new Map<string, string>();
  private stopListening?: () => void;

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
        this.open(request.path, request.text);
        break;
      }
      case 'close': {
        this.close(request.path);
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
    this.stopListening?.();
    this.stopListening = undefined;
    this.unarrived.clear();
    const engine = this.engine;
    this.engine = undefined;
    this.editor.reset();
    if (engine !== undefined) {
      await engine.disconnect();
    }
    this.send({ type: 'status', state: 'idle' });
  }

  /**
   * Puts a document in front of the bridge.
   *
   * A guest hears the room's open-document set in the handshake, and the sync that carries the
   * text is a later message. Reconciling a buffer against a replica that has received nothing
   * asks it to hold the empty document, which a Neovim buffer cannot: its text always ends in a
   * newline, so the buffer would keep one the room does not have, the mirror would drop it, and
   * the two would hold different texts from the first keystroke.
   *
   * Such a document is held in the room now, and put in front of the bridge when its text is
   * there. The hold is what makes the room send the text to this client and what makes its
   * arrival an event this process hears, so waiting for the text without it would wait for
   * ever. A host supplies the text instead of waiting for it, so it opens at once.
   */
  private open(path: string, text: string): void {
    const engine = this.engine;
    if (engine !== undefined && engine.session().role === 'guest' && !engine.has(path)) {
      this.unarrived.set(path, text);
      void engine.open(path).catch((error: unknown) => {
        this.send({
          type: 'report',
          report: {
            kind: 'sessionError',
            code: isProtocolError(error) ? error.code : 'error',
            message: `the server refused to open ${path}: ${error instanceof Error ? error.message : String(error)}`,
          },
        });
      });
      return;
    }
    this.editor.opened(path, text);
    this.bridge?.documentOpened(path);
  }

  /** Stops sharing a document, whether or not the room's text ever arrived for it. */
  private close(path: string): void {
    if (this.unarrived.delete(path)) {
      // Nothing was put in front of the bridge, so the hold this process took is its own to
      // give back.
      void this.engine?.close(path).catch(() => undefined);
      return;
    }
    this.bridge?.documentClosed(path);
    this.editor.closed(path);
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
    // The event that brings a document's text is the moment a document opened before it can be
    // reconciled against it. The bridge's own listener was registered first and finds no buffer
    // for the path, so the reconcile here is the first one the document gets.
    const stop = engine.on((event) => {
      if (event.type !== 'documentChanged') {
        return;
      }
      const text = this.unarrived.get(event.path);
      if (text !== undefined) {
        this.unarrived.delete(event.path);
        this.open(event.path, text);
      }
    });
    this.stopListening = stop;
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
