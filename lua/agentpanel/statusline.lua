-- agentpanel.statusline — a heirline component showing which worktree the
-- current window is in, rendered just before the git branch in the statusline.
--
-- Detection is cached per-directory (git spawns are not cheap) and recomputed
-- on buffer/dir/tab changes.
local cfg = require "agentpanel.config"
local git = require "agentpanel.git"

local M = {}
M.current_label = ""

local detect_cache = {} -- dir -> worktree label (string) | false

local function detect(dir)
  if dir == nil or dir == "" then return false end
  if detect_cache[dir] ~= nil then return detect_cache[dir] end
  local label = git.worktree_label(dir) or false
  detect_cache[dir] = label
  return label
end

--- Recompute the worktree label for the active window and request a redraw.
function M.refresh()
  local dir
  local ok, root = pcall(vim.api.nvim_tabpage_get_var, 0, "agentpanel_root")
  if ok and root and root ~= "" then
    dir = root
  else
    local f = vim.fn.expand "%:p:h"
    dir = (f ~= "" and vim.fn.isdirectory(f) == 1) and f or vim.fn.getcwd()
  end
  local label = detect(dir)
  local new = label or ""
  if new ~= M.current_label then
    M.current_label = new
    vim.schedule(function() pcall(vim.cmd.redrawstatus) end)
  end
end

-- Heirline component (insert before status.component.git_branch()). Providers
-- are re-evaluated on every statusline redraw; M.refresh() keeps current_label
-- fresh and forces a redraw when it changes, so no explicit `update` is needed.
M.component = {
  condition = function() return M.current_label ~= "" end,
  provider = function()
    return " " .. cfg.options.icons.worktree .. " " .. M.current_label .. " "
  end,
  hl = { fg = "git_branch_fg", bold = true },
}

local did_setup = false
function M.setup()
  if did_setup then return end
  did_setup = true
  local grp = vim.api.nvim_create_augroup("AgentPanelStatusline", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged", "TabEnter", "TermLeave" }, {
    group = grp,
    callback = function() M.refresh() end,
  })
  M.refresh()
end

return M
