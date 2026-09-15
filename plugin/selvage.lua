-- The user commands. Everything they call is in `lua/selvage/`.

if vim.g.loaded_selvage then
  return
end
vim.g.loaded_selvage = true

local command = vim.api.nvim_create_user_command

command('SelvageHost', function(args)
  require('selvage').host(args.args)
end, { nargs = '?', desc = 'Host a session' })

command('SelvageJoin', function(args)
  require('selvage').join(args.args)
end, { nargs = '?', desc = 'Join a session from an invite link' })

command('SelvageCopyInvite', function()
  require('selvage').copy_invite()
end, { nargs = 0, desc = 'Copy the invite link' })

command('SelvageOpen', function(args)
  require('selvage').open(args.args)
end, {
  nargs = '?',
  desc = 'Open a document from the room',
  complete = function(lead)
    local matches = {}
    for _, path in ipairs(require('selvage').offered()) do
      if path:sub(1, #lead) == lead then
        matches[#matches + 1] = path
      end
    end
    return matches
  end,
})

command('SelvageLeave', function()
  require('selvage').leave()
end, { nargs = 0, desc = 'Leave the session' })

command('SelvagePeers', function()
  require('selvage').list_peers()
end, { nargs = 0, desc = "List the room's participants" })

command('SelvageDisplayName', function(args)
  require('selvage').set_display_name(args.args)
end, { nargs = '?', desc = 'Set the name other participants see' })
