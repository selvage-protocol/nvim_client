# Host-run relay

When this client hosts a room, the relay runs in the host's client. There is no separate
`selvaged` to deploy for a room started here. The relay speaks the same `selvage/2` session
layer: it mints the room and token, assigns `peer_id`, publishes membership events, and
relays sealed binary frames byte for byte.

The invite carries the host's reachable address. Guests join it with the same link they use
today.

## Reaching the host over Tailscale

Install Tailscale on the host and on every guest and join the machines to the same tailnet.
The host client reads `tailscale ip -4` and puts that address in the invite. Guests dial the
invite over the tailnet, so no router port forward and no public address are needed. The
listener stays off the public internet.

A host on the same LAN as its guests can advertise its LAN address instead. A host with a
public address can advertise that directly, with whatever port forward and firewall rules
it chooses.

The invite is still a secret. It now carries the host's reachable address as well as the
room key and the host public key.

## What this changes

The host must stay online. It already had to: only the host writes the room's text to the
working copy, and clients end a session after the host-away window. When the host process
ends, the relay ends with it.

Nothing on the wire changes. Signatures, counters, roles, holds, awareness and CRDT sync
are peer-side facts and behave exactly as they did with a standalone relay.
