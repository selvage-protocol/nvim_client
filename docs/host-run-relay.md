# Host-run relay

When this client hosts a room, the relay runs in the host's client. There is no separate
`selvaged` to deploy for a room started here. The relay speaks the same `selvage/2` session
layer: it mints the room and token, assigns `peer_id`, publishes membership events, and
relays sealed binary frames byte for byte.

The invite carries the host's reachable address. Guests join it with the same link they use
today.

## Reaching the host over Tailscale

Install Tailscale on the host and on every guest and join the machines to the same tailnet.
The companion prefers `tailscale ip -4` for the address it puts in the invite. Guests dial that
address over the tailnet, so no router port forward is needed. The relay listens on all local
interfaces, so restrict inbound access with firewall or network rules. The invite address only
says where guests should connect; it does not restrict where the listener answers.

The companion falls back to the first non-internal LAN address, then `127.0.0.1`. It chooses
automatically. A host with Tailscale cannot choose a LAN address for the invite from the command,
and a router port forward does not change that address. Pass an explicit server URL to use a
different relay instead.

## Tailcat without a tailnet

[Tailcat](https://github.com/tailscale/tailcat) carries the relay over WireGuard through DERP and
NAT traversal. The companion relay listens on all interfaces, so restrict inbound access with a
firewall and rate-limit the relay.

Host:

1. Run `:SelvageHost` with no address. Copy the invite URL.
2. Read the port from the invite. In `ws://host:8080/session?…` it is `8080`.
3. Run `tailcat serve 8080` with that port.
4. Send the guest the printed `tc...` address, the port `8080`, and the full invite URL.

The invite ends with a fragment such as `#k=<room-key>&h=<host-key>`. It is part of the URL. The
guest must copy it unchanged.

Guest:

1. Run `tailcat forward <tc-addr> 18080:8080`.
2. Insert `127.0.0.1:18080` in place of the invite's `host:port`. Keep `/session`, the `?room=…&token=…`
   query and the `#k=…&h=…` fragment.
3. Run `:SelvageJoin` with the new URL:

```
ws://127.0.0.1:18080/session?room=<room-id>&token=<token>#k=<room-key>&h=<host-key>
```

Treat the `tc...` address and the invite as one secret.

The invite is still a secret. It now carries the host's reachable address as well as the
room key and the host public key.

## What this changes

The host must stay online. It already had to: only the host writes the room's text to the
working copy, and clients end a session after the host-away window. When the host process
ends, the relay ends with it.

Nothing on the wire changes. Signatures, counters, roles, holds, awareness and CRDT sync
are peer-side facts and behave exactly as they did with a standalone relay.
