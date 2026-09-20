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

command('SelvageFetch', function(args)
  require('selvage').fetch(args.args)
end, {
  nargs = '?',
  desc = 'Download a file from the room',
  complete = function(lead)
    local matches = {}
    for _, path in ipairs(require('selvage').fetchable()) do
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

command('SelvageChangeServer', function(args)
  require('selvage').change_server(args.args)
end, { nargs = '?', desc = 'Change the server' })

command('SelvageGoTo', function(args)
  require('selvage').go_to(args.args)
end, {
  nargs = '?',
  desc = 'Go to a participant',
  complete = function(lead)
    local matches = {}
    for _, row in ipairs(require('selvage').complete_peers()) do
      if row:sub(1, #lead) == lead then
        matches[#matches + 1] = row
      end
    end
    return matches
  end,
})

command('SelvageFollow', function(args)
  require('selvage').follow(args.args)
end, {
  nargs = '?',
  desc = 'Follow a participant',
  complete = function(lead)
    local matches = {}
    for _, row in ipairs(require('selvage').complete_peers()) do
      if row:sub(1, #lead) == lead then
        matches[#matches + 1] = row
      end
    end
    return matches
  end,
})

command('SelvageStopFollowing', function()
  require('selvage').stop_following()
end, { nargs = 0, desc = 'Stop following' })
