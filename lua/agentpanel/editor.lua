-- agentpanel.editor — the `e` / `c` actions: drop from a conversation back into
-- the editor at that session's worktree/cwd. Reuses an existing tab for the same
-- root if one is already open; otherwise opens a new tab rooted there. `c` does
-- the same, then drops the session's own terminal into a right-side sidecar.
local cfg = require "agentpanel.config"

local M = {}

local function tab_root(tp)
  local ok, r = pcall(vim.api.nvim_tabpage_get_var, tp, "agentpanel_root")
  if ok then return r end
  return nil
end

--- The 1-based number of the tab currently rooted at `session`'s cwd, or nil if
--- no open tab is assigned to it. Mirrors M.open's reuse rule (agentpanel_root),
--- so the rail can show which tab a session is already living in.
function M.assigned_tab(session)
  local root = session and session.cwd
  if not root then return nil end
  for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_root(tp) == root then return vim.api.nvim_tabpage_get_number(tp) end
  end
  return nil
end

--- Open `session`'s root directory in a (new or existing) tab.
---@return boolean ok
function M.open(session)
  local root = session.cwd
  if not root or vim.fn.isdirectory(root) == 0 then
    vim.notify("agentpanel: directory not found: " .. tostring(root), vim.log.levels.ERROR)
    return false
  end

  -- Reuse a tab already rooted at this worktree.
  for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_root(tp) == root then
      vim.api.nvim_set_current_tabpage(tp)
      vim.schedule(function() require("agentpanel.statusline").refresh() end)
      return true
    end
  end

  vim.cmd "tabnew"
  vim.api.nvim_tabpage_set_var(0, "agentpanel_root", root)
  vim.cmd("tcd " .. vim.fn.fnameescape(root))

  -- Reveal the tree at the new root if neo-tree is available, else edit the dir.
  local opened = pcall(vim.cmd, "Neotree action=show dir=" .. vim.fn.fnameescape(root))
  if not opened then pcall(vim.cmd, "edit " .. vim.fn.fnameescape(root)) end

  vim.schedule(function() require("agentpanel.statusline").refresh() end)
  return true
end

--- Like `M.open`, but also drops the session's live terminal into a right-side
--- sidecar in that tab (launching/resuming it if needed). Reuses an existing
--- sidecar window for the session if one is already open in the tab.
function M.open_sidecar(session)
  if not M.open(session) then return end
  local term = require "agentpanel.terminal"

  -- If a window in this tab already shows the session's terminal, just focus it.
  local tbuf = term.buf(session)
  if tbuf then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == tbuf then
        vim.api.nvim_set_current_win(win)
        pcall(vim.cmd.startinsert)
        return
      end
    end
  end

  -- Otherwise open a right vertical split and put the session terminal there.
  vim.cmd "botright vsplit"
  local width = math.floor(vim.o.columns * (cfg.options.ui.sidecar_width or 0.4))
  pcall(vim.cmd, "vertical resize " .. math.max(30, width))
  local win = vim.api.nvim_get_current_win()
  vim.w[win].agentpanel_sidecar = session.id
  term.ensure(session, win)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then pcall(vim.cmd.startinsert) end
  end)
end

return M
