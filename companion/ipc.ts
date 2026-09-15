/**
 * The local IPC between the Lua front-end and this process: one JSON object per line, in
 * both directions, over the companion's stdin and stdout.
 *
 * `DESIGN.md` §4.4 names a non-network transport for the editor-adapter ↔ sync-engine
 * boundary and leaves its shape open; this is that shape, and `README.md` documents it for
 * anyone writing a different front-end against the same companion.
 *
 * **Every offset here is a UTF-16 code unit**, counted in the document's text as Neovim
 * holds it — the buffer's lines joined by `\n` with a trailing `\n`, which is what Neovim's
 * own byte offsets count too. That is the same unit `vendor/bridge/editing.ts` works in and
 * the same unit a `Y.Text` index is, so nothing has to be converted on this side of the
 * seam; the conversion from Neovim's byte positions happens in Lua, where the bytes are.
 */

import type { Cursor } from '../vendor/bridge/index.ts';

/** A message the front-end sends. */
export type Request =
  /**
   * Mint a room on this server and become its host. Refused while a session is live: see
   * `refused`.
   *
   * `root` is the folder this session shares — the one the front-end stood in when the session
   * started — and it is what the grant is read off. It is the front-end's to say because only
   * the editor knows where its user is, and the companion's own working directory is the plugin
   * checkout it was started from. A `host` without one publishes no grant and serves no path a
   * peer asks for: a front-end that cannot name a folder shares nothing beyond the buffers it
   * sends.
   */
  | { type: 'host'; serverUrl: string; displayName?: string; autoSave?: boolean; root?: string }
  /** Join the room an invite link names. Refused while a session is live: see `refused`. */
  | { type: 'join'; invite: string; displayName?: string; autoSave?: boolean }
  /** Leave the session and drop the connection. The process stays up. */
  | { type: 'leave' }
  /**
   * Change the name this connection is known by, mid-session. It is this peer's own name, so
   * the request names no document; the room is told with `peer.renamed`, which the engine
   * applies to the cursors the front-end already draws.
   */
  | { type: 'rename'; displayName: string }
  /** A buffer is now shared under `path`, and holds `text`. */
  | { type: 'open'; path: string; text: string }
  /** The buffer is no longer shared; this client stops holding the path open. */
  | { type: 'close'; path: string }
  /** A local edit: `[start, end)` of the buffer's text became `text`. */
  | { type: 'change'; path: string; start: number; end: number; text: string }
  /** The answer to an `applyEdit`: whether the buffer now holds it. */
  | { type: 'applied'; id: number; ok: boolean }
  /** The answer to a `save`: whether the document reached disk. */
  | { type: 'saved'; id: number; ok: boolean }
  /** The caret moved, in the buffer's own offsets. */
  | { type: 'selection'; path: string; anchor: number; head: number }
  /** The caret left the shared documents. */
  | { type: 'selectionCleared' };

/** A message the companion sends. */
export type Notification =
  /**
   * Replace `[start, end)` of the buffer's text with `text`, and answer with `applied`.
   * The range is always the smallest one that gets there — never the whole document unless
   * the whole document changed.
   *
   * `version` is the document version the range was computed against. A front-end whose own
   * count has moved on — a local edit is in flight towards this process — must refuse the
   * edit rather than land a range on text it was not computed from.
   */
  | {
      type: 'applyEdit';
      id: number;
      path: string;
      start: number;
      end: number;
      text: string;
      version: number;
    }
  /** Write the document, and answer with `saved`. A document with nowhere to go answers `true`. */
  | { type: 'save'; id: number; path: string }
  /** Where the session stands. `invite` is present for the connection that minted the room. */
  | {
      type: 'status';
      state: 'idle' | 'connecting' | 'hosting' | 'joined' | 'error';
      role?: string;
      roomId?: string;
      invite?: string;
      message?: string;
    }
  /**
   * A `host` or `join` this process did not carry out, because a session is live and ending
   * it is the front-end's to ask about. The room named is the one still standing; nothing
   * about it changed.
   */
  | { type: 'refused'; what: 'host' | 'join'; roomId: string }
  /** The bridge's own report, passed through unchanged; `kind` says which. */
  | { type: 'report'; report: unknown }
  /** The remote carets this replica can resolve, in buffer offsets. */
  | { type: 'presence'; cursors: Cursor[] };

/** Reads newline-delimited JSON off a byte stream. */
export class LineReader {
  private buffer = '';
  private readonly onLine: (line: string) => void;

  constructor(onLine: (line: string) => void) {
    this.onLine = onLine;
  }

  /**
   * A chunk boundary is not a line boundary: a decoder that assumed it would split a
   * multi-byte character in half, so the text is accumulated and only whole lines handed on.
   */
  push(chunk: string): void {
    this.buffer += chunk;
    let newline = this.buffer.indexOf('\n');
    while (newline !== -1) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (line.trim() !== '') {
        this.onLine(line);
      }
      newline = this.buffer.indexOf('\n');
    }
  }
}
