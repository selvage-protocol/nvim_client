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

command('SelvageLeave', function()
  require('selvage').leave()
end, { nargs = 0, desc = 'Leave the session' })
