-- agentpanel.nvim — editor-agnostic entry points.
--
-- This file is sourced automatically when the plugin loads (or, under a
-- lazy-loading manager keyed on `cmd`, the first time one of these commands is
-- invoked). It exposes the panel through user commands so the plugin works in
-- any Neovim setup without assuming a particular keymap or statusline system.
if vim.g.loaded_agentpanel then return end
vim.g.loaded_agentpanel = true

-- :AgentPanel — toggle the modal agent panel.
vim.api.nvim_create_user_command("AgentPanel", function()
  require("agentpanel").toggle()
end, { desc = "Toggle the agent panel" })

-- :AgentPanel[New] [codex|claude] — open the panel and jump straight to the
-- new-session form for the given agent (defaults to codex).
vim.api.nvim_create_user_command("AgentPanelNew", function(opts)
  require("agentpanel").new(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = function() return { "codex", "claude" } end,
  desc = "Open the agent panel at the new-session form",
})
