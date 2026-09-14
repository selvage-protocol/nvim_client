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

return M
