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

[Tailcat](https://github.com/tailscale/tailcat) needs no Tailscale account or control plane.
The companion relay listens on all interfaces, so restrict inbound access with a firewall. Put a
TLS terminator and rate limit in front of the relay and run `tailcat serve <port>` against that
protected port. Hand the guest the printed `tc...` address and the port. Tailcat addresses are
capabilities. Share them with the same care as the invite.

The guest runs `tailcat forward <tc-addr> 18080:<port>`, then replaces only the invite's host and
port with `127.0.0.1:18080`. Keep the `/session` path, query and fragment as the host sent them.
The port comes from the invite and may change when the relay restarts.

The invite is still a secret. It now carries the host's reachable address as well as the
room key and the host public key.

## What this changes

The host must stay online. It already had to: only the host writes the room's text to the
working copy, and clients end a session after the host-away window. When the host process
ends, the relay ends with it.

Nothing on the wire changes. Signatures, counters, roles, holds, awareness and CRDT sync
are peer-side facts and behave exactly as they did with a standalone relay.
