-- agentpanel — a Codex-like agent panel for AstroNvim.
--
-- A <Leader>m modal with a left rail of conversations (grouped by project,
-- annotated with the agent and worktree) and a right pane embedding the live
-- codex/claude terminal. Sessions can run locally or in a fresh git worktree;
-- `e` drops back into the editor at a session's worktree root, and the
-- statusline shows the active worktree before the branch.
local M = {}

local did_setup = false

function M.setup(opts)
  if did_setup then return end
  did_setup = true
  require("agentpanel.config").setup(opts)
  require("agentpanel.store").load()
  require("agentpanel.statusline").setup()
  require("agentpanel.ui").setup_highlights()
end

function M.toggle()
  M.setup()
  require("agentpanel.ui").toggle()
end

function M.open()
  M.setup()
  require("agentpanel.ui").open()
end

--- Open the panel (if needed) and jump straight to the new-session form.
function M.new(agent)
  M.open()
  require("agentpanel.newsession").open(agent or "codex")
end

--- The heirline component to insert before the git branch in the statusline.
function M.statusline_component()
  M.setup()
  return require("agentpanel.statusline").component
end

return M
