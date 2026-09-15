/**
 * The editor side of the seam, over the local IPC: Neovim as the bridge sees it.
 *
 * Everything decidable about a document lives in `vendor/bridge/`; what is left here is
 * translation and one mirror. The mirror is the part worth reading: the bridge asks for a
 * document's text synchronously, and the buffer it names is in another process, so this
 * class keeps a copy of every shared buffer and the front-end keeps it in step.
 *
 * A document's text is the buffer's lines joined by `\n` **with a trailing `\n`** — the text
 * Neovim's own byte offsets count, and the text the file on disk holds. Line endings are not
 * this adapter's business: a Neovim buffer holds lines, and `fileformat` turns them into CRLF
 * at write time, so the host always reports `\n` and `vendor/bridge/editing.ts`'s conversion
 * is a no-op here.
 */

import type {
  Cursor,
  EditorHost,
  LineEnding,
  Report,
  TextChange,
} from '../vendor/bridge/index.ts';
import { applyChange } from '../vendor/bridge/index.ts';

import { readGrantedFile } from './grant.ts';
import type { Notification } from './ipc.ts';

interface Document {
  text: string;
  /**
   * How many changes this document has taken, counted the same way on both sides of the IPC.
   *
   * A remote edit is computed against the mirror and applied to the buffer, and the two are
   * not the same object: an edit the user made in the window between those two moments is a
   * message still in flight, and the range would land on text it was not computed from. The
   * version is what makes that detectable — an `applyEdit` carries the version it was computed
   * against and the front-end refuses one that does not match — and it is also what lets the
   * range be moved through the changes in between and offered again. Both sides count a local
   * change and an applied remote edit as one each.
   */
  version: number;
}

interface Pending {
  resolve: (ok: boolean) => void;
}

/**
 * An `applyEdit` this host has asked the front-end for and not yet been answered.
 *
 * The two extra members are what a refusal is read against. `version` is the mirror's version
 * the range was computed against — the version the front-end must still be at for the range to
 * mean what it says — and `withheld` is the local changes the document has taken since, which
 * the front-end counted after the apply was computed and which a refused range has to be moved
 * through. Both are empty for the common case, where the front-end answers `true` and the
 * mirror moves by exactly the change it was asked to apply.
 */
interface Offered extends Pending {
  path: string;
  change: TextChange;
  version: number;
  withheld: TextChange[];
  offered: number;
}

/**
 * How many times a refused range is moved and offered again before the refusal is passed on.
 * Each offer is one IPC round trip. A front-end that refuses without moving the buffer is
 * handed back after one offer, and so is one whose range a local change straddles; the bound is
 * reached only by a buffer that keeps moving under the range, because each movement is what
 * buys the next offer — which is what a user typing through the window supplies. When it is
 * reached the refusal goes to the bridge with the local edit still in the mirror, and the
 * bridge reports the difference before reconciling that text away.
 */
const MAX_REBASED_OFFERS = 3;

/**
 * A change's range as the document now reads, moved through the local changes made after it was
 * computed — in order, each counted against the text the one before it left.
 *
 * A local change the range sits entirely after moves the range by what it did to the text's
 * length; one the range sits entirely before leaves it alone. One the range straddles is not
 * expressible — the peer wrote about the same characters the user did, and there is no position
 * left to put it at — and answers `undefined`, which is the refusal the bridge's own retry is
 * for.
 */
function rebase(change: TextChange, withheld: readonly TextChange[]): TextChange | undefined {
  let start = change.start;
  let end = change.end;
  for (const local of withheld) {
    if (local.end <= start) {
      const moved = local.text.length - (local.end - local.start);
      start += moved;
      end += moved;
      continue;
    }
    if (local.start >= end) {
      continue;
    }
    return undefined;
  }
  return { start, end, text: change.text };
}

export interface NvimEditorHostOptions {
  /** Writes one message to the front-end. */
  send: (notification: Notification) => void;
}

export class NvimEditorHost implements EditorHost {
  private readonly documents = new Map<string, Document>();
  private readonly applies = new Map<number, Offered>();
  private readonly saves = new Map<number, Pending>();
  private nextId = 0;
  private readonly emit: (notification: Notification) => void;
  /**
   * The folder this session shares, or `undefined` when there is none: the root the grant's
   * paths are relative to, and the bound every path a peer names is held inside.
   */
  private folder: string | undefined;

  constructor(options: NvimEditorHostOptions) {
    this.emit = options.send;
  }

  /**
   * Points the host at the folder a session was started in, or at nothing when it ends.
   *
   * It is the front-end's to say: only the editor knows where its user is, and this process's
   * own working directory is the plugin checkout it was started from.
   */
  sharedFolder(root: string | undefined): void {
    this.folder = root;
  }

  // -- from the front-end ----------------------------------------------------

  /** A buffer is now shared under `path`, holding `text`. */
  opened(path: string, text: string): void {
    this.documents.set(path, { text, version: 0 });
  }

  closed(path: string): void {
    this.documents.delete(path);
  }

  /** A local edit. Returns `false` when the path is not one this session shares. */
  changed(path: string, change: TextChange): boolean {
    const document = this.documents.get(path);
    if (document === undefined) {
      return false;
    }
    document.text = applyChange(document.text, change);
    document.version += 1;
    for (const pending of this.applies.values()) {
      if (pending.path === path) {
        pending.withheld.push(change);
      }
    }
    return true;
  }

  /**
   * The front-end's answer to an `applyEdit`.
   *
   * A `false` is not always the end of the edit. The front-end refuses a range whose version
   * has moved on, and what that says is that the range — not the edit — no longer fits: a local
   * change the front-end counted has reached this mirror since the range was computed. The edit
   * is still the one the room wants, so it is offered again moved through those changes, which
   * lands it where the buffer now has the text it was computed from and leaves the local edit
   * where the user put it. Handing the refusal to the bridge instead would let it work the
   * change out again from the mirror, which is the room's text without the local edit, and the
   * user's keystroke would be dropped rather than merged with the peer's.
   *
   * A refusal with no local change behind it — a range that no longer fits for a reason this
   * side cannot see — is passed on unchanged, as the bridge's bounded retry and its
   * `applyRefused` report are for. A range whose local changes overlap it is passed on too:
   * there is no position to move it to, and the bridge reconciles the deferred text away and
   * reports the difference rather than dropping the keystroke in silence.
   */
  settleApply(id: number, ok: boolean): void {
    const pending = this.applies.get(id);
    if (pending === undefined) {
      return;
    }
    this.applies.delete(id);
    const document = this.documents.get(pending.path);
    if (document === undefined) {
      pending.resolve(false);
      return;
    }
    if (ok && document.version === pending.version) {
      document.text = applyChange(document.text, pending.change);
      document.version += 1;
      pending.resolve(true);
      return;
    }
    if (!ok && document.version !== pending.version && pending.offered < MAX_REBASED_OFFERS) {
      const moved = rebase(pending.change, pending.withheld);
      if (moved !== undefined) {
        pending.change = moved;
        pending.version = document.version;
        pending.withheld = [];
        pending.offered += 1;
        this.offer(pending);
        return;
      }
    }
    pending.resolve(false);
  }

  /** The front-end's answer to a `save`. */
  settleSave(id: number, ok: boolean): void {
    const pending = this.saves.get(id);
    if (pending === undefined) {
      return;
    }
    this.saves.delete(id);
    pending.resolve(ok);
  }

  /** Forgets every document and fails every outstanding request: the session is over. */
  reset(): void {
    this.documents.clear();
    this.folder = undefined;
    this.abandon();
  }

  /** Fails every outstanding request; a front-end that has gone away answers nothing. */
  abandon(): void {
    for (const pending of this.applies.values()) {
      pending.resolve(false);
    }
    this.applies.clear();
    for (const pending of this.saves.values()) {
      pending.resolve(false);
    }
    this.saves.clear();
  }

  // -- EditorHost ------------------------------------------------------------

  text(path: string): string | undefined {
    return this.documents.get(path)?.text;
  }

  lineEnding(_path: string): LineEnding {
    return '\n';
  }

  applyChange(path: string, change: TextChange): Promise<boolean> {
    const document = this.documents.get(path);
    if (document === undefined) {
      return Promise.resolve(false);
    }
    return new Promise<boolean>((resolve) => {
      this.offer({
        resolve,
        path,
        change,
        version: document.version,
        withheld: [],
        offered: 0,
      });
    });
  }

  /** Asks the front-end for one range, and keeps the answer addressed to the promise it holds. */
  private offer(pending: Offered): void {
    const id = (this.nextId += 1);
    this.applies.set(id, pending);
    this.emit({
      type: 'applyEdit',
      id,
      path: pending.path,
      start: pending.change.start,
      end: pending.change.end,
      text: pending.change.text,
      version: pending.version,
    });
  }

  save(path: string): Promise<boolean> {
    if (!this.documents.has(path)) {
      return Promise.resolve(true);
    }
    const id = (this.nextId += 1);
    return new Promise<boolean>((resolve) => {
      this.saves.set(id, { resolve });
      this.emit({ type: 'save', id, path });
    });
  }

  /**
   * Reads a file the room asked for, out of the folder this session shares.
   *
   * The path came from a peer and is not trusted, so `companion/grant.ts` holds it to the
   * grant's own rules before a byte is read: it has to be inside the folder, a path the listing
   * itself would publish, and a plain file at every step of the way. A session with no folder
   * — a front-end that did not name one — serves nothing.
   */
  async readGrantedFile(path: string): Promise<string | undefined> {
    const folder = this.folder;
    if (folder === undefined) {
      return undefined;
    }
    return readGrantedFile(folder, path);
  }

  renderCursors(cursors: Cursor[]): void {
    this.emit({ type: 'presence', cursors });
  }

  report(report: Report): void {
    this.emit({ type: 'report', report });
  }
}
