/**
 * The relay a host runs in its own companion: `/meta` and `/session` on one ephemeral
 * listener, with the session layer's membership and a byte-for-byte binary relay.
 *
 * The wire is the one a standalone server speaks (`selvage/2`). What is here is the
 * minimum a room needs: mint and join with a token, peer ids and membership events,
 * relayed frames, the frame and peer bounds, the keepalive and the room's grace. Sealed
 * payloads are never decoded.
 */

import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { isIP } from 'node:net';
import { networkInterfaces } from 'node:os';
import type { Duplex } from 'node:stream';

import { WebSocket, WebSocketServer, type RawData } from 'ws';

const WIRE = 'selvage/2';
const CAPABILITIES = ['y-protocols/1', 'awareness'];
const KEEPALIVE = {
  ping_interval_ms: 30000,
  awareness_renew_ms: 15000,
  awareness_expire_ms: 30000,
};
const ROOM_GRACE_MS = 30000;
const PING_INTERVAL_MS = 30000;
/** How many ping intervals may pass unanswered before the connection is dropped. */
const MISSED_PINGS = 2;
const MAX_PEERS_PER_ROOM = 128;
const MAX_FRAME_BYTES = 8 * 1024 * 1024;
const MAX_DISPLAY_NAME = 32;

const CONTROL_CHARACTER = /[\u0000-\u001f\u007f-\u009f]/;

export interface HostRelayOptions {
  /** The address the invite carries. Defaults to Tailscale, then the first non-internal IPv4. */
  advertiseHost?: string;
  /** The listener's port. Zero asks the OS for one. */
  port?: number;
}

export interface HostRelay {
  baseUrl: string;
  stop(): Promise<void>;
}

interface PeerInfo {
  peer_id: string;
  display_name: string;
  awareness_client_id?: number;
}

interface Peer {
  id: string;
  name: string;
  awareness: number | undefined;
  socket: WebSocket;
  room: Room;
  alive: boolean;
  missed: number;
  removed: boolean;
}

interface Room {
  id: string;
  token: string;
  peers: Map<string, Peer>;
  grace: NodeJS.Timeout | undefined;
}

interface Connection {
  socket: WebSocket;
  room: string | undefined;
  token: string | undefined;
  peer: Peer | undefined;
  ping: NodeJS.Timeout | undefined;
}

interface Envelope {
  id?: unknown;
  method?: unknown;
  params?: unknown;
  v?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function infoOf(peer: Peer): PeerInfo {
  return {
    peer_id: peer.id,
    display_name: peer.name,
    ...(peer.awareness === undefined ? {} : { awareness_client_id: peer.awareness }),
  };
}

function sendJson(socket: WebSocket, payload: unknown): void {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

function event(socket: WebSocket, name: string, params: unknown): void {
  sendJson(socket, { v: WIRE, event: name, params });
}

function response(socket: WebSocket, id: unknown, result: unknown): void {
  sendJson(socket, { v: WIRE, id, result });
}

function errorResponse(socket: WebSocket, id: unknown, code: string, message: string): void {
  sendJson(socket, { v: WIRE, id, error: { code, message } });
}

/** A fault before seating: the event, then the close the code names. */
function refusal(socket: WebSocket, code: string, message: string, close: number): void {
  event(socket, 'session.error', { code, message });
  socket.close(close, message.slice(0, 123));
}

function displayName(params: unknown): string | undefined {
  if (!isRecord(params) || typeof params['display_name'] !== 'string') {
    return undefined;
  }
  const name = params['display_name'].trim();
  if (name === '' || name.length > MAX_DISPLAY_NAME || CONTROL_CHARACTER.test(name)) {
    return undefined;
  }
  return name;
}

function awarenessOf(params: Record<string, unknown>): number | undefined {
  const id = params['awareness_client_id'];
  return typeof id === 'number' && Number.isFinite(id) ? id : undefined;
}

function frameBytes(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) {
    return data;
  }
  if (Array.isArray(data)) {
    return Buffer.concat(data);
  }
  return Buffer.from(data);
}

function readPort(server: Server): number {
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('the host relay has no port');
  }
  return address.port;
}

/**
 * The host's reachable address: Tailscale's IPv4 when it is installed, else the first
 * non-internal IPv4 this machine has, else loopback.
 */
async function advertisedHost(): Promise<string> {
  const tailscale = await new Promise<string | undefined>((resolve) => {
    execFile('tailscale', ['ip', '-4'], { timeout: 1000 }, (error, stdout) => {
      if (error !== null) {
        resolve(undefined);
        return;
      }
      const first = stdout
        .split('\n')
        .map((line) => line.trim())
        .find((line) => line !== '');
      resolve(first !== undefined && isIP(first) === 4 ? first : undefined);
    });
  });
  if (tailscale !== undefined) {
    return tailscale;
  }
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (!entry.internal && entry.family === 'IPv4') {
        return entry.address;
      }
    }
  }
  return '127.0.0.1';
}

/**
 * Starts the host's relay on an ephemeral port, all interfaces. The returned base URL is
 * what a host mints on and what the invite carries.
 */
export async function startHostRelay(options: HostRelayOptions = {}): Promise<HostRelay> {
  const rooms = new Map<string, Room>();
  const connections = new Map<WebSocket, Connection>();
  const sockets = new Set<WebSocket>();
  let stopping = false;

  const server = createServer((request: IncomingMessage, reply: ServerResponse) => {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (request.method !== 'GET' || url.pathname !== '/meta') {
      reply.writeHead(404, { 'content-type': 'application/json' });
      reply.end('{"error":"not found"}');
      return;
    }
    reply.writeHead(200, {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    });
    reply.end(
      JSON.stringify({
        server: 'selvage-nvim-host/1',
        wire_versions: [WIRE],
        capabilities: CAPABILITIES,
        keepalive: { ...KEEPALIVE, room_grace_ms: ROOM_GRACE_MS },
      }),
    );
  });

  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_FRAME_BYTES,
    perMessageDeflate: false,
  });

  function broadcast(room: Room, payload: unknown, except?: string): void {
    for (const peer of room.peers.values()) {
      if (peer.id !== except) {
        sendJson(peer.socket, payload);
      }
    }
  }

  function mintRoom(): Room {
    let id = '';
    do {
      id = `r-${randomBytes(6).toString('hex')}`;
    } while (rooms.has(id));
    const room: Room = {
      id,
      token: randomBytes(16).toString('hex'),
      peers: new Map(),
      grace: undefined,
    };
    rooms.set(id, room);
    return room;
  }

  function mintPeerId(room: Room): string {
    let id = '';
    do {
      id = `p-${randomBytes(8).toString('hex')}`;
    } while (room.peers.has(id));
    return id;
  }

  function armGrace(room: Room): void {
    if (room.grace !== undefined) {
      clearTimeout(room.grace);
    }
    room.grace = setTimeout(() => {
      room.grace = undefined;
      if (room.peers.size === 0 && rooms.get(room.id) === room) {
        rooms.delete(room.id);
      }
    }, ROOM_GRACE_MS);
    room.grace.unref();
  }

  function disconnect(connection: Connection): void {
    if (connection.ping !== undefined) {
      clearInterval(connection.ping);
      connection.ping = undefined;
    }
    const peer = connection.peer;
    connection.peer = undefined;
    if (peer === undefined || peer.removed) {
      return;
    }
    peer.removed = true;
    const room = peer.room;
    room.peers.delete(peer.id);
    if (stopping) {
      return;
    }
    broadcast(room, { v: WIRE, event: 'peer.left', params: { peer_id: peer.id } });
    if (room.peers.size === 0) {
      armGrace(room);
    }
  }

  function relay(peer: Peer, frame: Buffer): void {
    for (const other of peer.room.peers.values()) {
      if (other.id !== peer.id && other.socket.readyState === WebSocket.OPEN) {
        other.socket.send(frame, { binary: true });
      }
    }
  }

  function hello(connection: Connection, text: string): void {
    const socket = connection.socket;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      refusal(socket, 'bad_message', 'the first frame is not a session envelope', 4000);
      return;
    }
    const envelope = isRecord(parsed) ? (parsed as Envelope) : undefined;
    if (
      envelope === undefined ||
      typeof envelope.id !== 'number' ||
      !Number.isFinite(envelope.id)
    ) {
      refusal(socket, 'bad_message', 'a request needs an id', 4000);
      return;
    }
    if (envelope.v !== WIRE) {
      refusal(socket, 'bad_message', 'a frame this relay cannot read names another version', 4000);
      return;
    }
    if (envelope.method !== 'session.hello') {
      refusal(socket, 'hello_required', 'the first method must be session.hello', 4000);
      return;
    }
    const params = isRecord(envelope.params) ? envelope.params : undefined;
    if (params === undefined || typeof params['display_name'] !== 'string') {
      refusal(socket, 'bad_message', 'session.hello needs params with a display_name', 4000);
      return;
    }
    const name = displayName(params);
    if (name === undefined) {
      refusal(socket, 'bad_params', 'a display_name is required and at most 32 characters', 4000);
      return;
    }

    let room: Room;
    let minted = false;
    if (connection.room === undefined) {
      room = mintRoom();
      minted = true;
    } else {
      const found = rooms.get(connection.room);
      if (found === undefined) {
        refusal(socket, 'room_unknown', `no such room: ${connection.room}`, 4001);
        return;
      }
      if (connection.token === undefined || connection.token !== found.token) {
        refusal(socket, 'token_invalid', 'invalid room token', 4002);
        return;
      }
      if (found.peers.size >= MAX_PEERS_PER_ROOM) {
        refusal(socket, 'x.room_full', 'the room seats no more peers', 4000);
        return;
      }
      room = found;
    }

    if (room.grace !== undefined) {
      clearTimeout(room.grace);
      room.grace = undefined;
    }
    const peers = [...room.peers.values()].map(infoOf);
    const peer: Peer = {
      id: mintPeerId(room),
      name,
      awareness: awarenessOf(params),
      socket,
      room,
      alive: true,
      missed: 0,
      removed: false,
    };
    room.peers.set(peer.id, peer);
    connection.peer = peer;

    const reply = {
      v: WIRE,
      event: minted ? 'room.created' : 'room.joined',
      params: {
        room_id: room.id,
        ...(minted ? { token: room.token } : {}),
        self: infoOf(peer),
        peers,
        capabilities: CAPABILITIES,
        keepalive: KEEPALIVE,
      },
    };
    sendJson(socket, reply);
    if (!minted) {
      broadcast(room, { v: WIRE, event: 'peer.joined', params: { peer: infoOf(peer) } }, peer.id);
    }
  }

  function rename(connection: Connection, id: unknown, params: unknown): void {
    const peer = connection.peer;
    if (peer === undefined) {
      return;
    }
    const name = displayName(params);
    if (name === undefined) {
      errorResponse(connection.socket, id, 'bad_params', 'a display_name is required and at most 32 characters');
      return;
    }
    peer.name = name;
    response(connection.socket, id, {});
    broadcast(peer.room, {
      v: WIRE,
      event: 'peer.renamed',
      params: { peer_id: peer.id, display_name: name },
    });
  }

  function seated(connection: Connection, text: string): void {
    const socket = connection.socket;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      event(socket, 'session.error', { code: 'bad_message', message: 'not a session envelope' });
      return;
    }
    const envelope = isRecord(parsed) ? (parsed as Envelope) : undefined;
    if (
      envelope === undefined ||
      typeof envelope.id !== 'number' ||
      !Number.isFinite(envelope.id)
    ) {
      event(socket, 'session.error', { code: 'bad_message', message: 'a request needs an id' });
      return;
    }
    if (envelope.v !== WIRE) {
      event(socket, 'session.error', {
        code: 'bad_message',
        message: 'a frame this relay cannot read names another version',
      });
      return;
    }
    if (typeof envelope.method !== 'string') {
      event(socket, 'session.error', { code: 'bad_message', message: 'a request needs a method' });
      return;
    }
    switch (envelope.method) {
      case 'session.hello':
        errorResponse(socket, envelope.id, 'already_seated', 'this connection already completed the handshake');
        return;
      case 'session.rename':
        rename(connection, envelope.id, envelope.params);
        return;
      default:
        errorResponse(socket, envelope.id, 'unknown_method', `no such method: ${envelope.method}`);
    }
  }

  wss.on('connection', (socket: WebSocket, request: IncomingMessage) => {
    sockets.add(socket);
    const url = new URL(request.url ?? '/session', 'http://localhost');
    const roomValues = url.searchParams.getAll('room');
    const tokenValues = url.searchParams.getAll('token');
    const connection: Connection = {
      socket,
      room: roomValues.length === 1 ? roomValues[0] : undefined,
      token: tokenValues.length === 1 ? tokenValues[0] : undefined,
      peer: undefined,
      ping: undefined,
    };
    connections.set(socket, connection);

    if (roomValues.length > 1 || tokenValues.length > 1) {
      refusal(socket, 'token_invalid', 'the URL repeats room or token', 4002);
      return;
    }

    connection.ping = setInterval(() => {
      const peer = connection.peer;
      if (peer === undefined) {
        return;
      }
      if (!peer.alive) {
        peer.missed += 1;
        if (peer.missed >= MISSED_PINGS) {
          socket.terminate();
          return;
        }
      } else {
        peer.missed = 0;
      }
      peer.alive = false;
      socket.ping();
    }, PING_INTERVAL_MS);
    connection.ping.unref();

    socket.on('pong', () => {
      if (connection.peer !== undefined) {
        connection.peer.alive = true;
      }
    });
    socket.on('message', (data: RawData, isBinary: boolean) => {
      if (isBinary) {
        if (connection.peer === undefined) {
          refusal(socket, 'bad_message', 'a binary frame arrived before session.hello', 4000);
          return;
        }
        relay(connection.peer, frameBytes(data));
        return;
      }
      const text = frameBytes(data).toString('utf8');
      if (connection.peer === undefined) {
        hello(connection, text);
      } else {
        seated(connection, text);
      }
    });
    socket.on('close', () => {
      disconnect(connection);
      connections.delete(socket);
      sockets.delete(socket);
    });
    socket.on('error', () => {
      // The close handler is what removes the peer.
    });
  });

  server.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (url.pathname !== '/session') {
      socket.end('HTTP/1.1 404 Not Found\r\nconnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? 0, '0.0.0.0', () => {
      server.off('error', reject);
      resolve();
    });
  });

  const host = options.advertiseHost?.trim() ?? (await advertisedHost());
  const baseUrl = `ws://${host === '' ? '127.0.0.1' : host}:${String(readPort(server))}`;

  return {
    baseUrl,
    async stop(): Promise<void> {
      if (stopping) {
        return;
      }
      stopping = true;
      for (const connection of connections.values()) {
        if (connection.ping !== undefined) {
          clearInterval(connection.ping);
          connection.ping = undefined;
        }
      }
      for (const room of rooms.values()) {
        if (room.grace !== undefined) {
          clearTimeout(room.grace);
          room.grace = undefined;
        }
      }
      rooms.clear();
      for (const socket of sockets) {
        socket.terminate();
      }
      sockets.clear();
      connections.clear();
      await new Promise<void>((resolve) => {
        server.close(() => {
          resolve();
        });
      });
      wss.close();
    },
  };
}
