-- The mirror's two bounds, pinned to the vendored constants they copy.
--
-- `lua/selvage/mirror.lua` cannot import `vendor/bridge/grant.ts`, so it holds two literals: the
-- longest path a listing may name and the most paths one listing carries. Those are the vendored
-- `MAX_GRANT_PATH_BYTES` and, through `MAX_GRANT_PATHS = MAX_LISTING_PATHS`, `MAX_LISTING_PATHS`.
-- A literal that drifts from the constant it copies is a bound nothing checks, so this file reads
-- both sides and fails when they disagree — and asserts the reads reached a number, because a
-- pattern that matched nothing would make every comparison pass on nil.
--
--   nvim --headless -l test/lua/bounds.lua      (or scripts/test-lua.sh)

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- The number a source file assigns to `name`, or nil when it states it in no shape this reads.
--- Underscores are stripped, because the vendored copy writes `100_000`.
---
--- @param path string
--- @param name string
--- @return integer|nil
local function constant(path, name)
  local source = table.concat(vim.fn.readfile(path), '\n')
  local value = source:match('const%s+' .. name .. '%s*=%s*([%d_]+)')
  return value ~= nil and tonumber((value:gsub('_', ''))) or nil
end

local mirror = require('selvage.mirror')

local listing_paths = constant('vendor/engine/limits.ts', 'MAX_LISTING_PATHS')
local path_bytes = constant('vendor/bridge/grant.ts', 'MAX_GRANT_PATH_BYTES')
check('the pin reads MAX_LISTING_PATHS from the vendored engine', type(listing_paths), 'number')
check('the pin reads MAX_GRANT_PATH_BYTES from the vendored bridge', type(path_bytes), 'number')

check('the mirror holds the longest path a listing may name', mirror.max_path_bytes, path_bytes)
check('the mirror holds the most paths one listing carries', mirror.max_listed, listing_paths)
check('the count bound is the protocol ceiling', listing_paths, 100000)

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
