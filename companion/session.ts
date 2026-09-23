/**
 * The companion's session: one engine, one bridge, one editor host, driven by the messages
 * the front-end sends.
 *
 * Nothing here decides anything about a document — `vendor/bridge/` does that. What is here
 * is the lifecycle the front-end's commands name (host, join, leave) and the routing of one
 * message to one method.
 */

import { watch, type FSWatcher } from 'node:fs';

import { SessionBridge } from '../vendor/bridge/index.ts';
import type { Engine, TextChange } from '../vendor/bridge/index.ts';
import {
  SelvageEngine,
  code as errCode,
  fetchMeta,
  hostVersion,
  isProtocolError,
} from '../vendor/engine/index.ts';
import type { HostDecision, Meta, WireVersion } from '../vendor/engine/index.ts';

import { NvimEditorHost } from './editor.ts';
import { enumerateGrant } from './grant.ts';
import { isRequest } from './ipc.ts';
import { WIRE_VERSION_2, hostVersion2, joinVersion2, wireVersionOf } from './relay.ts';
import type { ListingSource } from './relay.ts';
import type { Notification, Request } from './ipc.ts';

/** The readable wire, the version a room the server can read is minted at. */
const WIRE_VERSION_1: WireVersion = 'selvage/1';

/**
 * The code a version refusal carries. It is not the protocol's: no server said it, and there is no
 * server in it — the refusal is this process's own decision, taken before anything was dialled — so
 * a front-end reads it as such and shows the sentence that comes with it rather than one about a
 * connection.
 */
export const WIRE_VERSION_REFUSED = 'wire_version_refused';

/**
 * How long a burst of file-system events is gathered for before the shared folder is read again.
 * A `git checkout` or a build produces thousands of events, and one reading per event would be a
 * thousands-fold walk of the tree; the window bounds a burst to one walk rather than one per file.
 */
const GRANT_SETTLE_MS = 250;

/**
 * How long a guest join waits for the listing the handshake carried before it reports the
 * session as started without one.
 *
 * The server queues `doc.granted` straight after `room.joined`, and only when the room grants
 * something; the engine reads the two frames off one socket, so the second may land a turn after
 * `join()` resolves. Reading the replica without waiting would hand the front-end an empty listing
 * for a room that has one, and — because the join's summary is said over the documents report —
 * the real listing would then arrive after that summary, where the front-end deliberately stays
 * silent. A room that grants nothing pays this bound once, at the join.
 */
const HANDSHAKE_GRANT_MS = 250;

/** The engine, plus the members the lifecycle needs and the bridge does not. */
export interface CompanionEngine extends Engine {
  inviteUrl(): string | undefined;
  disconnect(): Promise<void>;
  /**
   * Changes this connection's display name (§5). The bridge's `Engine` slice has no use for it
   * — a name is not a document — so it is here, on the adapter's own extension of the seam.
   */
  rename(displayName: string): Promise<void>;
  /** Publishes the room's grant: the host's listing of its working tree (§5). */
  grant(paths: readonly string[]): Promise<void>;
  /**
   * The room's grant as this replica holds it. The listing is not a member of the join reply —
   * the server restates it in a `doc.granted` straight after `room.joined` — so a session read
   * from the engine at the moment it starts is how a client learns what the room already grants.
   */
  grantedPaths(): string[];
}

/** How a session is opened. A test supplies its own; the default opens a real one. */
export interface EngineFactory {
  host(serverUrl: string, displayName: string): Promise<CompanionEngine>;
  join(invite: string, displayName: string): Promise<CompanionEngine>;
}

/**
 * The `selvage/2` half, kept apart from the version-1 factory because it is handed one thing
 * more: a host's listing, which `§7.1` seals into the room state rather than the server keeping.
 */
export interface Wire2Factory {
  host(serverUrl: string, displayName: string, listing: ListingSource): Promise<CompanionEngine>;
  join(invite: string, displayName: string): Promise<CompanionEngine>;
}

export const realEngines: EngineFactory = {
  host: (serverUrl, displayName) => SelvageEngine.host(serverUrl, displayName),
  join: (invite, displayName) => SelvageEngine.join(invite, displayName),
};

export const realWire2: Wire2Factory = { host: hostVersion2, join: joinVersion2 };

/**
 * A document the front-end has opened whose text the room has not sent yet: the text it was
 * opened with, and the local changes the front-end has counted since.
 */
interface Unarrived {
  text: string;
  changes: TextChange[];
}

export interface CompanionOptions {
  send: (notification: Notification) => void;
  /**
   * The editor side of the seam. The default is this process's own, over the same `send`; a test
   * supplies one that records what the bridge asks of it.
   */
  editor?: NvimEditorHost;
  engines?: EngineFactory;
  /**
   * The `selvage/2` factories. A test supplies its own for the same reason it supplies an
   * `engines`: the room behind them is real, and what a test is about is what this process does.
   */
  wire2?: Wire2Factory;
  /**
   * How the shared folder is read. `enumerateGrant` in a real session; a test supplies one whose
   * completion it decides, because a walk that outlasts the window a burst is gathered in is the
   * only way to see two of them in flight at once.
   */
  enumerate?: (root: string) => Promise<string[]>;
  displayName?: string;
  /**
   * Whether a document the room changed is written, for a `host`/`join` that does not say.
   * The front-end's own setting rides in the request, as it does in the other client; this is
   * what that leaves for a front-end that says nothing.
   */
  autoSave?: boolean;
  /**
   * Reads the server's `/meta` before a host, or `undefined` for one that could not be read. The
   * default is the real endpoint, best effort; a test supplies its own for the same reason it
   * supplies an `engines`: what it is about is what this process does with the answer, and a
   * process in a test should not dial one.
   */
  meta?: MetaReader;
}

/** How a server's `/meta` is read: the body, or `undefined` when it could not be read at all. */
export type MetaReader = (baseUrl: string) => Promise<Meta | undefined>;

export class Companion {
  private readonly send: (notification: Notification) => void;
  private readonly engines: EngineFactory;
  private readonly wire2: Wire2Factory;
  private readonly enumerate: (root: string) => Promise<string[]>;
  private readonly editor: NvimEditorHost;
  private readonly defaultName: string;
  private readonly autoSave: boolean;
  private readonly readMeta: MetaReader;
  private engine?: CompanionEngine;
  private bridge?: SessionBridge;
  /** Documents the front-end has opened whose text the room has not sent yet — see `open`. */
  private readonly unarrived = new Map<string, Unarrived>();
  private stopListening?: () => void;
  /** The shared folder, watched while this process is hosting and closed with the session. */
  private grantWatcher?: FSWatcher;
  /**
   * Whether the room's listing has already reached the front-end through the bridge's own
   * `grant` report. The bridge is constructed before the handshake's listing is read, so an
   * event it forwards is the same listing the snapshot below would carry, and one of the two
   * has to stand down.
   */
  private grantReported = false;
  /** The rereading a burst has scheduled, if one is outstanding. */
  private grantRepublish?: NodeJS.Timeout;
  /** The listing last handed to the room, so a folder that has not changed publishes nothing. */
  private grantedListing?: string[];
  /**
   * How many readings of the shared folder have been started. A reading that is not the last one
   * started has nothing to say: it read the folder before a later one did.
   */
  private grantReadings = 0;
  /** The folder this session shares while hosting it: the listing a reclaim republishes. */
  private grantRoot?: string;
  /**
   * The peer id the current connection seated with. A reconnect is a new peer under the
   * same room, so a seat report under a different id is the reclaim rather than later
   * room news — the re-seat signal this engine generation carries (`reconnecting` only
   * exists upstream; see the re-vendor note in the reclaim-grant round log).
   */
  private seatedPeer?: string;

  constructor(options: CompanionOptions) {
    this.send = options.send;
    this.editor = options.editor ?? new NvimEditorHost({ send: this.send });
    this.engines = options.engines ?? realEngines;
    this.wire2 = options.wire2 ?? realWire2;
    this.enumerate = options.enumerate ?? enumerateGrant;
    this.defaultName = options.displayName ?? 'neovim';
    this.autoSave = options.autoSave ?? true;
    this.readMeta = options.meta ?? readMetaBestEffort;
  }

  /**
   * Handles one message. The caller runs these one at a time: `open` after `host` is an
   * order the front-end relies on, and an overlapping `handle` would not keep it.
   */
  async handle(request: Request): Promise<void> {
    // The stdin mouth checks this too, but a request can also arrive from a test or a future
    // caller: one answered blindly is a crash down the line, where the failure names nothing
    // about the message that caused it. Misshapen is dropped, not answered.
    if (!isRequest(request)) {
      return;
    }
    switch (request.type) {
      case 'host': {
        // Which version a new room is minted at is the server's to say and the front-end's to pin
        // (`PROTOCOL.md` §2): a client that can speak `selvage/2` mints it where `/meta` seats it,
        // refuses locally rather than falling back where the list is reachable and holds nothing
        // at that major, and attempts it where `/meta` could not be read. A pin outranks the list
        // both ways, and a pin the server does not seat is refused rather than fallen back from.
        if (this.refuseWhileLive('host')) {
          break;
        }
        const decided = hostVersion(await this.readMeta(request.serverUrl), request.wire);
        if (decided.outcome === 'refuse') {
          this.refuseVersion(request.serverUrl, decided);
          break;
        }
        const version = decided.version;
        await this.connect(
          'host',
          () =>
            version === WIRE_VERSION_2
              ? this.hosting2(
                  request.serverUrl,
                  request.displayName ?? this.defaultName,
                  request.root,
                )
              : this.engines.host(request.serverUrl, request.displayName ?? this.defaultName),
          request.autoSave,
          request.root,
          version,
        );
        break;
      }
      case 'join': {
        // Which version a join speaks is the link's to say and not a setting's: `§5.1`'s
        // fragment carries the room key and the host key, and a room pinned to `selvage/2` seats
        // no connection that cannot read them.
        const version = wireVersionOf(request.invite);
        await this.connect(
          'join',
          () =>
            version === WIRE_VERSION_2
              ? this.wire2.join(request.invite, request.displayName ?? this.defaultName)
              : this.engines.join(request.invite, request.displayName ?? this.defaultName),
          request.autoSave,
          undefined,
          version,
        );
        break;
      }
      case 'leave': {
        await this.leave();
        break;
      }
      case 'rename': {
        this.rename(request.displayName);
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
        this.changed(request.path, {
          start: request.start,
          end: request.end,
          text: request.text,
        });
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
    this.stopWatching();
    this.grantRoot = undefined;
    this.seatedPeer = undefined;
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
   * A mid-session rename, from the front-end's `rename`. The engine sends `session.rename` and
   * the room answers with `peer.renamed`, which the bridge turns into a re-labelled cursor; the
   * name in force is the engine's, so nothing here holds it. A refusal is the server declining
   * the name — the live one stands — and is reported rather than thrown, as a refused `open` is.
   */
  private rename(displayName: string): void {
    const engine = this.engine;
    if (engine === undefined) {
      return;
    }
    void engine.rename(displayName).catch((error: unknown) => {
      this.send({
        type: 'report',
        report: {
          kind: 'sessionError',
          code: isProtocolError(error) ? error.code : 'error',
          message: `the server refused the display name "${displayName}": ${error instanceof Error ? error.message : String(error)}`,
        },
      });
    });
  }

  /**
   * Puts a document in front of the bridge.
   *
   * A guest hears the room's open-document set in the handshake, and the sync that carries the
   * text is a later message. Reconciling a buffer against a replica that has received nothing
   * asks it to hold the empty document, while the room may yet send a seed: the buffer would
   * publish its own content as the document, and the two would hold different texts from the
   * first keystroke.
   *
   * Such a document is held in the room now, and put in front of the bridge when its text is
   * there. The hold is what makes the room send the text to this client, and the text's arrival
   * is what this process hears — either as the engine's event for a document it holds, or, when
   * the text was here before the hold was answered, as that answer itself. Waiting for the text
   * without the hold would wait for ever. A host supplies the text instead of waiting for it, so
   * it opens at once.
   *
   * A document opened this way has no mirror until the text arrives, and a change made to it in
   * the meantime is kept rather than dropped — see `changed`.
   */
  private open(path: string, text: string): void {
    const engine = this.engine;
    // The bridge holds a guest document back by the same rule; this deferral is here too because
    // the count an edit is offered against is the mirror's, and the mirror is `arrive`'s to make.
    if (engine !== undefined && engine.session().role === 'guest' && !engine.has(path)) {
      this.unarrived.set(path, { text, changes: [] });
      void engine
        .open(path)
        .then(() => {
          // The text can be here before the server's answer to the hold is: the answer and the
          // sync that carries the text are two messages on one connection, and which arrives
          // first is the server's to decide. The engine reports an arrival for a document it
          // holds, so it reports the one that arrives second — the answer, when the text was
          // already here, is the moment nothing else will report.
          if (engine.has(path)) {
            this.arrive(path);
          }
        })
        .catch((error: unknown) => {
          // A refused hold leaves nothing that will ever open this document, so the entry —
          // and the changes kept against it — goes with the report rather than growing for the
          // rest of the session.
          this.unarrived.delete(path);
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
    this.renderCursors();
  }

  /**
   * A local edit, from the front-end's `change`.
   *
   * The front-end counts every change the moment it makes it, and the mirror counts every change
   * it takes. A change to a document whose mirror does not exist yet — a guest's document whose
   * room text has not arrived — would be counted on one side only, and the version an `applyEdit`
   * carries would then be one the front-end has already left: the range would be refused for
   * ever, and the buffer's difference from the replica, of which the mirror is this process's
   * model, would be published to the room. So a change the mirror has no document to take is kept
   * and applied when the document is made, in the order the front-end counted it.
   */
  private changed(path: string, change: TextChange): void {
    if (this.editor.changed(path, change)) {
      this.bridge?.documentChanged(path);
      return;
    }
    this.unarrived.get(path)?.changes.push(change);
  }

  /**
   * The room's text for a document this client opened before it arrived. The mirror is created
   * against the text the front-end opened the buffer with, and then takes the local changes the
   * front-end has counted since — so the two counts start at the same moment and move together,
   * which is what an `applyEdit`'s version is read against.
   */
  private arrive(path: string): void {
    const held = this.unarrived.get(path);
    if (held === undefined) {
      return;
    }
    this.unarrived.delete(path);
    this.editor.opened(path, held.text);
    for (const change of held.changes) {
      this.editor.changed(path, change);
    }
    this.bridge?.documentOpened(path);
    this.renderCursors();
  }

  /**
   * Asks the bridge for the remote carets now that a document has opened. The bridge reports
   * them when awareness changes, but a cursor naming a path this client did not yet hold is
   * skipped then — a peer already in the room when this client joins would never be drawn
   * until they moved. The VS Code adapter does the same on a visible-editor change.
   */
  private renderCursors(): void {
    if (this.bridge !== undefined) {
      this.editor.renderCursors(this.bridge.cursors());
    }
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

  /**
   * Waits for the handshake's `doc.granted` when the room grants anything, or the bound.
   *
   * The event is the bridge's as much as this listener's — the bridge was constructed above and
   * forwards it either way — so this is a wait on a real arrival and not a delay: a room that
   * grants nothing simply never emits it, and the bound is that case's price.
   */
  private async settleGrant(engine: CompanionEngine): Promise<void> {
    if (engine.grantedPaths().length > 0) {
      return;
    }
    await new Promise<void>((resolve) => {
      let timer: ReturnType<typeof setTimeout>;
      const stop = engine.on((event) => {
        if (event.type === 'grantChanged') {
          finish();
        }
      });
      function finish(): void {
        clearTimeout(timer);
        stop();
        resolve();
      }
      timer = setTimeout(finish, HANDSHAKE_GRANT_MS);
    });
  }

  /**
   * Refuses a request while a session is live, and says which room still stands. Which session a
   * person gives up, and whether they meant to, is a question only the front-end can ask — the
   * front-end refuses a second host or join before it sends one. This process is the engine's
   * host, so a request that arrives anyway is refused and said so, rather than obeyed: opening a
   * second session would end the first behind the front-end's back, and the host of a room would
   * lose it to a mistyped address. True when the request was answered that way.
   */
  private refuseWhileLive(what: 'host' | 'join'): boolean {
    const live = this.engine;
    if (live === undefined) {
      return false;
    }
    this.send({ type: 'refused', what, roomId: live.session().roomId });
    return true;
  }

  /**
   * Says a local refusal of the version a host asked for, in the front-end's own words. It is a
   * failure of the session rather than of a connection — this process never dialled anything — so
   * it is a `status` the front-end shows and not a report of a room that was joined.
   */
  private refuseVersion(
    address: string,
    refusal: Extract<HostDecision, { outcome: 'refuse' }>,
  ): void {
    this.send({
      type: 'status',
      state: 'error',
      code: WIRE_VERSION_REFUSED,
      message: hostVersionRefusal(address, refusal),
    });
  }

  /**
   * Opens a session, unless one is live.
   */
  private async connect(
    what: 'host' | 'join',
    open: () => Promise<CompanionEngine>,
    autoSave?: boolean,
    root?: string,
    version: WireVersion = WIRE_VERSION_1,
  ): Promise<void> {
    if (this.refuseWhileLive(what)) {
      return;
    }
    this.send({ type: 'status', state: 'connecting' });
    let engine: CompanionEngine;
    try {
      engine = await open();
    } catch (error: unknown) {
      this.send({
        type: 'status',
        state: 'error',
        message: error instanceof Error ? error.message : String(error),
        // A refusal the protocol named carries its code as well as its words: the server's
        // message answers with values the person never chose to see — `no such room: <id>` —
        // and the code is the same fact without them, for a front-end that says it its own way.
        ...(isProtocolError(error) ? { code: error.code } : {}),
      });
      return;
    }
    this.engine = engine;
    // The peer id this connection seated with: a reconnect seats again under a new one,
    // which is what tells a reclaim apart from later room news below.
    this.seatedPeer = engine.session().peer.peer_id;
    // Which listing reports this session has produced is the session's, not the process's.
    this.grantReported = false;
    this.bridge = new SessionBridge({
      engine,
      host: this.editor,
      autoSave: autoSave ?? this.autoSave,
    });
    // The event that brings a document's text is the moment a document opened before it can be
    // reconciled against it. A document opened that way has no buffer yet — `arrive` is what
    // makes one — so the bridge's own listener, registered first, finds nothing for the path and
    // the reconcile here is the first one the document gets.
    //
    // The two events that end a session, `roomGone` and `disconnected`, are the engine's own
    // last word and are handled the same way `leave` is: the room is over, this process has
    // nothing left to hold it with, and the front-end is told with `status idle` rather than
    // left with an engine it cannot use. The bridge's own report of them reaches the front-end
    // first — `leave` here does not know the reason, so the reason is the bridge's to say.
    const stop = engine.on((event) => {
      if (event.type === 'grantChanged') {
        // The bridge forwards this itself, and it was constructed above, so its `grant` report
        // is already on its way: the snapshot below must not write the same listing again.
        this.grantReported = true;
        return;
      }
      if (event.type === 'documentChanged') {
        this.arrive(event.path);
        return;
      }
      if (event.type === 'documentsChanged' || event.type === 'peersChanged') {
        // Every seat reports the document set and the peers, under a new peer id on a
        // reconnect — so a report under an id this connection did not seat with is the
        // reclaim, while later room news reuses the id and is left alone.
        if (engine.session().peer.peer_id !== this.seatedPeer) {
          this.seatedPeer = engine.session().peer.peer_id;
          this.republishAfterReseat(engine);
        }
        return;
      }
      if (event.type === 'roomGone' || event.type === 'disconnected') {
        void this.leave();
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
    // The room's grant is a fact of that handshake too, and it is not a member of the join reply:
    // the server restates it in a `doc.granted` straight after `room.joined`, and only when the
    // room grants something. The engine reads the two frames off one socket, so the listing may
    // land a turn after `join()` resolves: a guest with no document in front of it waits for that
    // frame here rather than reporting an empty listing and letting the real one arrive after the
    // join's summary, where the front-end deliberately stays silent. A later change is the bridge's
    // `grant` report.
    //
    // It is sent *before* the documents, and the order is the front-end's to rely on: a guest
    // materialises the listing as a directory and names a document's buffer after the file it
    // was materialised at, so the listing has to be in front of the front-end before the first
    // document is opened. Both are sent in one turn, so nothing is waiting on the wire.
    //
    // A listing the bridge already forwarded needs no snapshot: it is the same listing, it is
    // already in front of the documents, and writing it twice would put a whole grant on the pipe
    // for nothing. The wait is what gives the bridge that chance; a room with nothing to list has
    // no report to stand down for, and the empty snapshot below is its answer.
    if (session.role === 'guest' && session.documents.length === 0 && !this.grantReported) {
      await this.settleGrant(engine);
    }
    if (!this.grantReported) {
      this.send({ type: 'report', report: { kind: 'grant', paths: engine.grantedPaths() } });
    }
    // The room's open-document set at the moment of joining arrives in the handshake rather
    // than as an event, so a guest would otherwise hear about the room's documents only if
    // one changed after it arrived. The peers are the same fact about the same handshake: the
    // `peersChanged` event the seat emitted went out before the bridge was listening.
    this.send({
      type: 'report',
      report: { kind: 'documents', documents: session.documents },
    });
    this.send({ type: 'report', report: { kind: 'peers', peers: session.peers } });
    // The room's shape is the host's to publish: the folder the session was started in is the
    // grant, read off the working copy as the session starts and read again whenever the folder
    // changes under it — a later change to which buffers are open is not a statement about the
    // folder, and neither is anything outside it.
    this.grantRoot = session.role === 'host' ? root : undefined;
    if (session.role === 'host' && root !== undefined && root !== '') {
      this.editor.sharedFolder(root);
      // A `selvage/2` host published the listing before this point — the state it sealed at mint
      // carries it — so its first reading is the one already in the room, and the watcher starts
      // from it rather than publishing the same tree again. A `selvage/1` host publishes here,
      // because a version-1 room's grant is the server's to hold and this is the frame that puts
      // it there.
      if (version !== WIRE_VERSION_2) {
        this.publishGrant(root);
      }
      this.watchGrant(root);
    }
  }

  /**
   * Opens a `selvage/2` room as its host, with the shared folder's own reading as its first
   * listing.
   *
   * `§7.1` seals a state from the listing rather than the server holding one, so the walk has to
   * come before the mint: a host that minted first would put an empty tree in front of its first
   * guest, and a room that grants nothing is a different room from one whose listing is late.
   *
   * The walk is held in this attempt's own scope until the room that seals it exists. A mint can
   * throw — a dead address, a server that refuses the version-2 hello — and a listing written into
   * the session's own field before that would outlive the attempt: `publishGrant` compares against
   * what it holds, so the next `selvage/1` host of the same folder would find it unchanged and
   * send no `doc.grant` at all. A room the mint sealed a state from holds the walk; one that never
   * minted holds nothing.
   */
  private async hosting2(
    serverUrl: string,
    displayName: string,
    root?: string,
  ): Promise<CompanionEngine> {
    let walked: readonly string[] = [];
    const listing: ListingSource = {
      current: () => walked,
      replace: (paths) => {
        walked = [...paths];
      },
    };
    if (root !== undefined && root !== '') {
      try {
        listing.replace(await this.enumerate(root));
      } catch (error: unknown) {
        // A folder this process cannot read is not a reason to refuse the room: the host's
        // listing is empty until it can be read, and the walk's own failure is reported by
        // `publishGrant`, which the watcher runs on the next change.
        this.send({
          type: 'report',
          report: {
            kind: 'sessionError',
            code: 'error',
            message: `could not read the folder this session shares: ${describe(error)}`,
          },
        });
      }
    }
    const engine = await this.wire2.host(serverUrl, displayName, listing);
    // The state the mint sealed carries this listing, so the room has been handed it: from here
    // it is what `publishGrant` compares a fresh walk against.
    this.grantedListing = [...walked];
    return engine;
  }

  /**
   * Publishes the shared folder again after the retry reseated: a host that dropped reclaims
   * its room rather than minting a new one, and the room kept the listing it had while this
   * process was gone. The folder as it stands now replaces the dead listing — the last listing
   * is forgotten first, so even an unchanged folder re-asserts what the room holds, one frame
   * the guests dedupe, rather than staying silent. A guest owes the room no listing.
   */
  private republishAfterReseat(engine: CompanionEngine): void {
    const root = this.grantRoot;
    if (engine.session().role !== 'host' || root === undefined || root === '') {
      return;
    }
    this.grantedListing = undefined;
    this.publishGrant(root);
  }

  /**
   * Watches the folder this session shares and republishes its listing when it changes.
   *
   * The watcher belongs to the session: it is opened only while hosting — a guest publishes no
   * grant and so has nothing to watch — and closed when the session ends. One that reports an
   * error is closed too: a failed watcher has no promise left to keep, and holding one would
   * leave a host that looks live with a listing that silently stops moving.
   */
  private watchGrant(root: string): void {
    let watcher: FSWatcher;
    try {
      watcher = watch(root, { recursive: true });
    } catch (error: unknown) {
      this.reportWatchFailure(error);
      return;
    }
    watcher.on('change', () => {
      this.scheduleGrant(root);
    });
    watcher.on('error', (error) => {
      this.reportWatchFailure(error);
    });
    this.grantWatcher = watcher;
  }

  /**
   * Says the shared folder has stopped being watched, once; the session goes on with the listing
   * it holds, because a listing that is not being refreshed is the room it was before any of this.
   */
  private reportWatchFailure(error: unknown): void {
    this.stopWatching();
    this.send({
      type: 'report',
      report: {
        kind: 'sessionError',
        code: 'error',
        message: `could not watch the folder this session shares: ${describe(error)}`,
      },
    });
  }

  /**
   * Schedules one rereading of the shared folder. The first event of a burst sets the timer and
   * the ones after it do not move it, so a burst is read once per window rather than once per
   * event: a window does not wait for the burst to end.
   */
  private scheduleGrant(root: string): void {
    if (this.grantRepublish !== undefined) {
      return;
    }
    this.grantRepublish = setTimeout(() => {
      this.grantRepublish = undefined;
      this.publishGrant(root);
    }, GRANT_SETTLE_MS);
  }

  /** Stops watching the shared folder, and forgets the listing the room was last offered. */
  private stopWatching(): void {
    if (this.grantRepublish !== undefined) {
      clearTimeout(this.grantRepublish);
      this.grantRepublish = undefined;
    }
    this.grantWatcher?.close();
    this.grantWatcher = undefined;
    this.grantedListing = undefined;
  }

  /**
   * Publishes the listing of the folder this session shares.
   *
   * A server that does not know `doc.grant` answers `unknown_method`, which means it has no
   * grant rather than that anything failed: the session goes on and the room falls back to its
   * open-document set. Any other refusal is reported and also changes nothing.
   */
  private publishGrant(root: string): void {
    const engine = this.engine;
    if (engine === undefined) {
      return;
    }
    // Which reading this is. A walk of a large tree outlasts the window a burst is gathered in —
    // the 20 000-node bound measured ~390 ms against a 250 ms window — so an event during a walk
    // starts a second one, and the two can finish in the order opposite to the one they started
    // in. The last reading started is the only one whose answer is the folder's current shape.
    const reading = ++this.grantReadings;
    void (async () => {
      let paths: string[];
      try {
        paths = await this.enumerate(root);
      } catch (error: unknown) {
        if (this.engine === engine) {
          this.send({
            type: 'report',
            report: {
              kind: 'sessionError',
              code: 'error',
              message: `could not read the folder this session shares: ${describe(error)}`,
            },
          });
        }
        return;
      }
      // A reading that started before a later one has nothing to say, however it finished first:
      // the folder it read was replaced while the two were in flight, and publishing it would put
      // the room back on a listing the reading after it had already replaced. The next change to
      // the folder is what would put it right, and a room that is not changing is left wrong.
      if (reading !== this.grantReadings) {
        return;
      }
      // A session that ended while the folder was being read has no room left to be told
      // anything, and its listing must not become the next session's starting point.
      if (this.engine !== engine) {
        return;
      }
      // The engine publishes unconditionally, and a listing is a snapshot the room replaces
      // wholesale: a folder that names exactly what it named last time has nothing to say.
      const previous = this.grantedListing;
      if (previous !== undefined && sameListing(previous, paths)) {
        return;
      }
      try {
        await engine.grant(paths);
        this.grantedListing = paths;
      } catch (error: unknown) {
        if (this.engine !== engine) {
          return;
        }
        if (isProtocolError(error, errCode.unknownMethod)) {
          // The server has no grant at all, so nothing was refused: the room keeps its
          // open-document set, and this folder is what it would grant if it could.
          this.grantedListing = paths;
          return;
        }
        // A refused listing leaves the room with the grant it had, so it is not remembered as
        // the one the room holds: the folder's next change offers the new listing all the same.
        this.send({
          type: 'report',
          report: {
            kind: 'sessionError',
            code: isProtocolError(error) ? error.code : 'error',
            message: `the server refused the listing of the folder this session shares: ${describe(error)}`,
          },
        });
      }
    })();
  }
}

/** Whether two listings name the same paths, in the same order. */
function sameListing(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((path, index) => path === right[index]);
}

/**
 * What the server's `/meta` answers, or `undefined` when it could not be read at all —
 * unreachable, not JSON, no fetch. Best effort by design: the endpoint is advisory and the
 * handshake reports the truth, so a body that could not be read decides nothing (`PROTOCOL.md`
 * §10).
 */
async function readMetaBestEffort(baseUrl: string): Promise<Meta | undefined> {
  try {
    return await fetchMeta(baseUrl);
  } catch {
    return undefined;
  }
}

/**
 * What a local refusal says: the server it names, the version that server does not seat, and what
 * it seats instead, in `/meta`'s own words. It is the sentence the other client shows, without the
 * `Selvage: ` wrapper each editor adds in its own spelling — the two clients say one sentence, and
 * where the version a room is minted at comes from is not a thing to learn twice.
 */
function hostVersionRefusal(
  address: string,
  refusal: Extract<HostDecision, { outcome: 'refuse' }>,
): string {
  // A `/meta` that named no version at all cannot happen here — a body with no versions is not an
  // answer, and `hostVersion` reads it as one that decides nothing — but a front-end told "its
  // /meta offers " with nothing after it reads as a truncated message.
  const offered = refusal.offered.length === 0 ? 'nothing' : refusal.offered.join(', ');
  if (refusal.reason === 'pin-not-seated') {
    return `the wire version is pinned to ${refusal.pin}, and ${address} does not seat it — its /meta offers ${offered} — so hosting there is refused rather than fallen back from.`;
  }
  return `${address} does not seat selvage/2, the encrypted wire — its /meta offers ${offered} — so a room hosted there would be one the server can read.`;
}

/** A failure as a sentence: the message of an Error, or whatever was thrown instead. */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
