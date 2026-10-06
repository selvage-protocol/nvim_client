-- `:checkhealth selvage`: what this plugin needs of the machine, and what it found. The version
-- checks are `lua/selvage/versions.lua`'s, so what a launch refuses and what this reports cannot
-- disagree.
--
--   :checkhealth selvage

local versions = require('selvage.versions')

local M = {}

--- The directory the plugin Neovim loaded is in, read off the copy on the runtime path: the
--- package's own symlinks are resolved, so a pack directory reports where the files are rather
--- than where they are linked from.
--- @return string|nil, string|nil
local function plugin_root()
  local found = vim.api.nvim_get_runtime_file('lua/selvage/companion.lua', true)
  if #found == 0 then
    return nil, 'lua/selvage/companion.lua is on no runtime path, so the plugin is not installed.'
  end
  local here = vim.uv.fs_realpath(found[1]) or found[1]
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
end

--- One version against the floor it is held to: the line both checks below report with.
--- @param what string
--- @param found string
--- @param floor string
--- @param at string where the found version was read, when there is somewhere to name
local function report_version(what, found, floor, at)
  local where = at ~= nil and (' at ' .. at) or ''
  if versions.at_least(found, floor) then
    vim.health.ok(('%s %s%s meets the floor of %s.'):format(what, found, where, floor))
  else
    vim.health.error(versions.refusal(what, floor, found))
  end
end

--- What the companion needs that is not beside it: the packages `package.json` names as
--- dependencies, so the list has one home and a half-finished `npm ci` is caught rather than
--- counted. The manifest itself is named when it is missing or unreadable.
--- @param root string
--- @return string[]
local function missing_dependencies(root)
  local manifest = root .. '/package.json'
  local named = { 'package.json' }
  if vim.fn.filereadable(manifest) == 1 then
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(manifest), '\n'))
    if ok and type(decoded) == 'table' and type(decoded.dependencies) == 'table' then
      named = {}
      for name in pairs(decoded.dependencies) do
        if vim.fn.isdirectory(root .. '/node_modules/' .. name) == 0 then
          named[#named + 1] = name
        end
      end
      table.sort(named)
    end
  end
  return named
end

function M.check()
  vim.health.start('selvage')

  local neovim = vim.version()
  local found = ('%d.%d.%d'):format(neovim.major, neovim.minor, neovim.patch or 0)
  report_version('Neovim', found, versions.neovim)

  local node = vim.fn.exepath('node')
  if node == '' then
    vim.health.error(versions.no_node())
  else
    local text, why = versions.read_version(node)
    if text == nil then
      vim.health.error(why)
    else
      report_version('Node', vim.trim(text), versions.node, node)
    end
  end

  local root, why = plugin_root()
  if root == nil then
    vim.health.error(why)
    return
  end
  if vim.g.loaded_selvage then
    vim.health.ok(('the plugin is loaded, from %s.'):format(root))
  else
    vim.health.warn(('the plugin is not loaded; its commands are defined by %s.'):format(root))
  end
  local entry = root .. '/companion/main.ts'
  if vim.fn.filereadable(entry) == 1 then
    vim.health.ok(('the companion entry point is at %s.'):format(entry))
  else
    vim.health.error(('the companion entry point is missing at %s.'):format(entry))
  end
  local missing = missing_dependencies(root)
  if #missing == 0 then
    vim.health.ok("the companion's dependencies are installed.")
  else
    vim.health.error(
      ("the companion's dependencies are not installed; run `npm ci` in %s (%s)."):format(
        root,
        table.concat(missing, ', ')
      )
    )
  end
end

return M
