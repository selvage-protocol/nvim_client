/**
 * An in-process `selvage/2` room: two real clients, one socket seam, no server and no network.
 *
 * `vendor/engine/relay.ts` dials through a `WebSocketFactory`, so a test can hand a real
 * `RelaySession` — and through it the real bridge, companion and adapter — a socket whose other
 * end is this file. What is implemented here is the part of `PROTOCOL.md` §5 that is the
 * *server's*: `session.hello` and the room a token names, `peer.joined`/`peer.left`, and relaying
 * the binary frames between seats without reading one (payload-opaque, §4.5). The room's own state
 * is the host's, sealed by the real engine, and the frames are the real ones.
 *
 * Nothing above the socket is a stub, which is the point: a test that wants a frame to arrive at a
 * chosen moment pauses a seat (`pause`, `flush`) and lets it go, rather than sleeping and hoping.
 * A guest whose socket is cut is `drop`.
 */

import type { WebSocketFactory, WebSocketLike } from '../../vendor/engine/index.ts';

/** `readyState` values, as the engine's transport reads them. */
const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 3;

/** `PROTOCOL.md`'s endpoint path, which every dialled URL carries. */
const ENDPOINT = '/session';

const WIRE_VERSION = 'selvage/2';

/** What a server advertises when the client brings no keepalive of its own (`§8.2`). */
const KEEPALIVE = {
  ping_interval_ms: 30_000,
  awareness_renew_ms: 15_000,
  awareness_expire_ms: 30_000,
};

type Frame = { text: string } | { bytes: Uint8Array };

interface RoomState {
  readonly id: string;
  readonly token: string;
  readonly seats: Seat[];
}

interface Seat {
  readonly id: string;
  displayName: string;
  awarenessId: number | undefined;
  /** The room this connection named in its URL, until a hello seats it in one. */
  named: { room: string | undefined; token: string | undefined };
  room: RoomState | undefined;
  readonly socket: RoomSocket;
  open: boolean;
  paused: boolean;
  /** Binary frames from this seat that never arrive: a socket that loses them. */
  losing: number;
  readonly queued: Frame[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function textOf(value: unknown, key: string): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const field = value[key];
  return typeof field === 'string' ? field : undefined;
}

/** `PROTOCOL.md` §5's bound, which the handshake and a `session.rename` share. */
const DISPLAY_NAME_MAX_UTF16 = 32;

/** Whether `text` carries a control character: C0, DEL or C1, the Unicode `Cc` range (`§5`). */
function hasControlCharacters(text: string): boolean {
  for (const symbol of text) {
    const point = symbol.codePointAt(0) ?? 0;
    if (point < 0x20 || (point >= 0x7f && point <= 0x9f)) {
      return true;
    }
  }
  return false;
}

/**
 * What `session.rename`'s name is refused behind, as `§5` states the bound: a name that carries a
 * control character, a blank one once trimmed, or one over the bound the handshake shares. The
 * trimming is the server's own act — an accepted name is the name it carries — and so is the
 * order of the refusals, control first, so the words match the server's.
 */
function renameRefusal(raw: string, name: string): { code: string; message: string } | undefined {
  if (hasControlCharacters(raw)) {
    return { code: 'bad_params', message: 'display_name contains control characters' };
  }
  if (name === '') {
    return { code: 'bad_params', message: 'a display_name is required' };
  }
  if (name.length > DISPLAY_NAME_MAX_UTF16) {
    return {
      code: 'bad_params',
      message: `display_name is longer than ${DISPLAY_NAME_MAX_UTF16} UTF-16 code units`,
    };
  }
  return undefined;
}

/** The one socket implementation: what the client writes reaches the room, and nothing else. */
class RoomSocket implements WebSocketLike {
  readyState = CONNECTING;
  binaryType = 'arraybuffer';
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: ((event: { code?: number; reason?: unknown }) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;

  private readonly room: InProcessRoom;
  private seat: Seat | undefined;

  constructor(room: InProcessRoom) {
    this.room = room;
  }

  /** The seat this socket is the other end of. Set once the seat exists. */
  attach(seat: Seat): void {
    this.seat = seat;
  }

  private seated(): Seat {
    if (this.seat === undefined) {
      throw new Error('the socket has no seat');
    }
    return this.seat;
  }

  /** The other end came up. Called by the room, never by the client. */
  open(): void {
    if (this.readyState !== CONNECTING) {
      return;
    }
    this.readyState = OPEN;
    this.onopen?.();
  }

  /** One server-to-client frame. */
  deliver(frame: Frame): void {
    this.onmessage?.({ data: 'text' in frame ? frame.text : frame.bytes });
  }

  /** The socket ended: a close the room decided, or the client's own `close`. */
  ended(code: number, reason: string): void {
    if (this.readyState === CLOSED) {
      return;
    }
    this.readyState = CLOSED;
    this.onclose?.({ code, reason });
  }

  send(data: string | Uint8Array): void {
    if (this.readyState !== OPEN) {
      return;
    }
    if (typeof data === 'string') {
      this.room.fromClientText(this.seated(), data);
      return;
    }
    this.room.fromClientBinary(this.seated(), data);
  }

  close(code?: number, reason?: string): void {
    this.room.disconnect(this.seated(), code ?? 1000, reason ?? '');
  }
}

export class InProcessRoom {
  private readonly rooms: RoomState[] = [];
  private readonly seats: Seat[] = [];
  private seated = 0;
  private stopped = false;

  /** The factory a session under test dials with. */
  readonly factory: WebSocketFactory = (url: string): WebSocketLike => this.dial(url);

  /** The seats that are seated and open right now, in the order they were seated. */
  openSeats(): string[] {
    return this.seats.filter((seat) => seat.open).map((seat) => seat.id);
  }

  /**
   * Queues everything this seat is sent until {@link flush}.
   *
   * A handshake whose reply is withheld is what makes an UNKNOWN role a state a test can stand in
   * for as long as it needs: the frames are the real ones, and they are delivered in order when
   * the test says so.
   */
  pause(seat: string): void {
    this.seatOf(seat).paused = true;
  }

  /** Delivers everything a paused seat was sent, in the order it was sent. */
  flush(seat: string): void {
    const found = this.seatOf(seat);
    found.paused = false;
    const queued = found.queued.splice(0, found.queued.length);
    for (const frame of queued) {
      found.socket.deliver(frame);
    }
  }

  /**
   * The next `count` binary frames from this seat never arrive, until the seat goes.
   *
   * A frame lost on a closing socket is what `PROTOCOL.md` §13.1's reciprocal request exists for
   * (NOTES.md §B.48): the receiver keeps what depended on it pending, no refusal follows, and only
   * a later request carries the history back. The count is spent by frames of every kind, because
   * a room does not read one (`DESIGN.md` §4.5); what a test means by it is "whatever this
   * connection sent before its socket went", and {@link drop} ends the allowance with the socket.
   */
  lose(seat: string, count = 1): void {
    this.seatOf(seat).losing += count;
  }

  /** Cuts one seat's socket the way a network does: no close frame, and no goodbye. */
  drop(seat: string): void {
    this.disconnect(this.seatOf(seat), 1006, '');
  }

  /** Ends every open socket. The end of a test's room. */
  stop(): void {
    this.stopped = true;
    for (const seat of this.seats) {
      if (seat.open) {
        seat.open = false;
        seat.socket.ended(1000, '');
      }
    }
  }

  // --- the room's own side -----------------------------------------------------

  private seatOf(id: string): Seat {
    const found = this.seats.find((seat) => seat.id === id && seat.open);
    if (found === undefined) {
      throw new Error(`no such open seat: ${id}`);
    }
    return found;
  }

  private dial(url: string): WebSocketLike {
    if (this.stopped) {
      throw new Error('the room is stopped');
    }
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new Error(`not an address: ${url}`);
    }
    if (!parsed.pathname.endsWith(ENDPOINT)) {
      throw new Error(`${url} does not address ${ENDPOINT}`);
    }
    this.seated += 1;
    // The socket and the seat name each other, so one is built and attached to the other.
    const socket = new RoomSocket(this);
    const seat: Seat = {
      id: `p-${this.seated}`,
      displayName: '',
      awarenessId: undefined,
      named: {
        room: parsed.searchParams.get('room') ?? undefined,
        token: parsed.searchParams.get('token') ?? undefined,
      },
      room: undefined,
      socket,
      open: false,
      paused: false,
      losing: 0,
      queued: [],
    };
    socket.attach(seat);
    this.seats.push(seat);
    // A socket comes up on a later turn, as a real one does: the client sets its handlers after
    // the factory returned, and an `onopen` from inside the call would reach none of them.
    setImmediate(() => {
      if (this.stopped) {
        return;
      }
      seat.open = true;
      socket.open();
    });
    return socket;
  }

  /** A text frame from a client: `session.hello`, `session.rename`, or nothing this room reads. */
  fromClientText(seat: Seat, text: string): void {
    let message: unknown;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    const method = textOf(message, 'method');
    const params = isRecord(message) ? message['params'] : undefined;
    if (method === 'session.hello') {
      this.hello(seat, params);
      return;
    }
    if (method === 'session.rename') {
      const id =
        isRecord(message) && typeof message['id'] === 'number' ? Math.trunc(message['id']) : undefined;
      const raw = textOf(params, 'display_name');
      if (id === undefined) {
        return;
      }
      if (raw === undefined) {
        seat.socket.deliver({
          text: JSON.stringify({
            v: WIRE_VERSION,
            id,
            error: { code: 'bad_params', message: 'the display_name is missing' },
          }),
        });
        return;
      }
      const name = raw.trim();
      const refusal = renameRefusal(raw, name);
      if (refusal !== undefined) {
        seat.socket.deliver({
          text: JSON.stringify({ v: WIRE_VERSION, id, error: refusal }),
        });
        return;
      }
      seat.displayName = name;
      // The reply is the request's own answer (`§4.2`): the relay resolves the method on it.
      seat.socket.deliver({ text: JSON.stringify({ v: WIRE_VERSION, id, result: {} }) });
      // The mover included: the relay takes the room's own word for the name it now has, and a
      // re-hello carries the name this event set (`PROTOCOL.md` §5).
      this.announce({
        text: JSON.stringify({
          v: WIRE_VERSION,
          event: 'peer.renamed',
          params: { peer_id: seat.id, display_name: name },
        }),
      }, seat.room);
      return;
    }
    // Every other method belongs to a version this room does not speak. The real server answers
    // `unknown_method`; no client here sends one, so saying nothing is the whole of it.
  }

  /** A binary frame: the room's own job, and nobody's to read (`DESIGN.md` §4.5). */
  fromClientBinary(seat: Seat, bytes: Uint8Array): void {
    if (seat.room === undefined || !seat.open) {
      return;
    }
    if (seat.losing > 0) {
      seat.losing -= 1;
      return;
    }
    this.broadcast(seat, { bytes: Uint8Array.from(bytes) });
  }

  /**
   * A closed socket: the seat goes, and the room says so to the rest.
   *
   * The socket's own `close` reaches it here, and so do {@link drop} and {@link stop}: one path
   * for every way a connection ends, so nothing ends without the room hearing of it.
   */
  disconnect(seat: Seat, code: number, reason: string): void {
    const was = seat.open;
    seat.open = false;
    // The frames a closing socket was holding are gone with it: the loss ends where the
    // connection does, so a re-seat's own frames are not the ones a test meant to lose.
    seat.losing = 0;
    if (was && seat.room !== undefined) {
      this.broadcast(seat, {
        text: JSON.stringify({
          v: WIRE_VERSION,
          event: 'peer.left',
          params: { peer_id: seat.id },
        }),
      });
    }
    seat.socket.ended(code, reason);
  }

  /**
   * `session.hello`: the room the URL named, or a room minted for it, and the seats already in it.
   *
   * A room is created by the first hello that names none — the host's own mint — and the token it
   * is handed is what a join's URL carries back (`§5.1`). A join whose room or token does not
   * match is refused the way the real server refuses it, with `session.error` and the closing
   * number for that refusal (§11).
   */
  private hello(seat: Seat, params: unknown): void {
    const name = textOf(params, 'display_name') ?? '';
    const awareness = isRecord(params) ? params['awareness_client_id'] : undefined;
    if (typeof awareness !== 'number' || !Number.isInteger(awareness) || awareness < 0) {
      this.refuse(seat, 'bad_params', 'awareness_client_id');
      return;
    }
    seat.displayName = name;
    seat.awarenessId = awareness;
    let room: RoomState | undefined;
    if (seat.named.room === undefined) {
      room = { id: `r-${this.rooms.length + 1}`, token: `t-${this.rooms.length + 1}`, seats: [] };
      this.rooms.push(room);
    } else {
      room = this.rooms.find((candidate) => candidate.id === seat.named.room);
      if (room === undefined) {
        this.refuse(seat, 'room_unknown', `no such room: ${seat.named.room}`);
        return;
      }
      if (seat.named.token !== room.token) {
        this.refuse(seat, 'token_invalid', 'the invite token is not this room\'s');
        return;
      }
    }
    seat.room = room;
    const peers = room.seats
      .filter((other) => other.open)
      .map((other) => ({
        peer_id: other.id,
        display_name: other.displayName,
        ...(other.awarenessId === undefined ? {} : { awareness_client_id: other.awarenessId }),
      }));
    const created = seat.named.room === undefined;
    room.seats.push(seat);
    seat.socket.deliver({
      text: JSON.stringify({
        v: WIRE_VERSION,
        id: 1,
        event: created ? 'room.created' : 'room.joined',
        params: {
          room_id: room.id,
          token: room.token,
          self: { peer_id: seat.id, display_name: name },
          peers,
          keepalive: { ...KEEPALIVE },
          capabilities: [],
        },
      }),
    });
    this.broadcast(seat, {
      text: JSON.stringify({
        v: WIRE_VERSION,
        event: 'peer.joined',
        params: {
          peer: {
            peer_id: seat.id,
            display_name: name,
            awareness_client_id: seat.awarenessId,
          },
        },
      }),
    });
  }

  /** §11's refusal: the code, and the closing number that goes with it. */
  private refuse(seat: Seat, code: string, message: string): void {
    seat.socket.deliver({
      text: JSON.stringify({
        v: WIRE_VERSION,
        event: 'session.error',
        params: { code, message },
      }),
    });
    this.disconnect(seat, closeCodeOf(code), '');
  }

  /** One frame to every open seat of a room, the sender among them. */
  private announce(frame: Frame, room: RoomState | undefined): void {
    if (room === undefined) {
      return;
    }
    for (const seat of room.seats) {
      if (!seat.open) {
        continue;
      }
      this.toSeat(seat, frame);
    }
  }

  /** One frame to one seat, queued when the seat is paused. */
  private toSeat(seat: Seat, frame: Frame): void {
    if (seat.paused) {
      seat.queued.push(frame);
      return;
    }
    seat.socket.deliver(frame);
  }

  private broadcast(from: Seat, frame: Frame): void {
    const room = from.room;
    if (room === undefined) {
      return;
    }
    for (const seat of room.seats) {
      if (seat === from || !seat.open) {
        continue;
      }
      this.toSeat(seat, frame);
    }
  }
}

/** §11's closing number for a refusal, for the one refusal a room here can decide. */
function closeCodeOf(code: string): number {
  if (code === 'room_unknown') {
    return 4001;
  }
  if (code === 'token_invalid') {
    return 4002;
  }
  if (code === 'room_gone') {
    return 4003;
  }
  return 4000;
}
