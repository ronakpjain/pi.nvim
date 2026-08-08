-- pi.nvim - Neovim plugin for pi coding agent
-- Maintainer: pablopunk
-- License: MIT

-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = true

-- Register user-facing commands exposed by the plugin.

-- Open a prompt using the current buffer as additional context.
vim.api.nvim_create_user_command("PiAsk", function()
  require("pi").prompt_with_buffer()
end, { desc = "Ask pi with current buffer as context" })

-- Open a prompt using the current visual selection as context.
vim.api.nvim_create_user_command("PiAskSelection", function()
  require("pi").prompt_with_selection()
end, { range = true, desc = "Ask pi with visual selection as context" })

-- Cancel the currently running pi request, if there is one.
vim.api.nvim_create_user_command("PiCancel", function()
  require("pi").cancel()
end, { desc = "Cancel the active pi request" })

-- Show the pi.nvim session log
vim.api.nvim_create_user_command("PiLog", function()
  require("pi").show_log()
end, { desc = "Show pi session log" })

-- Open or focus the persistent Pi transcript split.
vim.api.nvim_create_user_command("Pi", function()
  require("pi").open()
end, { desc = "Open the Pi transcript" })

vim.api.nvim_create_user_command("PiClose", function()
  require("pi").close_transcript()
end, { desc = "Close the Pi transcript" })

-- Prompt in the currently selected/resumed session.
vim.api.nvim_create_user_command("PiAskSession", function()
  require("pi").prompt_session()
end, { desc = "Ask Pi in the current session" })

-- Session lifecycle and inspection.
vim.api.nvim_create_user_command("PiSessionNew", function()
  require("pi").new_session()
end, { desc = "Start a new Pi session" })

vim.api.nvim_create_user_command("PiSessionResume", function()
  require("pi").resume_session()
end, { desc = "Resume a Pi session for the current project" })

vim.api.nvim_create_user_command("PiSessionResumeAll", function()
  require("pi").resume_session({ all = true, prompt = "Pi session (all projects): " })
end, { desc = "Resume any Pi session" })

vim.api.nvim_create_user_command("PiSessionSwitch", function(args)
  require("pi").switch_session(args.args)
end, { nargs = 1, complete = "file", desc = "Switch to a Pi session path" })

vim.api.nvim_create_user_command("PiSessionClone", function()
  require("pi").clone_session()
end, { desc = "Clone the active Pi session" })

vim.api.nvim_create_user_command("PiSessionFork", function()
  require("pi").fork_session()
end, { desc = "Fork the active Pi session" })

vim.api.nvim_create_user_command("PiSessionTree", function()
  require("pi").show_tree()
end, { desc = "Show the active Pi session tree" })

vim.api.nvim_create_user_command("PiSessionPath", function()
  require("pi").session_path()
end, { desc = "Copy the active Pi session path" })

vim.api.nvim_create_user_command("PiSessionName", function()
  require("pi").session_name()
end, { desc = "Name the active Pi session" })

vim.api.nvim_create_user_command("PiSessionStats", function()
  require("pi").session_stats()
end, { desc = "Show Pi session usage and context stats" })

vim.api.nvim_create_user_command("PiSessionExport", function()
  require("pi").export_session()
end, { desc = "Export the active Pi session as HTML" })

vim.api.nvim_create_user_command("PiSessionStop", function()
  require("pi").stop()
end, { desc = "Stop the persistent Pi RPC process" })

-- Interactive queue and context controls.
vim.api.nvim_create_user_command("PiSteer", function()
  require("pi").steer()
end, { desc = "Steer the running Pi turn" })

vim.api.nvim_create_user_command("PiFollowUp", function()
  require("pi").follow_up()
end, { desc = "Queue a Pi follow-up" })

vim.api.nvim_create_user_command("PiCompact", function()
  require("pi").compact()
end, { desc = "Compact the Pi session context" })

vim.api.nvim_create_user_command("PiModelCycleForward", function()
  require("pi").cycle_model()
end, { desc = "Cycle Pi model forward" })

vim.api.nvim_create_user_command("PiThinkingCycle", function()
  require("pi").cycle_thinking_level()
end, { desc = "Cycle Pi thinking level" })
