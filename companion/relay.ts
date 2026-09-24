/**
 * The companion's session: the socket wiring the vendored engine's relay is, with
 * this repository's own transport and nothing above it but the bridge.
 *
 * The wiring itself is not here, and that is the point of where it lives. `vendor/engine/relay.ts`
 * opens the socket, says `session.hello`, seats the connection from `room.created`/`room.joined`,
 * runs the session's clocks and mints the host's invite with its fragment;
 * `vendor/bridge/peer-engine.ts` reads that and the session's observables into the vocabulary this
 * companion already drives. What is left for this file is the two things a Node client decides:
 * which socket library to dial with, and what this Neovim's own listing is.
 *
 * **The crypto seam is the engine's default.** WebCrypto is `globalThis.crypto` in the Node this
 * companion requires (22.18), so no Node-only seam is needed here and none is written.
 *
 * **Where a host's room state is kept.** Nowhere. §7.1's store is what a returning host continues
 * its `issued` series from, and this client has no resume (`§9.1`): a dropped socket ends its
 * session, so there is no returning host to continue anything.
 */

import WebSocket from 'ws';

import { PeerEngine } from '../vendor/bridge/index.ts';
import type { CompanionEngine } from './session.ts';
import type { WebSocketFactory, WebSocketLike } from '../vendor/engine/index.ts';

/**
 * The code a link this client will not join with is refused behind.
 *
 * `§5.1`'s refusal is local and has no wire form: it happens before a socket is opened, it is not a
 * `session.error`, and `§11`'s vocabulary is not involved. What it is about is the whole of what
 * there is to say, and the engine says it — so a front-end shown a failure with no code at all
 * would read it as a server that did not answer and replace that sentence with one about a
 * connection. This is the companion's own name for the case, and not a code of the protocol's.
 */
export const INVITE_REFUSED = 'invite_refused';

/** A link refused locally, with the engine's own words for what is wrong with it. */
export class UnreadableInvite extends Error {
  readonly code = INVITE_REFUSED;
}

/** The socket this companion dials with, from the `ws` package it already depends on. */
const factory: WebSocketFactory = (url: string): WebSocketLike =>
  new WebSocket(url) as unknown as WebSocketLike;

/** The listing this companion's folder watcher keeps, as `§7.1`'s producer reads it. */
export interface ListingSource {
  current(): readonly string[];
  replace(paths: readonly string[]): void;
}

/** The engine this companion drives, plus the four things it needs of its own. */
function adapter(engine: PeerEngine): CompanionEngine {
  return {
    session: () => engine.session(),
    text: (path) => engine.text(path),
    has: (path) => engine.has(path),
    open: (path) => engine.open(path),
    close: (path) => engine.close(path),
    insert: (path, index, text) => engine.insert(path, index, text),
    delete: (path, index, length) => engine.delete(path, index, length),
    setSelection: (path, selection) => engine.setSelection(path, selection),
    setAwareness: (state) => engine.setAwareness(state),
    presence: () => engine.presence(),
    resolveSelection: (path, selection) => engine.resolveSelection(path, selection),
    on: (listener) => engine.on(listener),
    inviteUrl: () => engine.inviteUrl(),
    disconnect: () => engine.disconnect(),
    rename: (name) => engine.rename(name),
    grant: (paths) => engine.grant(paths),
    grantedPaths: () => engine.grantedPaths(),
  };
}

/**
 * Mints a room on the server an address names, as its host.
 *
 * The listing is read when a state is published and replaced by `grant`, so the folder watcher's
 * own reading is what the room hears — there is no second copy of the tree in this process.
 */
export async function hostRoom(
  serverUrl: string,
  displayName: string,
  listing: ListingSource,
): Promise<CompanionEngine> {
  return adapter(
    await PeerEngine.host({
      baseUrl: serverUrl,
      displayName,
      listing,
      webSocketFactory: factory,
      client: 'selvage-nvim',
    }),
  );
}

/** Joins the room an invite names, from either form of the link. */
export async function joinRoom(invite: string, displayName: string): Promise<CompanionEngine> {
  // `§5.1`'s refusal happens before a socket is opened, and that is what tells it apart from a
  // connection that failed: the factory below is the engine's one way to dial, so a join that threw
  // with it never called is a link this client would not read, and the engine's sentence for it is
  // the whole of what a person can act on.
  let dialled = false;
  const dialling: WebSocketFactory = (url: string): WebSocketLike => {
    dialled = true;
    return factory(url);
  };
  try {
    return adapter(
      await PeerEngine.join({
        invite,
        displayName,
        webSocketFactory: dialling,
        client: 'selvage-nvim',
      }),
    );
  } catch (error: unknown) {
    if (dialled) {
      throw error;
    }
    throw new UnreadableInvite(error instanceof Error ? error.message : String(error));
  }
}
