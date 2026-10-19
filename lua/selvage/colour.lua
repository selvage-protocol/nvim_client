-- A seat's colour, as this editor draws it.
--
-- The room gives a peer a colour; how it is presented is the adapter's business (`DESIGN.md`
-- §4.3), and a terminal has 256 slots at best. `cterm` quantises a truecolor value to the nearest
-- slot, and a highlight group is made per seat: `peer_highlight` for the caret and the sign,
-- `peer_fill` for the one-cell mark, and `peer_sign` for the two initials a row is drawn with.
local api = vim.api

local state = require('selvage.state').state

local M = {}

--- The RGB channels of a `#rrggbb` colour, or nil for anything else.
local function channels(colour)
  local r, g, b = tostring(colour or ''):match('^#(%x%x)(%x%x)(%x%x)')
  if r == nil then
    return nil
  end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

--- The terminal's own first sixteen colours, whose exact values its theme decides, so a colour
--- equal to one of them takes that place rather than the nearest cube or grey cell.
local CTERM_BASE = {
  [0x000000] = 0,
  [0x800000] = 1,
  [0x008000] = 2,
  [0x808000] = 3,
  [0x000080] = 4,
  [0x800080] = 5,
  [0x008080] = 6,
  [0xc0c0c0] = 7,
  [0x808080] = 8,
  [0xff0000] = 9,
  [0x00ff00] = 10,
  [0xffff00] = 11,
  [0x0000ff] = 12,
  [0xff00ff] = 13,
  [0x00ffff] = 14,
  [0xffffff] = 15,
}

--- The 6x6x6 cube's channel values, spaced the terminal's way rather than uniformly.
local CTERM_LEVELS = { 0, 95, 135, 175, 215, 255 }

--- The 0-based cube step whose value is nearest a channel.
local function nearest_level(value)
  local best, best_distance = 0, math.abs(value - CTERM_LEVELS[1])
  for index = 1, #CTERM_LEVELS do
    local distance = math.abs(value - CTERM_LEVELS[index])
    if distance < best_distance then
      best, best_distance = index - 1, distance
    end
  end
  return best
end

--- The xterm-256 index nearest an sRGB triple: the terminal's own colour when it is one of the
--- first sixteen, otherwise the closer of the cube and the grey ramp. A stock Neovim leaves
--- `'termguicolors'` off, where a group carrying only gui colours draws as nothing, so every
--- colour this plugin sets is given the cterm value beside it.
local function cterm_index(r, g, b)
  local base = CTERM_BASE[r * 65536 + g * 256 + b]
  if base ~= nil then
    return base
  end
  local ri, gi, bi = nearest_level(r), nearest_level(g), nearest_level(b)
  local cr, cg, cb = CTERM_LEVELS[ri + 1], CTERM_LEVELS[gi + 1], CTERM_LEVELS[bi + 1]
  local step = math.floor(((r + g + b) / 3 - 8) / 10 + 0.5)
  step = math.max(0, math.min(23, step))
  local grey = 8 + 10 * step
  local cube_distance = (r - cr) ^ 2 + (g - cg) ^ 2 + (b - cb) ^ 2
  local grey_distance = (r - grey) ^ 2 + (g - grey) ^ 2 + (b - grey) ^ 2
  if grey_distance < cube_distance then
    return 232 + step
  end
  return 16 + 36 * ri + 6 * gi + bi
end

--- The xterm-256 index for a `#rrggbb` colour, or nil for anything else.
local function cterm(colour)
  local r, g, b = channels(colour)
  if r == nil then
    return nil
  end
  return cterm_index(r, g, b)
end

--- The highlight group a peer's caret block and sign are drawn in, made once per peer from the
--- colour the bridge derived, so a peer is the same colour in every client: black on the
--- peer's own colour, a block over the caret's cell and a legible sign in the gutter alike.
--- Each colour carries its cterm value too, so the same peer is drawn with the terminal's
--- colours when `'termguicolors'` is off.
local function peer_highlight(cursor)
  local name = state.peer_groups[cursor.peerId]
  if name == nil then
    state.peer_count = state.peer_count + 1
    name = 'SelvagePeer' .. state.peer_count
    state.peer_groups[cursor.peerId] = name
  end
  -- The set is the cost, not the name: a colour that did not move since the last report keeps
  -- the highlight it already has.
  local paints = state.peer_paints[cursor.peerId]
  if paints == nil then
    paints = {}
    state.peer_paints[cursor.peerId] = paints
  end
  local paint = tostring(cursor.colour or '#888888')
  if paints.group ~= paint then
    paints.group = paint
    local colour = cursor.colour or '#888888'
    api.nvim_set_hl(0, name, {
      fg = '#000000',
      bg = colour,
      ctermfg = cterm('#000000'),
      ctermbg = cterm(colour),
      bold = true,
    })
  end
  return name
end

--- The alpha the bridge gave a selection's fill, or its own quarter when it named none.
local function fill_alpha(fill)
  local alpha = tostring(fill or ''):match('^#%x%x%x%x%x%x(%x%x)$')
  return alpha ~= nil and tonumber(alpha, 16) / 255 or 0.25
end

--- The highlight a peer's selection is filled with, made once per peer beside the caret one.
---
--- The bridge hands the fill as `#rrggbbaa` and a buffer highlight takes an opaque
--- `#rrggbb`, so the alpha is resolved here: against the editor's own background, so the fill
--- is a tint the text stays legible on rather than the peer's colour painted over it, which is
--- the trade a `Visual` highlight makes too. A theme with no `Normal` background has the
--- colour its `background` option names.
local function peer_fill(cursor)
  local name = state.peer_fills[cursor.peerId]
  if name == nil then
    state.peer_count = state.peer_count + 1
    name = 'SelvagePeer' .. state.peer_count .. 'Fill'
    state.peer_fills[cursor.peerId] = name
  end
  local paints = state.peer_paints[cursor.peerId]
  if paints == nil then
    paints = {}
    state.peer_paints[cursor.peerId] = paints
  end
  local background = api.nvim_get_hl(0, { name = 'Normal' }).bg
  if background == nil then
    background = vim.o.background == 'light' and 0xffffff or 0x000000
  end
  -- The fill, the colour and the background it was resolved against: a report that moves
  -- none of them keeps the highlight it already has, a theme switch included.
  local paint = tostring(cursor.colour) .. '\0' .. tostring(cursor.fill) .. '\0' .. tostring(background)
  if paints.fill ~= paint then
    paints.fill = paint
    local r, g, b = channels(cursor.colour)
    if r == nil then
      api.nvim_set_hl(0, name, {})
      return name
    end
    local nr = math.floor(background / 65536) % 256
    local ng = math.floor(background / 256) % 256
    local nb = background % 256
    local alpha = fill_alpha(cursor.fill)
    local function mix(fore, back)
      return math.floor(fore * alpha + back * (1 - alpha) + 0.5)
    end
    local fr, fg, fb = mix(r, nr), mix(g, ng), mix(b, nb)
    api.nvim_set_hl(0, name, {
      bg = ('#%02x%02x%02x'):format(fr, fg, fb),
      ctermbg = cterm_index(fr, fg, fb),
    })
  end
  return name
end

--- The sign a peer's caret carries in the gutter. `sign_text` takes one or two cells: the
--- first two characters of the name tell two peers whose names share an initial apart — `pi`
--- and `pc` both begin with `p` — and the colour tells the rest apart. A wide character takes
--- both cells on its own, so the second character is only taken when it still fits.
local function peer_sign(label)
  local first = vim.fn.strcharpart(label or '', 0, 1)
  if first == '' then
    return '•'
  end
  local two = vim.fn.strcharpart(label, 0, 2)
  return vim.fn.strdisplaywidth(two) <= 2 and two or first
end


M.cterm = cterm
M.peer_fill = peer_fill
M.peer_highlight = peer_highlight
M.peer_sign = peer_sign

return M
