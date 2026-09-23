/**
 * The local IPC between the Lua front-end and this process: one JSON object per line, in
 * both directions, over the companion's stdin and stdout.
 *
 * `DESIGN.md` §4.4 names a non-network transport for the editor-adapter ↔ sync-engine
 * boundary and leaves its shape open; this is that shape, and `README.md` documents it for
 * anyone writing a different front-end against the same companion.
 *
 * **Every offset here is a UTF-16 code unit**, counted in the document's text as Neovim
 * holds it — the buffer's lines joined by `\n`, one newline between lines and none after the
 * last, so an empty buffer is the empty string and a buffer whose last line is empty ends in a
 * newline. That text is byte for byte what the room holds. It is the same unit
 * `vendor/bridge/editing.ts` works in and the same unit a `Y.Text` index is, so nothing has to
 * be converted on this side of the seam; the conversion from Neovim's byte positions happens in
 * Lua, where the bytes are.
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
  | {
      type: 'host';
      serverUrl: string;
      displayName?: string;
      autoSave?: boolean;
      root?: string;
      /**
       * The wire version this room is pinned to, or absent for a front-end that has pinned
       * nothing. A pin is deliberate and outranks the server: `selvage/1` hosts a room the server
       * can read, `selvage/2` the encrypted one. Without one the server's `/meta` decides — this
       * process mints `selvage/2` where it is seated, refuses locally rather than falling back to
       * the readable wire where it is not, and attempts it where `/meta` could not be read
       * (`PROTOCOL.md` §2, §10). The front-end's own setting is the pin
       * (`vim.g.selvage_wire_version`); a join never consults either, because it speaks the
       * version the invite link names (§5.1).
       */
      wire?: 'selvage/1' | 'selvage/2';
    }
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
      /**
       * The protocol's own code for a failure the server named (an `error` frame, a refused
       * handshake) — or one of the two refusals this process decides itself. `wire_version_refused`
       * is the version a host asked for that the server's `/meta` does not seat;
       * `invite_refused` is a link whose fragment this client will not read, refused locally
       * before a socket is opened (`PROTOCOL.md` §5.1). Both are absent for a failure nothing
       * named — a socket that never got there.
       *
       * It is the code and not the message that a front-end says a refusal by: the server's message
       * carries the values it refused about, which are not what a person acts on, where a local
       * refusal's message is already the whole sentence and is shown as it stands.
       */
      code?: string;
    }
  /**
   * A `host` or `join` this process did not carry out, because a session is live and ending
   * it is the front-end's to ask about. The room named is the one still standing; nothing
   * about it changed.
   */
  | { type: 'refused'; what: 'host' | 'join'; roomId: string }
  /**
   * A report, `kind` saying which. The bridge's own are passed through unchanged; `role` is this
   * process's own, and says that the room's state has given this connection a different role than
   * the status it was told at the seat (`PROTOCOL.md` §13.4).
   */
  | { type: 'report'; report: unknown }
  /** The remote carets this replica can resolve, in buffer offsets. */
  | { type: 'presence'; cursors: Cursor[] };

/**
 * How many UTF-8 bytes a line may hold before it is dropped rather than accumulated
 * without bound: a whole-document `open` is one JSON line, so a bound below that would
 * refuse real work, while no bound lets one runaway write grow the buffer — and re-scan it
 * per chunk — for the life of the process. Bytes, not code units: stdin is decoded as UTF-8,
 * and a CJK line is three times what `String.length` says. Past it the reader sheds to the
 * next newline and says so once per line, through `onDrop`; what was shed never reaches
 * `onLine`.
 */
export const MAX_IPC_LINE_BYTES = 32 * 1024 * 1024;

/** Reads newline-delimited JSON off a byte stream. */
export class LineReader {
  private buffer = '';
  // The buffer in UTF-8 bytes, not code units: stdin is decoded as UTF-8, so a CJK line
  // is three times what `String.length` says, and the bound has to hold for it too. Counted
  // as chunks land and lines leave, never re-scanned whole.
  private bufferBytes = 0;
  private readonly onLine: (line: string) => void;
  private readonly onDrop: (bytes: number) => void;
  /** Whether the reader is shedding an overlong line, to its newline. */
  private dropping = false;

  constructor(onLine: (line: string) => void, onDrop: (bytes: number) => void = () => undefined) {
    this.onLine = onLine;
    this.onDrop = onDrop;
  }

  /**
   * A chunk boundary is not a line boundary: a decoder that assumed it would split a
   * multi-byte character in half, so the text is accumulated and only whole lines handed on.
   */
  push(chunk: string): void {
    this.buffer += chunk;
    // Past the bound with no newline in sight, the line is shed rather than kept, said the
    // first time it sheds; a shed tail that runs past it again goes in silence.
    this.bufferBytes += Buffer.byteLength(chunk, 'utf8');
    if (this.bufferBytes > MAX_IPC_LINE_BYTES && !this.buffer.includes('\n')) {
      if (!this.dropping) {
        this.dropping = true;
        this.onDrop(this.bufferBytes);
      }
      this.buffer = '';
      this.bufferBytes = 0;
      return;
    }
    let newline = this.buffer.indexOf('\n');
    while (newline !== -1) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      // The newline is ASCII, so a line and its terminator leave together.
      const lineBytes = Buffer.byteLength(line, 'utf8');
      this.bufferBytes -= lineBytes + 1;
      if (this.dropping) {
        // The newline the shed line ended at: shedding ends with it, and the tail with it.
        this.dropping = false;
      } else if (lineBytes > MAX_IPC_LINE_BYTES) {
        // A whole line past the bound, delivered in fewer chunks than it takes to shed:
        // nothing this process answers is that long, so it goes the way a shed one does.
        this.onDrop(lineBytes);
      } else if (line.trim() !== '') {
        this.onLine(line);
      }
      newline = this.buffer.indexOf('\n');
    }
  }
}

/**
 * Whether a parsed line is a request this process answers. The front-end is the same user's
 * own editor, not a remote peer, so a misshapen message is a bug rather than an attack — but
 * one answered blindly is a crash somewhere down the line (`request.serverUrl` read off a
 * `join`, a `change` counted with a start that is a string), where the failure names nothing
 * about the message that caused it. Anything here refuses is said on stderr and dropped
 * before it is queued.
 *
 * The union above is what a front-end may send; anything else — a notification echoed back,
 * a newer front-end's new message, a line that decoded to a bare string — is not one.
 */
export function isRequest(value: unknown): value is Request {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const fields = value as Record<string, unknown>;
  if (typeof fields['type'] !== 'string') {
    return false;
  }
  const text = (name: string): boolean => typeof fields[name] === 'string';
  const count = (name: string): boolean => typeof fields[name] === 'number';
  const flag = (name: string): boolean => typeof fields[name] === 'boolean';
  const maybeText = (name: string): boolean =>
    fields[name] === undefined || typeof fields[name] === 'string';
  const maybeFlag = (name: string): boolean =>
    fields[name] === undefined || typeof fields[name] === 'boolean';
  switch (fields['type']) {
    case 'host':
      return (
        text('serverUrl') &&
        maybeText('displayName') &&
        maybeFlag('autoSave') &&
        maybeText('root') &&
        (fields['wire'] === undefined ||
          fields['wire'] === 'selvage/1' ||
          fields['wire'] === 'selvage/2')
      );
    case 'join':
      return text('invite') && maybeText('displayName') && maybeFlag('autoSave');
    case 'leave':
    case 'selectionCleared':
      return true;
    case 'rename':
      return text('displayName');
    case 'open':
      return text('path') && text('text');
    case 'close':
      return text('path');
    case 'change':
      return text('path') && count('start') && count('end') && text('text');
    case 'applied':
    case 'saved':
      return count('id') && flag('ok');
    case 'selection':
      return text('path') && count('anchor') && count('head');
    default:
      return false;
  }
}
