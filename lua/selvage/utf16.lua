-- Byte positions to UTF-16 code units and back.
--
-- A Neovim buffer is UTF-8 and every position the API reports is a byte; the protocol counts
-- UTF-16 code units, because that is what a `Y.Text` index is (specification §8.1). There is no
-- shortcut for text that is not ASCII, so this is the conversion, kept to the one line it
-- applies to: a document's offset is a sum over whole lines plus one conversion inside the line
-- the offset falls in.

local M = {}

-- `vim.str_utfindex(s, encoding, index)` is the current form; the two-value
-- `vim.str_utfindex(s, index)` is what older Neovim has, and calling it on a newer one prints a
-- deprecation warning. Choose once rather than per keystroke.
local modern = pcall(vim.str_utfindex, '', 'utf-16', 0)

--- Whether a string is ASCII, in which case every offset in it is its own byte offset.
local function ascii(s)
  return s:find('[\128-\255]') == nil
end

--- The number of UTF-16 code units in `s`.
function M.len(s)
  if ascii(s) then
    return #s
  end
  return M.of_byte(s, #s)
end

--- The UTF-16 offset of the byte offset `byte` in `s`.
function M.of_byte(s, byte)
  if ascii(s) then
    return byte
  end
  if modern then
    return vim.str_utfindex(s, 'utf-16', byte)
  end
  local _, units = vim.str_utfindex(s, byte)
  return units
end

--- The byte offset of the UTF-16 offset `units` in `s`.
function M.to_byte(s, units)
  if ascii(s) then
    return units
  end
  if modern then
    return vim.str_byteindex(s, 'utf-16', units)
  end
  return vim.str_byteindex(s, units, true)
end

--- Whether `s` is well-formed UTF-8.
---
--- A Neovim buffer is a byte array — the encoding of the file it was read from is not this
--- process's to assume — so a buffer opened as Latin-1 holds bytes that are not UTF-8. The
--- companion decodes its stdin as UTF-8, so such a byte reaches the room as U+FFFD: the
--- document quietly loses it. What cannot be carried is refused instead, and this is what says
--- which texts those are.
---
--- The walk is RFC 3629: a lead byte names the sequence's length, its continuation bytes follow
--- in 0x80-0xBF, and the forms that are not characters — an overlong encoding, a surrogate,
--- anything past U+10FFFF — do not pass.
function M.valid(s)
  local index = 1
  local length = #s
  while index <= length do
    local lead = s:byte(index)
    local size, minimum, code
    if lead < 0x80 then
      size, minimum, code = 1, 0, lead
    elseif lead >= 0xc2 and lead <= 0xdf then
      -- 0xc0 and 0xc1 are left out: a two-byte sequence for a code point under 0x80 is an
      -- overlong, and they can make nothing else.
      size, minimum, code = 2, 0x80, lead - 0xc0
    elseif lead >= 0xe0 and lead <= 0xef then
      size, minimum, code = 3, 0x800, lead - 0xe0
    elseif lead >= 0xf0 and lead <= 0xf4 then
      size, minimum, code = 4, 0x10000, lead - 0xf0
    else
      -- A continuation byte where a lead belongs, or the five- and six-byte forms.
      return false
    end
    if index + size - 1 > length then
      return false
    end
    for offset = 1, size - 1 do
      local byte = s:byte(index + offset)
      if byte < 0x80 or byte > 0xbf then
        return false
      end
      code = code * 0x40 + byte - 0x80
    end
    if code < minimum or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff) then
      return false
    end
    index = index + size
  end
  return true
end

return M
