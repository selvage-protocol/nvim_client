-- The user commands. Everything they call is in `lua/selvage/`.

if vim.g.loaded_selvage then
  return
end
vim.g.loaded_selvage = true

local command = vim.api.nvim_create_user_command

command('SelvageHost', function(args)
  require('selvage').host(args.args)
end, { nargs = 1, desc = 'Host a session on a Selvage server' })

command('SelvageJoin', function(args)
  require('selvage').join(args.args)
end, { nargs = 1, desc = 'Join a session from an invite link' })

command('SelvageCopyInvite', function()
  require('selvage').copy_invite()
end, { nargs = 0, desc = 'Copy the invite link' })

command('SelvageOpen', function(args)
  require('selvage').open(args.args)
end, {
  nargs = '?',
  desc = 'Open a document the session shares',
  complete = function(lead)
    local matches = {}
    for _, path in ipairs(require('selvage').documents()) do
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

command('SelvageDisplayName', function(args)
  require('selvage').set_display_name(args.args)
end, { nargs = '?', desc = 'Set the name other participants see' })
