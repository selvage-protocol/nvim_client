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

import type { Notification } from './ipc.ts';

interface Document {
  text: string;
  /**
   * How many changes this document has taken, counted the same way on both sides of the IPC.
   *
   * A remote edit is computed against the mirror and applied to the buffer, and the two are
   * not the same object: an edit the user made in the window between those two moments is a
   * message still in flight, and the range would land on text it was not computed from. The
   * version is what makes that detectable — an `applyEdit` carries the version it was
   * computed against, the front-end refuses one that does not match, and the bridge's own
   * refusal path works the change out again from the mirror the local edit has by then
   * reached. Both sides count a local change and an applied remote edit as one each.
   */
  version: number;
}

interface Pending {
  resolve: (ok: boolean) => void;
}

export interface NvimEditorHostOptions {
  /** Writes one message to the front-end. */
  send: (notification: Notification) => void;
}

export class NvimEditorHost implements EditorHost {
  private readonly documents = new Map<string, Document>();
  private readonly applies = new Map<number, Pending & { path: string; change: TextChange }>();
  private readonly saves = new Map<number, Pending>();
  private nextId = 0;
  private readonly emit: (notification: Notification) => void;

  constructor(options: NvimEditorHostOptions) {
    this.emit = options.send;
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
    return true;
  }

  /** The front-end's answer to an `applyEdit`. */
  settleApply(id: number, ok: boolean): void {
    const pending = this.applies.get(id);
    if (pending === undefined) {
      return;
    }
    this.applies.delete(id);
    const document = this.documents.get(pending.path);
    if (ok && document !== undefined) {
      document.text = applyChange(document.text, pending.change);
      document.version += 1;
    }
    pending.resolve(ok);
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
    const id = (this.nextId += 1);
    return new Promise<boolean>((resolve) => {
      this.applies.set(id, { resolve, path, change });
      this.emit({
        type: 'applyEdit',
        id,
        path,
        start: change.start,
        end: change.end,
        text: change.text,
        version: document.version,
      });
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

  renderCursors(cursors: Cursor[]): void {
    this.emit({ type: 'presence', cursors });
  }

  report(report: Report): void {
    this.emit({ type: 'report', report });
  }
}
