/**
 * What the front-end draws about the room and says about it, worked out here from the bridge's
 * shared words and colours so that Neovim, VS Code and the web page agree by construction.
 *
 * Lua receives the results as data: the seats with their colours and roster labels on every
 * `peers` report, the rendered sentences on the reports that need one, and the fixed words once
 * as a `words` notification when this process starts.
 */

import {
  COPIED_LABEL,
  COPIED_STAND_MS,
  COPY_INVITE_LABEL,
  HOST_LEAVE_QUESTION,
  LEAVE_ASKING_LABEL,
  LEAVE_CANCEL_LABEL,
  SHARED_SESSION_IDENTITY,
  disconnectingReading,
  followEndedByFileGone,
  followEndedByLeaving,
  followEndedByMoving,
  followEndedByTyping,
  guestIdentity,
  hostLeftSentence,
  hostingIdentity,
  initials,
  peerColour,
  rosterLabel,
  seatColours,
} from '../vendor/bridge/index.ts';
import type { PeerInfo } from '../vendor/engine/index.ts';

/** One person in the room as the front-end draws them. */
export interface SeatView extends PeerInfo {
  /** The name the roster shows: the display name, told apart from a namesake's. */
  roster: string;
  initials: string;
  /** The seat colour, or the peer's own colour past the palette's thirteen seats. */
  colour: string;
}

/** The label a peer is known by: the display name, or the peer id when it has none. */
function nameOf(peer: PeerInfo): string {
  return peer.display_name === '' ? peer.peer_id : peer.display_name;
}

/**
 * Everyone in the room with their seat: the host first, then this connection's own seat, then
 * the others in the order the room lists them, which is the order the web page draws its faces.
 */
export function seatViews(
  self: PeerInfo | undefined,
  others: readonly PeerInfo[],
): { self: SeatView | undefined; peers: SeatView[] } {
  const everyone = self === undefined ? [...others] : [self, ...others];
  const colours = seatColours(everyone.map((peer) => ({ peerId: peer.peer_id, role: peer.role })));
  const named = everyone.map((peer) => ({ displayName: nameOf(peer), peerId: peer.peer_id }));
  const view = (peer: PeerInfo): SeatView => ({
    ...peer,
    roster: rosterLabel({ displayName: nameOf(peer), peerId: peer.peer_id }, named),
    initials: initials(nameOf(peer)),
    colour: colours.get(peer.peer_id) ?? peerColour(peer.peer_id),
  });
  return { self: self === undefined ? undefined : view(self), peers: others.map(view) };
}

/** The identity the session bar opens with. A host sharing no named folder is in a shared session, as in VS Code. */
export function identity(role: string, folder: string | undefined, hostName: string | undefined): string {
  if (role === 'host') {
    return folder === undefined || folder === '' ? SHARED_SESSION_IDENTITY : hostingIdentity(folder);
  }
  return guestIdentity(hostName === undefined || hostName === '' ? undefined : hostName);
}

/** The session bar's line while the host is away: who left, and how long the room has left. */
export function hostAwayLine(name: string, graceMs: number, remainingMs: number): string {
  return `${hostLeftSentence(name)} · Disconnecting in ${disconnectingReading(graceMs, remainingMs)}`;
}

/** Where a name goes in a sentence the front-end fills with Lua's `string.format`. */
const HOLE = '\u{E000}';

function template(sentence: (name: string) => string): string {
  return sentence(HOLE).replaceAll('%', '%%').replace(HOLE, '%s');
}

/**
 * The clause of the web page's leave question that is not true in Neovim: the host's own buffers
 * hold every keystroke, and the file is theirs to write, so nothing typed stops short of the folder.
 */
const KEYSTROKES_CLAUSE = ', and your last few keystrokes may not reach your folder.';

export function hostLeaveQuestion(): string {
  if (!HOST_LEAVE_QUESTION.endsWith(KEYSTROKES_CLAUSE)) {
    return HOST_LEAVE_QUESTION;
  }
  return `${HOST_LEAVE_QUESTION.slice(0, -KEYSTROKES_CLAUSE.length)}.`;
}

/** The fixed words, sent once. A `%s` in a sentence is where the front-end puts a name. */
export function words(): Record<string, unknown> {
  return {
    copyInvite: COPY_INVITE_LABEL,
    copied: COPIED_LABEL,
    copiedMs: COPIED_STAND_MS,
    reconnecting: 'Reconnecting…',
    followEnded: {
      typing: template(followEndedByTyping),
      moving: template(followEndedByMoving),
      leaving: template(followEndedByLeaving),
      fileGone: template(followEndedByFileGone),
    },
    leave: {
      question: hostLeaveQuestion(),
      confirm: LEAVE_ASKING_LABEL,
      cancel: LEAVE_CANCEL_LABEL,
    },
  };
}
