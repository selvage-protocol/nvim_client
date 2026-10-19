-- What the session holds and what the room offers.
--
-- `documents` is the room paths this session holds, `offered` is the union a command may be given
-- — the grant, the room's open-document set and this session's own documents — and `fetchable` is
-- what a fetch may name, which is the listing the mirror can write. `peers` is the last presence
-- report's rows, ordered as the room seats them. Each of them answers a script, a completion or a
-- command, which is why they live here and not beside the drawing they are built from.
local mirror = require('selvage.mirror')
local state = require('selvage.state').state

local M = {}

--- The room paths this session holds, ordered so that completion and a prompt agree.
function M.documents()
  local paths = vim.tbl_keys(state.documents)
  table.sort(paths)
  return paths
end

--- What the room offers: its grant, the paths the room holds open, and the documents this
--- session holds, ordered as `documents()` is.
---
--- The union is deliberate rather than the grant alone, so a server that has no grant — one
--- older than `doc.grant` — still offers everything the room knows, and a document shared after
--- the listing was published is reachable as well. What this is *not* is a statement of what
--- this session holds. The room's open-document set is a peer's statement about itself
--- (`PROTOCOL.md` §13.7): a path in it with no buffer behind it is offered and openable, and
--- `documents()` is still the answer to which paths this session holds. A path a listing took
--- away is not offered from the room's set again while another peer holds it — `drop_documents`
--- is what takes it away and `state.dropped` is what keeps it away.
function M.offered()
  local seen = {}
  local paths = {}
  local function add(path)
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for _, path in ipairs(state.grant) do
    add(path)
  end
  for path in pairs(state.room_documents) do
    if not state.dropped[path] then
      add(path)
    end
  end
  for _, path in ipairs(M.documents()) do
    add(path)
  end
  table.sort(paths)
  return paths
end

--- The paths the room's listing names, ordered as `offered()` is: what `:SelvageFetch` can be
--- given, and what its completion offers.
---
--- The listing rather than everything the room offers: a document the room holds open that its
--- listing does not name has no file in the mirror, so there is nothing to fetch for it.
function M.fetchable()
  -- Where there is a mirror, what it holds a file for, as `fetch_targets` reads it: a listed path
  -- it refused has nowhere for a fetch to write. A host has no mirror and keeps its whole listing.
  local mirrored = mirror.root() ~= nil
  local paths = {}
  for _, path in ipairs(state.grant) do
    if not mirrored or mirror.granted(path) then
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

--- Where the session stands, for a statusline or a script.
---
--- `mirror` is the directory this session materialises the room into, for a guest whose room
--- listed something, and nil otherwise: it is where a plugin that reads the filesystem has to
--- look, because nothing else tells a person where the room is.
function M.session()
  return {
    status = state.status,
    role = state.role,
    room = state.room,
    invite = state.invite,
    documents = M.documents(),
    mirror = mirror.root(),
  }
end

--- The text of a shared document, as the room holds it.
function M.text(path)
  local document = state.documents[path]
  return document and document:text() or nil
end

--- The peers the last presence report drew, keyed by peer id: the ones whose caret this client
--- can draw, and so the ones the gutter has a sign and a colour for.
local function drawn_by_id()
  local drawn = {}
  for _, peer in ipairs(state.peers) do
    drawn[peer.peerId] = peer
  end
  return drawn
end

--- Every presence entry the last report named, drawn or not, keyed by peer id. `drawn_by_id` is
--- the subset this window holds a buffer for; this is the room's whole word about where people
--- are, which is what a path is read from when no caret could be resolved for a peer here.
local function presence_by_id()
  local said = {}
  for _, cursor in ipairs(state.cursors) do
    if type(cursor) == 'table' and type(cursor.peerId) == 'string' then
      said[cursor.peerId] = cursor
    end
  end
  return said
end

--- The room's participants: every peer the room names, each with what this session knows about
--- it. A peer the room names whose document this client does not hold is listed all the same: the
--- list is the room's, and someone looking for a person here should find them whether or not their
--- caret is on screen. That row carries no `sign`, `highlight` or `colour`, because those are the
--- two cells and the colour the gutter draws — a list that explains the gutter has to agree with
--- it cell for cell, and a peer the gutter drew nothing for has nothing there to explain. Its
--- `path` is still there: a presence entry the companion could not resolve a caret in carries the
--- room's own document for the peer, which is what `:SelvageFollow` and `:SelvageGoTo` open to
--- reach them.
---
--- `label` is the whole display name the two cells abbreviate, or the peer id when the room left
--- the name blank; `path` is the document the peer is in as the room's presence said. `sign` is
--- what the gutter shows, so a reader holding the two cells has one lookup to make, and
--- `highlight` is the very group the caret and the sign are drawn with.
function M.peers()
  local drawn = drawn_by_id()
  local said = presence_by_id()
  local peers = {}
  local named = {}
  for _, peer in ipairs(state.room_peers) do
    local name = tostring(peer.display_name or '')
    local mine = drawn[peer.peer_id]
    local presence = said[peer.peer_id]
    named[peer.peer_id] = true
    peers[#peers + 1] = {
      peerId = peer.peer_id,
      label = name ~= '' and name or tostring(peer.peer_id),
      roster = peer.roster,
      initials = peer.initials,
      seat = peer.colour,
      role = peer.role,
      path = mine and mine.path or (presence and presence.path or nil),
      sign = mine and mine.sign or nil,
      colour = mine and mine.colour or nil,
      highlight = mine and mine.highlight or nil,
    }
  end
  -- A peer the last presence report named and the room has not named: there is no session report
  -- to list them from, and the caret — or the document they are in — is still someone.
  for _, peer in ipairs(state.cursors) do
    if type(peer) == 'table' and type(peer.peerId) == 'string' and not named[peer.peerId] then
      named[peer.peerId] = true
      local mine = drawn[peer.peerId]
      peers[#peers + 1] = {
        peerId = peer.peerId,
        label = peer.label or peer.peerId,
        role = peer.role,
        path = peer.path,
        sign = mine and mine.sign or nil,
        colour = mine and mine.colour or nil,
        highlight = mine and mine.highlight or nil,
      }
    end
  end
  return peers
end



return M
