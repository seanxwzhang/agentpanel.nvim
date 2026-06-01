-- agentpanel.newsession — the "new session" form (inspired by the Codex
-- composer): pick a project directory, choose local vs. a fresh worktree, and
-- the base branch, then create + launch the session.
local cfg = require "agentpanel.config"
local store = require "agentpanel.store"
local git = require "agentpanel.git"
local util = require "agentpanel.util"

local M = {}
local ns = vim.api.nvim_create_namespace "agentpanel_newsession"

local state = nil -- { buf, win, f, order, field_line }

local function default_dir()
  local ok, root = pcall(vim.api.nvim_tabpage_get_var, 0, "agentpanel_root")
  if ok and root and root ~= "" then return root end
  local top = git.toplevel(vim.fn.getcwd())
  return top or vim.fn.getcwd()
end

local function suggest_branch(f) return f.agent .. "/" .. util.slug(os.date "%m%d-%H%M%S") end

local function set_dir(f, dir)
  dir = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/$", "")
  f.dir = dir
  local top = git.toplevel(dir)
  f.is_repo = top ~= nil
  f.project_root = top or dir
  f.project_name = vim.fn.fnamemodify(f.project_root, ":t")
  f.base = (f.is_repo and (git.current_branch(f.project_root) or cfg.options.default_base_branch)) or ""
  if not f.is_repo then f.where = "local" end
  f.new_branch = suggest_branch(f)
end

-- Build the ordered list of focusable fields for the current mode.
local function field_order(f)
  local o = { "project", "where" }
  if f.where == "worktree" then
    o[#o + 1] = "base"
    o[#o + 1] = "new_branch"
  end
  o[#o + 1] = "create"
  return o
end

local LABELS = {
  project = "Project",
  where = "Where",
  base = "Base branch",
  new_branch = "New branch",
}

local function value_of(f, key)
  if key == "project" then return f.project_name .. "  (" .. vim.fn.fnamemodify(f.dir, ":~") .. ")" end
  if key == "where" then return f.where == "worktree" and "New worktree" or "Local" end
  if key == "base" then return f.base end
  if key == "new_branch" then return f.new_branch end
  return ""
end

local function render()
  local f = state.f
  state.order = field_order(f)
  if f.focus > #state.order then f.focus = #state.order end
  if f.focus < 1 then f.focus = 1 end

  local agent = cfg.options.agents[f.agent]
  local lines = { "", "  New " .. agent.label .. " session  " .. agent.icon, "" }
  state.field_line = {}
  local hl = {} -- { line, col_start, col_end, group }

  for _, key in ipairs(state.order) do
    local lineno = #lines -- 0-indexed for extmark
    if key == "create" then
      lines[#lines + 1] = "      [ Create session ]"
      state.field_line.create = lineno
      hl[#hl + 1] = { lineno, 0, -1, "AgentPanelCreate" }
    else
      local label = util.pad(LABELS[key] .. ":", 14)
      lines[#lines + 1] = "   " .. label .. value_of(f, key)
      state.field_line[key] = lineno
      hl[#hl + 1] = { lineno, 3, 3 + #label, "AgentPanelFormLabel" }
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "   ↵ edit · ⎵ toggle · ^s create · q cancel"

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, h[1], h[2], {
      end_col = h[3] == -1 and nil or h[3],
      end_row = h[3] == -1 and h[1] + 1 or nil,
      hl_group = h[4],
    })
  end

  -- Highlight + place cursor on the focused field. No end_row: line_hl_group
  -- with an end_row would shade every line in the range, not just this one.
  local focus_key = state.order[f.focus]
  local fl = state.field_line[focus_key]
  if fl then
    vim.api.nvim_buf_set_extmark(state.buf, ns, fl, 0, { line_hl_group = "AgentPanelSel" })
    if vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_set_cursor, state.win, { fl + 1, 0 })
    end
  end
end

local function close()
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state = nil
end

local function submit()
  local f = state.f
  if vim.fn.isdirectory(f.dir) == 0 then
    vim.notify("agentpanel: not a directory: " .. f.dir, vim.log.levels.ERROR)
    return
  end

  local cwd, mode, worktree, branch
  if f.where == "worktree" then
    if not f.is_repo then
      vim.notify("agentpanel: worktree requires a git repo", vim.log.levels.ERROR)
      return
    end
    -- Resolve a collision-proof branch + path here (cheap: just reads the
    -- branch list). The actual `git worktree add` runs inside the session pty
    -- so it doesn't block the editor and its output is visible. See
    -- agentpanel.terminal.
    local function wtpath(br)
      return cfg.options.worktree_root .. "/" .. util.slug(f.project_name) .. "/" .. (util.slug(br):gsub("/", "-"))
    end
    local existing = {}
    for _, b in ipairs(git.branches(f.project_root)) do
      existing[b] = true
    end
    branch = f.new_branch
    local n = 1
    while existing[branch] or vim.fn.isdirectory(wtpath(branch)) == 1 do
      n = n + 1
      branch = f.new_branch .. "-" .. n
    end
    cwd, mode = wtpath(branch), "worktree"
    worktree = { path = cwd, branch = branch, base = f.base }
  else
    cwd, mode = f.dir, "local"
    branch = f.is_repo and (git.current_branch(f.dir) or "") or ""
  end

  local title = cfg.options.agents[f.agent].label .. " · " .. os.date "%b %d %H:%M"

  local session = {
    id = util.uid(),
    title = title,
    agent = f.agent,
    project_name = f.project_name,
    project_root = f.project_root,
    cwd = cwd,
    mode = mode,
    worktree = worktree,
    branch = branch,
    created_at = os.time(),
    last_active = os.time(),
    _fresh = true,
  }
  store.add(session)
  close()
  require("agentpanel.ui").after_create(session.id)
end

-- Field edit dispatch ------------------------------------------------------

-- Edit the Project path inline, directly over the "Project:" field. Uses a
-- normal (nofile) buffer rather than a prompt buffer, so blink.cmp attaches and
-- its `path` source shows a directory autocomplete dropdown as you type.
local PROJECT_VALUE_COL = 3 + 14 -- "   " + padded "Project:" label (see render)

local function edit_project_inline()
  local f = state.f
  local field_line = state.field_line and state.field_line.project
  if not field_line or not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end

  local form_w = vim.api.nvim_win_get_config(state.win).width
  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype = "nofile"
  vim.bo[ibuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { f.dir })

  local iwin = vim.api.nvim_open_win(ibuf, true, {
    relative = "win",
    win = state.win,
    row = field_line,
    col = PROJECT_VALUE_COL,
    width = math.max(20, form_w - PROJECT_VALUE_COL - 1),
    height = 1,
    style = "minimal",
    zindex = 250,
  })
  vim.wo[iwin].winhighlight = "Normal:AgentPanelSel"
  vim.api.nvim_win_set_cursor(iwin, { 1, #f.dir })

  local function blink() local ok, b = pcall(require, "blink.cmp") return ok and b or nil end
  local done = false
  local function finish(accept)
    if done then return end
    done = true
    local val = (vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)[1] or ""):gsub("%s+$", "")
    pcall(vim.cmd.stopinsert)
    if vim.api.nvim_win_is_valid(iwin) then pcall(vim.api.nvim_win_close, iwin, true) end
    if state.win and vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_set_current_win(state.win) end
    if accept and val ~= "" then set_dir(f, val) end
    render()
  end

  local map = function(mode, lhs, fn) vim.keymap.set(mode, lhs, fn, { buffer = ibuf, nowait = true }) end
  -- <CR> accepts a highlighted completion if the menu is open, else confirms.
  map("i", "<CR>", function()
    local b = blink()
    if b and b.is_visible() then b.accept() else finish(true) end
  end)
  map("n", "<CR>", function() finish(true) end)
  -- <Esc> closes the completion menu first, then cancels.
  map("i", "<Esc>", function()
    local b = blink()
    if b and b.is_visible() then pcall(b.hide) else finish(false) end
  end)
  map("n", "<Esc>", function() finish(false) end)
  map("n", "q", function() finish(false) end)
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = ibuf,
    once = true,
    callback = function() finish(false) end,
  })

  vim.cmd.startinsert { bang = true }
end

local function edit_focused()
  local f = state.f
  local key = state.order[f.focus]
  if key == "create" then return submit() end
  if key == "project" then
    edit_project_inline()
  elseif key == "where" then
    if f.where == "local" then
      if not f.is_repo then
        vim.notify("agentpanel: not a git repo — staying local", vim.log.levels.WARN)
        return
      end
      f.where = "worktree"
    else
      f.where = "local"
    end
    render()
  elseif key == "base" then
    local branches = git.branches(f.project_root)
    if #branches == 0 then return end
    vim.ui.select(branches, { prompt = "Base branch" }, function(choice)
      if choice then
        f.base = choice
        render()
      end
    end)
  elseif key == "new_branch" then
    vim.ui.input({ prompt = "New branch: ", default = f.new_branch }, function(input)
      if input and input ~= "" then
        f.new_branch = input
        render()
      end
    end)
  end
end

local function move_focus(delta)
  local f = state.f
  f.focus = f.focus + delta
  if f.focus < 1 then f.focus = #state.order end
  if f.focus > #state.order then f.focus = 1 end
  render()
end

--- Open the new-session form for `agent` ("codex" | "claude").
function M.open(agent)
  if not cfg.options.agents[agent] then agent = "codex" end
  local f = { agent = agent, where = "local", focus = 1 }
  set_dir(f, default_dir())

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "agentpanel_form"

  local width = math.min(78, math.floor(vim.o.columns * 0.7))
  local height = 12
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.options.ui.border,
    title = " New session ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false

  state = { buf = buf, win = win, f = f }

  local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  map("j", function() move_focus(1) end)
  map("<Down>", function() move_focus(1) end)
  map("k", function() move_focus(-1) end)
  map("<Up>", function() move_focus(-1) end)
  map("<Tab>", function() move_focus(1) end)
  map("<S-Tab>", function() move_focus(-1) end)
  map("<CR>", edit_focused)
  map("<Space>", edit_focused) -- acts on the focused field (e.g. toggles Where)
  map("<C-s>", submit)
  map("q", close)
  map("<Esc>", close)

  render()
end

return M
