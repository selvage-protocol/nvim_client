-- Selvage for Neovim: the commands, and which buffers a session shares.
--
-- Everything that decides anything about a document is in the companion process
-- (`companion/`, driving the vendored engine and bridge). What is here is which buffer is
-- shared under which room path, and the wiring between the two.
--
-- Each part of that now lives in the module beside this one that owns it: the room's state,
-- the companion's messages, presence, the bar, the mirror, and the commands themselves. This
-- file requires them, in the one order that leaves their load-time work in place, and hands out
-- what `plugin/selvage.lua` and a statusline ask for — `require('selvage').<name>` — as the same
-- functions they have always been. Nothing else belongs here: a rule about a session is the
-- module's, and this file is only where a caller reaches it from.
--
-- A module that does something as it loads rather than when a session starts is required where
-- that work belongs: the bar's is the winbar's click handler.

local bar = require('selvage.bar')
local commands = require('selvage.commands')
local display_name = require('selvage.display_name')
local fetch = require('selvage.fetch')
local follow = require('selvage.follow')

-- The invite's own autocmd, registered as the module loads: the link a host handed on goes back
-- out of the registers before ShaDa writes them (`VimLeavePre`).
require('selvage.invite')

local peers = require('selvage.peers')
local queries = require('selvage.queries')
local server = require('selvage.server')
local share = require('selvage.share')

local M = {}

--- The room's own answers: what this session holds, what the room offers, and where its peers
--- are. Read by the commands, the completion functions and a statusline.
M.documents = queries.documents
M.offered = queries.offered
M.fetchable = queries.fetchable
M.session = queries.session
M.text = queries.text
M.peers = queries.peers

--- Which buffer is shared under which room path, and the room's files coming the other way.
M.open = share.open
M.fetch = fetch.fetch
M.complete_peers = peers.complete_peers

--- The bar's own rows, and going to a participant.
M.room = bar.room
M.list_peers = bar.list_peers
M.statusline = bar.statusline
M.go_to = follow.go_to
M.follow = follow.follow
M.stop_following = follow.stop_following
M.following = follow.following

--- The commands themselves, as `plugin/selvage.lua` registers them.
M.host = commands.host
M.join = commands.join
M.copy_invite = commands.copy_invite
M.leave = commands.leave
M.display_name = display_name.display_name
M.set_display_name = display_name.set_display_name
M.change_server = server.change_server

return M
