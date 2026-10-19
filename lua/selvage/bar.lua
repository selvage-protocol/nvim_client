-- The window's bar: the session's own row, the follow's chip, and ending a follow.
--
-- A window shows one buffer's row at a time, so an indicator saves each buffer's own row as the
-- window arrives at it and puts it back as it leaves; a session with no follow gets its row back
-- the same way. `end_follow` sits here with the row it takes down: a local edit of a shared
-- document ends a follow from inside the change callback `share` installs, and this is the one
-- place the follow has to be reachable from without a module requiring it back.
local api = vim.api

local mirror = require('selvage.mirror')
local cterm = require('selvage.colour').cterm
local peer_highlight = require('selvage.colour').peer_highlight
local peer_sign = require('selvage.colour').peer_sign
local notify = require('selvage.notify').notify
local queries = require('selvage.queries')
local buffer_empty = require('selvage.state').buffer_empty
local document_for_buf = require('selvage.state').document_for_buf
local in_session = require('selvage.state').in_session
local state = require('selvage.state').state

local M = {}

local end_follow
local refresh_indicators

--- The marks the bar draws beside a face, each one cell wide whatever `ambiwidth` says: the host's
--- crown, the face this window follows, and the way to stop following.
local CROWN = '♛'
local FOLLOWED_MARK = '◉'
local STOP_MARK = '✕'

--- The highlight the session's own row is drawn in: the framing that tells its row apart
--- from a person's own, and the name a colorscheme or a person may style. Linked to `Title`
--- and defined with `default`, so anything a colorscheme defines for the name wins; a
--- colorscheme runs `highlight clear`, which is why this is set where the row is drawn rather
--- than once.
local SESSION_HIGHLIGHT = 'SelvageSession'
local SESSION_FRAME = '%#' .. SESSION_HIGHLIGHT .. '#'

--- A name or a sentence as part of one of the indicators' rows. The row is evaluated like a
--- statusline, where `%` starts an item and `%{…}` is a Vimscript expression, and a display name
--- is whatever the peer typed: every `%` in it arrives doubled, so a name reads as itself rather
--- than as the item it spells.
local function row_text(text)
  return tostring(text or ''):gsub('%%', '%%%%')
end

--- The follow's chip: the peer's name and the way to stop, clickable where the editor takes a
--- mouse. The `%0@...@ ... %X` label is what makes a click stop the follow, through the stop
--- command's own handler; a click needs `'mouse'` set, while the command stops the follow
--- regardless.
local function follow_chip(label)
  return ('%%#SelvageFollow#%%0@SelvageStopFollowing@ Following %s %s %%X%%*'):format(row_text(label), STOP_MARK)
end

-- What the bar's click label calls: a Vim function by name. A Lua `_G` function is invisible to
-- that lookup (`exists('*name')` is 0 for one), so this thin wrapper hands the click to the
-- command's own handler. Defined once, when the module loads: with no session the handler only
-- says there is nothing to act on, and no clickable row stands then anyway.
vim.cmd([[function! SelvageStopFollowing(minwid, clicks, button, mods) abort
  call v:lua.require('selvage').stop_following()
endfunction]])

--- Which saved row a window's buffer reads and writes: the window and the buffer together,
--- because that is the granularity the editor swaps them at.
local function winbar_key(win, bufnr)
  return win .. ':' .. bufnr
end

--- Whether a window is a float: a notification, a hover, a completion menu — the editor's own
--- furniture rather than a window showing a document.
---
--- No indicator belongs in one. A float is not a place a person reads the session's rows and it is
--- often shorter than the row itself: the one line a one-line float has is already spoken for, so
--- writing a winbar into one is where Neovim raises `E36: Not enough room`. The host-away row is
--- redrawn by a repeating timer, and Neovim stops a repeating timer after three of its runs raise
--- an error.
local function floating(win)
  local ok, config = pcall(api.nvim_win_get_config, win)
  return ok and config.relative ~= ''
end

--- Sets the bar's own groups. Linked with `default` where a colorscheme may style them; your own
--- face is your seat's colour, so it is set again when that moves.
local function paint_bar()
  local you = state.self_seat ~= nil and tostring(state.self_seat.colour or '#888888') or '#888888'
  if state.session_painted == you then
    return
  end
  state.session_painted = you
  pcall(api.nvim_set_hl, 0, SESSION_HIGHLIGHT, { link = 'Title', default = true })
  pcall(api.nvim_set_hl, 0, 'SelvageWarn', { link = 'WarningMsg', default = true })
  pcall(api.nvim_set_hl, 0, 'SelvageCrown', { fg = '#f9e2af', ctermfg = cterm('#f9e2af'), bold = true, default = true })
  pcall(api.nvim_set_hl, 0, 'SelvageFollowed', { fg = '#cba6f7', ctermfg = cterm('#cba6f7'), bold = true, default = true })
  pcall(api.nvim_set_hl, 0, 'SelvageYou', {
    fg = '#000000',
    bg = you,
    ctermfg = cterm('#000000'),
    ctermbg = cterm(you),
    bold = true,
    underline = true,
  })
end

--- How the session row is shown: `always` for `true`, `'always'` and the default — the row stands
--- for as long as the session does, the way the VS Code client's status bar does, so whoever has
--- just hosted reads that they have before anyone joins; `changes` for the quiet row, which
--- appears only while there is something to act on; `never` for `false` and `'never'`.
local function indicator_mode()
  local setting = vim.g.selvage_indicator
  if setting == false or setting == 'never' then
    return 'never'
  end
  if setting == 'changes' then
    return 'changes'
  end
  return 'always'
end

--- The session's own words, the way the web page's session bar opens: what the session is called,
--- or while the host is away, who left and how long the room has; and whether the connection is
--- being re-established. Nil when there is no session to speak of, and nil while the row is turned
--- off, which is also what silences a statusline built on the same words.
local function session_words()
  if indicator_mode() == 'never' then
    return nil
  end
  if state.status == 'connecting' then
    return 'Connecting…'
  end
  if not in_session() then
    return nil
  end
  local said = state.host_away ~= nil and state.host_away.line or state.identity or ''
  if state.reconnecting then
    local reconnecting = state.words ~= nil and state.words.reconnecting or 'Reconnecting…'
    said = said == '' and reconnecting or (said .. ' · ' .. reconnecting)
  end
  return said
end

--- Whether a buffer stands for a room file whose content this session has not fetched: the
--- room's shape is materialised on disk and its text is not, so an empty buffer is not an
--- empty file.
---
--- `DESIGN.md` §4.2 leaves a listing partial by design, and every tool that reads the mirror —
--- ripgrep, ctags, a language server — reads a partial project with it. The row is where that
--- is visible while the file is in front of the person, rather than a sentence in `:messages`
--- they have to remember.
local function unfetched_buffer(bufnr)
  if not buffer_empty(bufnr) then
    return false
  end
  local path = mirror.room_path(api.nvim_buf_get_name(bufnr))
  if path == nil or not mirror.granted(path) then
    return false
  end
  return not mirror.written(path)
end

--- Whether this buffer's row is wanted: under `always`, wherever a session stands; under
--- `changes`, only while there is something to act on — a connection being made or retried, the
--- host away, or content the room has not sent yet; never under `never`.
local function row_wanted(bufnr)
  local mode = indicator_mode()
  if mode == 'never' then
    return false
  end
  if state.reconnecting or state.status == 'connecting' or state.host_away ~= nil then
    return true
  end
  if state.following ~= nil or unfetched_buffer(bufnr) then
    return true
  end
  return mode == 'always' and session_words() ~= nil
end

--- Everyone in the room in the order the web page draws their faces: your own first, then the
--- others in the order the room lists them. The host is crowned wherever it sits; order says
--- nothing about seats, whose colours the companion hands out.
local function seat_order()
  local seats = {}
  if state.self_seat ~= nil then
    seats[1] = state.self_seat
  end
  for _, peer in ipairs(state.room_peers) do
    seats[#seats + 1] = peer
  end
  return seats
end

--- The faces at the right of the bar: each person's initials in their seat's colour, the host's
--- crowned, your own underlined, and the one this window follows marked.
local function faces_text()
  local own = state.self_seat ~= nil and state.self_seat.peer_id or nil
  local followed = state.following ~= nil and state.following.peerId or nil
  local faces = {}
  for _, seat in ipairs(seat_order()) do
    local face = ''
    if seat.role == 'host' then
      face = '%#SelvageCrown#' .. CROWN
    end
    if seat.peer_id == followed then
      face = face .. '%#SelvageFollowed#' .. FOLLOWED_MARK
    end
    local group = seat.peer_id == own and 'SelvageYou'
      or peer_highlight({ peerId = seat.peer_id, colour = seat.colour })
    local initials = seat.initials or peer_sign(seat.display_name)
    faces[#faces + 1] = ('%s%%#%s# %s %%*'):format(face, group, row_text(initials))
  end
  return table.concat(faces, ' ')
end

--- The room as `:SelvagePeers` lists it: everyone in the order of the faces, each with the
--- highlight their face wears and the file they are in. Your own file is the one `win` shows,
--- the current window by default.
function M.room(win)
  paint_bar()
  local own = state.self_seat ~= nil and state.self_seat.peer_id or nil
  local followed = state.following ~= nil and state.following.peerId or nil
  local where = {}
  for _, peer in ipairs(queries.peers()) do
    where[peer.peerId] = peer.path
  end
  local here = document_for_buf(api.nvim_win_get_buf(win or 0))
  local people = {}
  for _, seat in ipairs(seat_order()) do
    local you = seat.peer_id == own
    local label = tostring(seat.display_name or '')
    label = label ~= '' and label or tostring(seat.peer_id)
    people[#people + 1] = {
      peerId = seat.peer_id,
      label = label,
      name = seat.roster or label,
      initials = seat.initials or peer_sign(label),
      host = seat.role == 'host',
      you = you,
      followed = seat.peer_id == followed,
      highlight = you and 'SelvageYou' or peer_highlight({ peerId = seat.peer_id, colour = seat.colour }),
      path = you and (here and here.path or nil) or where[seat.peer_id],
    }
  end
  return { people = people }
end

--- Lists everyone in the room, one line each: their face, their name and the file they are in.
--- Echoed rather than notified, because a notification provider may render a message as plain
--- text and the face's colour is how a person is told apart from the carets.
function M.list_peers()
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local people = M.room().people
  local width = 0
  for _, person in ipairs(people) do
    person.shown = person.name .. (person.you and ' (you)' or '')
    width = math.max(width, vim.fn.strdisplaywidth(person.shown))
  end
  local chunks = {}
  for _, person in ipairs(people) do
    if #chunks > 0 then
      chunks[#chunks + 1] = { '\n' }
    end
    chunks[#chunks + 1] = person.host and { CROWN, 'SelvageCrown' } or { ' ' }
    chunks[#chunks + 1] = person.followed and { FOLLOWED_MARK, 'SelvageFollowed' } or { ' ' }
    chunks[#chunks + 1] = { ' ' .. person.initials .. ' ', person.highlight }
    chunks[#chunks + 1] = { ' ' .. person.shown .. (' '):rep(width - vim.fn.strdisplaywidth(person.shown) + 2) }
    chunks[#chunks + 1] = { person.path or 'no file open', 'Comment' }
  end
  api.nvim_echo(chunks, true, {})
end

--- The bar a buffer wears, the web page's session bar in a winbar: the session's name, the
--- follow, and the faces at the right. Under `never` a follow still shows its own
--- chip, because it is the way to stop. Nil when the buffer has no row to wear.
local function indicator_row(bufnr)
  local mode = indicator_mode()
  if mode == 'never' then
    if state.following == nil then
      return nil
    end
    return SESSION_FRAME .. ' ' .. follow_chip(state.following.label)
  end
  if not row_wanted(bufnr) then
    return nil
  end
  paint_bar()
  local parts = {}
  if state.host_away ~= nil then
    parts[#parts + 1] = '%#SelvageWarn#' .. row_text(state.host_away.line) .. '%*'
  elseif state.status == 'connecting' then
    parts[#parts + 1] = 'Connecting…'
  elseif state.identity ~= nil then
    parts[#parts + 1] = row_text(state.identity)
  end
  if state.reconnecting then
    parts[#parts + 1] = '%#SelvageWarn#' .. row_text(state.words ~= nil and state.words.reconnecting or 'Reconnecting…') .. '%*'
  end
  if state.following ~= nil then
    parts[#parts + 1] = follow_chip(state.following.label)
  end
  if unfetched_buffer(bufnr) then
    parts[#parts + 1] = SESSION_FRAME .. '[not fetched]%*'
  end
  return SESSION_FRAME .. ' ' .. table.concat(parts, ' ') .. '%=' .. faces_text() .. ' '
end

--- Whether `text` is one of the indicators' own rows: only they write that framing, so a buffer
--- showing one with no row saved for it is residue rather than someone's own row.
local function is_indicator_row(text)
  return tostring(text):find(SESSION_FRAME, 1, true) == 1
end

--- Puts back the winbar rows the indicators replaced, wherever they stand: every window
--- still showing a buffer one of them visited gets its own row back. With nothing wanted on
--- the row, a window showing an indicator's own row with nothing saved is residue — a split
--- the departures never swept — and reads empty instead.
local function restore_indicators()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      local key = winbar_key(win, api.nvim_win_get_buf(win))
      local prev = state.saved_winbars[key]
      if prev ~= nil then
        state.saved_winbars[key] = nil
        -- A float keeps no row of a person's back: it is not a window showing their buffer, and
        -- a row it never had is not one to put back. Clearing one is safe where writing one is
        -- not — removing a winbar needs no line the float has not got.
        if not floating(win) then
          pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
        end
      else
        local ok, current = pcall(api.nvim_get_option_value, 'winbar', { win = win })
        if ok and is_indicator_row(current) then
          pcall(api.nvim_set_option_value, 'winbar', '', { win = win })
        end
      end
    end
  end
end

--- Puts the row a window should wear on it, saving the person's own first, and puts the
--- person's own back when neither indicator wants the row. The one path both of them take:
--- which of them speaks is `indicator_row`'s answer.
---
--- Window-local, so nothing else on screen moves, and every buffer's own row is put back as
--- it leaves. Never the statusline, which is what statusline plugins own.
local function show_indicator(win)
  win = win or api.nvim_get_current_win()
  if floating(win) then
    return
  end
  local bufnr = api.nvim_win_get_buf(win)
  local key = winbar_key(win, bufnr)
  local ours = indicator_row(bufnr)
  local ok, current = pcall(api.nvim_get_option_value, 'winbar', { win = win })
  current = (ok and current) or ''
  if ours == nil then
    local prev = state.saved_winbars[key]
    if prev ~= nil then
      state.saved_winbars[key] = nil
      if current ~= prev then
        pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
      end
    elseif is_indicator_row(current) then
      pcall(api.nvim_set_option_value, 'winbar', '', { win = win })
    end
    return
  end
  if state.saved_winbars[key] == nil then
    -- A re-target lands an indicator in a buffer whose row is already saved, and a rename
    -- only re-words it, so those never reach here. What does is a split inheriting the row
    -- it split from: the copy is ours but nothing saved it, and its own row is the default —
    -- it never had one — so that is what leaving puts back.
    state.saved_winbars[key] = is_indicator_row(current) and '' or current
  end
  if current ~= ours then
    pcall(api.nvim_set_option_value, 'winbar', ours, { win = win })
  end
end

--- Draws the row again in the windows showing `bufnr`: what one buffer holds is the one
--- thing the row says that changes without a session event — the mark a file wears while the
--- room's text has not arrived goes the moment it does.
local function refresh_indicator_for(bufnr)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
      show_indicator(win)
    end
  end
end

--- Draws the wanted row again on every window: what a session transition needs, and what a
--- room whose membership moved needs. The bar is the same in every window, and each window keeps
--- its own saved row.
refresh_indicators = function()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      show_indicator(win)
    end
  end
end
--- Shows the follow in the window, in their own colour. Called wherever the follow moves or
--- re-labels, so the row follows it.
local function set_indicator()
  local following = state.following
  if following == nil then
    return
  end
  pcall(api.nvim_set_hl, 0, 'SelvageFollow', {
    fg = '#000000',
    bg = following.colour or '#888888',
    ctermfg = cterm('#000000'),
    ctermbg = cterm(following.colour or '#888888'),
    bold = true,
  })
  vim.g.selvage_following = following.peerId
  refresh_indicators()
end

--- Takes the indicators down, wherever they stand.
local function clear_indicator()
  restore_indicators()
  vim.g.selvage_following = nil
end

--- Keeps the indicator on the window through a switch: every buffer it shows carries the
--- row over its own saved row, and a buffer whose row is still saved gets it back when
--- neither indicator has anything to say about it — the lazy half of leaving nothing behind.
local function indicator_window_enter()
  show_indicator()
end

--- Puts back the row the indicator replaced in the buffer being left: the window about to
--- show another buffer would otherwise keep the indicator in the old buffer's own row. Only
--- the buffer going out of view is touched — a split still showing its own copy keeps it.
local function follow_window_leave(event)
  if state.following == nil then
    return
  end
  local leaving = event ~= nil and event.buf or nil
  -- The event's own window is the one leaving: a split still showing the same buffer keeps
  -- its own copy of the indicator until it moves, rather than losing it to a sibling's
  -- switch. Without an event there is no leaver to name, so every window still showing a
  -- visited buffer is swept instead.
  local wins = leaving == nil and api.nvim_list_wins() or { api.nvim_get_current_win() }
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then
      local bufnr = api.nvim_win_get_buf(win)
      if leaving == nil or bufnr == leaving then
        local key = winbar_key(win, bufnr)
        local prev = state.saved_winbars[key]
        if prev ~= nil then
          state.saved_winbars[key] = nil
          pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
        end
      end
    end
  end
end

--- Drops the saved rows of a wiped buffer: its rows go with it, and a buffer number Neovim
--- hands out again starts clean rather than inheriting them.
local function forget_winbar_stash(event)
  local suffix = ':' .. tostring(event.buf)
  for key in pairs(state.saved_winbars) do
    if key:sub(-#suffix) == suffix then
      state.saved_winbars[key] = nil
    end
  end
end

--- Whether the caret is where the follow last put it, in the window and buffer it put it in.
local function still_landed()
  local landed = state.follow_landed
  if landed == nil or api.nvim_get_current_win() ~= landed.win or api.nvim_get_current_buf() ~= landed.buf then
    return false
  end
  local here = api.nvim_win_get_cursor(0)
  return here[1] == landed.row and here[2] == landed.col
end

--- Watches the window for the indicators: the switches that swap which buffer's row they
--- show are the ones that save and put back each buffer's own.
local function watch_follow_window()
  state.follow_group = api.nvim_create_augroup('SelvageFollowWindow', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = state.follow_group,
    callback = indicator_window_enter,
  })
  -- A caret the user moved ends the follow: the next frame would drag it back, and a follow that
  -- fought the person is the behaviour they remember as broken. A move the follow itself made is
  -- behind `applying_follow`, not read here.
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = state.follow_group,
    callback = function()
      if state.applying_follow or state.following == nil or still_landed() then
        return
      end
      end_follow('moved')
    end,
  })
  api.nvim_create_autocmd('BufLeave', {
    group = state.follow_group,
    callback = follow_window_leave,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = state.follow_group,
    callback = forget_winbar_stash,
  })
end

--- Why a follow ended, in the web page's words, keyed by the reason `end_follow` is given.
local FOLLOW_ENDED = { typed = 'typing', moved = 'moving', left = 'leaving', gone = 'fileGone' }

--- Ends the follow, saying so as `why` asks: 'typed', 'moved', 'left' and 'gone' in the web
--- page's words, and nothing for 'stopped', which the person did themselves, as the web does. A
--- follow the session takes with it is 'silent' and leaves the row to the session's end.
end_follow = function(why)
  local following = state.following
  if following == nil then
    return
  end
  state.following = nil
  state.follow_landed = nil
  -- A deadline armed for this establishment has nothing left to refuse: a second follow that
  -- starts before it fires arms its own, and the timer that finds this one gone stands down.
  state.landing_wait = nil
  vim.g.selvage_following = nil
  if why == 'silent' then
    clear_indicator()
    return
  end
  local function show()
    -- The row is the window's, and the session's words are what stands on it with no follow:
    -- ending one puts the other back on every window, not only the one in front. A follow
    -- started again before this ran has drawn its own row already.
    if state.following == nil then
      clear_indicator()
      refresh_indicators()
    end
    local ended = state.words ~= nil and FOLLOW_ENDED[why] ~= nil and state.words.followEnded[FOLLOW_ENDED[why]] or nil
    if ended ~= nil then
      notify(ended:format(following.label))
    end
  end
  if why == 'typed' then
    -- Typing ends a follow from inside the buffer's change callback, where Neovim refuses to
    -- change another buffer's text or open a window: a notifier that draws a float fails there
    -- with E565, so it waits for the next turn.
    vim.schedule(show)
  else
    show()
  end
end

--- What the indicator shows, for whoever wants it in the statusline:
--- `%{v:lua.require'selvage'.statusline()}`. The follow's words while one stands, and the
--- session's own otherwise: the same words the window's row carries, without its highlight
--- framing, so a person with their own statusline reads them where they read everything else.
function M.statusline()
  local following = state.following
  if following ~= nil then
    return 'Following ' .. tostring(following.label or '')
  end
  local said = session_words()
  if said == nil then
    return ''
  end
  if unfetched_buffer(api.nvim_get_current_buf()) then
    return said .. ' [not fetched]'
  end
  return said
end



M.clear_indicator = clear_indicator
M.end_follow = end_follow
M.refresh_indicator_for = refresh_indicator_for
M.refresh_indicators = refresh_indicators
M.set_indicator = set_indicator
M.watch_follow_window = watch_follow_window

return M
