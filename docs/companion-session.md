# The companion's session

`companion/relay.ts` is small on purpose: the socket wiring lives in `vendor/engine/relay.ts`, the
adapter's own vocabulary in `vendor/bridge/peer-engine.ts`, and what is left for this repository is
its own socket (`ws`) and its own listing. `companion/session.ts` drives it through the
`EngineFactory` seam, and the crypto seam is the engine's default, WebCrypto: Node 22.18 has it
globally, so this repository carries no Node-only crypto of its own.

What a person does:

- `:SelvageHost <address>` mints the room on that server, with the folder this window is in as the
  room's listing. The address, the folder and the invite are otherwise unchanged.
- A join is pasting the link. The invite carries the room key and the host key on its fragment, and
  a room seats no connection that cannot read them, so the link is what a join is: a link without a
  fragment is refused locally, before a socket is opened.
- Copying the invite is unchanged: the page link this client hands on is the same room, token and
  two keys as the connection's own wire invite.
- Everything else is the same code over the same bridge: `:SelvageOpen`, the mirror,
  `:SelvageFetch`, `:SelvagePeers`, follow and cursors.

## A viewer's editor is read-only

The room's state assigns roles (`§13.4`), and a connection seated as `viewer` gets the room's
documents with `modifiable` off: `§13.9` has a viewer publish no content, so a buffer that accepted
a keystroke would show text the room never receives. The role is read where it is used rather than
remembered from the join (the state that commits this connection's key is published after the
seat, so a viewer learns what it is from a report of its own), and what the room itself applies is
written through the flag, because what a viewer receives is not refused. Leaving gives each buffer
back the `modifiable` it had. This client declares no role and is seated as `guest`: what a host
does with the state is a later phase's, and a client that could ask to be a viewer would be
inventing a request the protocol does not have.

## What is not carried

The listing a host publishes is sealed into the room state by its host key, so it is lost when the
process ends; this client runs no resume (`§9.1`), so there is no returning host to continue the
`issued` series from and no `HostStore` is written. §13.11's per-receiver caps are unimplemented, as
they are in the reference client.
