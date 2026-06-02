-- agentpanel.ui — the <Leader>m modal: a left rail of conversations grouped by
-- project (showing agent + worktree + last-active), and a right pane that
-- embeds the selected session's live agent terminal.
local cfg = require "agentpanel.config"
local store = require "agentpanel.store"
local term = require "agentpanel.terminal"
local util = require "agentpanel.util"
local editor = require "agentpanel.editor"

local api = vim.api
local M = {}
local ns = api.nvim_create_namespace "agentpanel_rail"

M.state = {
  open = false,
  win_rail = nil,
  win_pane = nil,
  win_hint = nil,
  win_backdrop = nil,
  buf_rail = nil,
  buf_placeholder = nil,
  buf_hint = nil,
  buf_backdrop = nil,
  pane_cfg = nil,
  current_id = nil,
  archived_expanded = false, -- whether the bottom "Archived" section is open
  archived_header_line = nil, -- rail line of the "Archived (N)" toggle
  line_to_id = {}, -- buffer line (1-indexed) -> session id
  session_lines = {}, -- ordered list of session line numbers
  nav_lines = {}, -- lines j/k stops on (sessions + archived header)
}

-- Highlights -------------------------------------------------------------

local did_hl = false
function M.setup_highlights()
  if did_hl then return end
  did_hl = true
  local set = function(name, opts) api.nvim_set_hl(0, name, opts) end
  set("AgentPanelSel", { link = "Visual", default = true })
  set("AgentPanelHeader", { link = "Comment", default = true })
  set("AgentPanelProject", { link = "Directory", bold = true, default = true })
  set("AgentPanelTime", { link = "Comment", default = true })
  set("AgentPanelWorktreeTag", { link = "Special", default = true })
  set("AgentPanelTabTag", { link = "Number", default = true })
  set("AgentPanelKey", { link = "Keyword", bold = true, default = true })
  set("AgentPanelTitle", { link = "Normal", default = true })
  set("AgentPanelCreate", { link = "String", bold = true, default = true })
  set("AgentPanelFormLabel", { link = "Comment", default = true })
  set("AgentPanelArchived", { link = "Comment", italic = true, default = true })
  set("AgentPanelHint", { link = "Comment", default = true })
  set("AgentPanelBackdrop", { link = "NormalFloat", default = true })
  set("AgentPanelAgentCodex", { fg = "#c792ea", bold = true })
  set("AgentPanelAgentClaude", { fg = "#e0935b", bold = true })
  set("AgentPanelSpinner", { fg = "#56b6c2", bold = true }) -- working: animated spinner
  set("AgentPanelBell", { fg = "#e5c07b", bold = true }) -- unread / awaiting input
end

-- Geometry ----------------------------------------------------------------

local function geom()
  local W, H = vim.o.columns, vim.o.lines
  local total_w = math.floor(W * cfg.options.ui.width)
  local height = math.floor(H * cfg.options.ui.height)
  local top = math.floor((H - height) / 2 - 1)
  local left = math.floor((W - total_w) / 2)
  local rail_w = math.min(cfg.options.ui.rail_width, math.floor(total_w * 0.42))
  local pane_left = left + rail_w + 3
  local pane_w = total_w - rail_w - 5
  if pane_w < 24 then pane_w = 24 end
  -- Reserve the bottom rows for a full-width shortcut hint line.
  local body_h = math.max(5, height - 3)
  local hint_row = top + body_h + 1
  -- Backdrop covers the whole modal bounding box (incl. borders + hint) so the
  -- editor never shows through the seam between the rail and the pane.
  local bd_row = math.max(0, top - 1)
  local bd_col = math.max(0, left - 1)
  return {
    height = body_h, -- height of the rail/pane content
    top = top,
    left = left,
    rail_w = rail_w,
    pane_left = pane_left,
    pane_w = pane_w,
    hint_row = hint_row,
    hint_col = left,
    hint_w = pane_left + pane_w - left,
    bd_row = bd_row,
    bd_col = bd_col,
    bd_w = (pane_left + pane_w + 1) - bd_col,
    bd_h = (hint_row + 1) - bd_row,
  }
end

-- Rail rendering ----------------------------------------------------------

-- Stable rail ordering: newest-created first, tie-broken by id for a total
-- deterministic order. Deliberately NOT last_active — selecting/opening a
-- session bumps last_active (for the time-ago column) and sorting on it would
-- make the list reshuffle on every click.
local function by_created(a, b)
  local ca, cb = a.created_at or 0, b.created_at or 0
  if ca ~= cb then return ca > cb end
  return (a.id or "") > (b.id or "")
end

-- Active (non-archived) sessions grouped by project. Projects are ordered by
-- their newest session; sessions within a project newest-first — both stable.
local function grouped()
  local by_proj, order = {}, {}
  local sessions = vim.deepcopy(store.all())
  table.sort(sessions, by_created)
  for _, s in ipairs(sessions) do
    if not (s.archived == true) then
      local key = s.project_root or s.project_name or "?"
      if not by_proj[key] then
        by_proj[key] = { name = s.project_name or vim.fn.fnamemodify(key, ":t"), items = {} }
        order[#order + 1] = key
      end
      table.insert(by_proj[key].items, s)
    end
  end
  return order, by_proj
end

-- Archived sessions, newest-created first (same stable order as the rail).
local function archived_list()
  local list = {}
  for _, s in ipairs(store.all()) do
    if s.archived == true then list[#list + 1] = s end
  end
  table.sort(list, by_created)
  return list
end

-- Build a single rail line for a session, returning the string and a list of
-- { col0, col1, group } byte-range highlights.
local function session_line(s, width)
  local agent = cfg.options.agents[s.agent] or cfg.options.agents.codex
  local time = util.rel_time(s.last_active)
  local wt = s.mode == "worktree" and (cfg.options.icons.worktree .. " ") or ""
  -- Tab badge: the nvim tab this session is currently open in, if any.
  local tabn = editor.assigned_tab(s)
  local tabtag = tabn and (cfg.options.icons.tab .. tabn .. " ") or ""
  local right = tabtag .. wt .. time
  local right_w = vim.fn.strdisplaywidth(right)

  local line, blen, dispw, hl = "", 0, 0, {}
  local function add(seg, group)
    local c0 = blen
    line = line .. seg
    blen = blen + #seg
    dispw = dispw + vim.fn.strdisplaywidth(seg)
    if group then hl[#hl + 1] = { c0, blen, group } end
  end

  -- status gutter: a 1-col margin, then a spinner (working) / bell (unread)
  -- badge, padded so the agent icon always lands at the same column.
  local glyph, ghl = require("agentpanel.activity").badge(s)
  add " "
  if glyph ~= "" then add(glyph, ghl) end
  if dispw < 4 then add(string.rep(" ", 4 - dispw)) end
  add(agent.icon, s.agent == "claude" and "AgentPanelAgentClaude" or "AgentPanelAgentCodex")
  add " "
  local title_w = width - dispw - right_w - 1
  if title_w < 4 then title_w = 4 end
  add(util.truncate(s.title or "(untitled)", title_w), s.archived and "AgentPanelArchived" or "AgentPanelTitle")
  -- pad to right-align the tab/worktree/time column
  local pad_to = width - right_w
  if dispw < pad_to then add(string.rep(" ", pad_to - dispw)) end
  if tabtag ~= "" then add(tabtag, "AgentPanelTabTag") end
  if wt ~= "" then add(cfg.options.icons.worktree .. " ", "AgentPanelWorktreeTag") end
  add(time, "AgentPanelTime")
  return line, hl
end

local function render_rail()
  local st = M.state
  if not (st.buf_rail and api.nvim_buf_is_valid(st.buf_rail)) then return end
  local width = geom().rail_w

  local lines, hls = {}, {} -- hls: { line0, col0, col1, group }
  st.line_to_id, st.session_lines, st.nav_lines, st.archived_header_line = {}, {}, {}, nil

  local function push(text) lines[#lines + 1] = text end
  local function hl(line0, c0, c1, group) hls[#hls + 1] = { line0, c0, c1, group } end
  -- Register a session row: maps the line to its id and makes it navigable.
  local function add_session(s)
    local text, lhl = session_line(s, width)
    push(text)
    local line0 = #lines - 1
    st.line_to_id[#lines] = s.id
    st.session_lines[#st.session_lines + 1] = #lines
    st.nav_lines[#st.nav_lines + 1] = #lines
    for _, h in ipairs(lhl) do
      hl(line0, h[1], h[2], h[3])
    end
  end

  push ""
  -- action row: cx / cc
  do
    local s = "   new:  "
    local l = s
    hl(1, #s, #s + 2, "AgentPanelKey")
    l = l .. "cx codex   "
    local base = #s + #"cx codex   "
    hl(1, base, base + 2, "AgentPanelKey")
    l = l .. "cc claude"
    push(l)
  end
  push("   " .. string.rep("─", math.max(0, width - 6)))

  local order, by_proj = grouped()
  if #order == 0 then
    push ""
    push "   No conversations yet."
    push ""
    push "   Press cx for a codex session"
    push "   or cc for a claude session."
  end

  for _, key in ipairs(order) do
    local proj = by_proj[key]
    push ""
    local header = "  " .. cfg.options.icons.local_dir .. " " .. util.truncate(proj.name, width - 5)
    push(header)
    hl(#lines - 1, 0, #header, "AgentPanelProject")
    for _, s in ipairs(proj.items) do
      add_session(s)
    end
  end

  -- Archived section: a collapsible group pinned at the bottom.
  local archived = archived_list()
  if #archived > 0 then
    push ""
    push("   " .. string.rep("─", math.max(0, width - 6)))
    local arrow = st.archived_expanded and "▾" or "▸"
    local header = "  " .. arrow .. " Archived (" .. #archived .. ")"
    push(header)
    st.archived_header_line = #lines
    st.nav_lines[#st.nav_lines + 1] = #lines
    hl(#lines - 1, 0, #header, "AgentPanelArchived")
    if st.archived_expanded then
      for _, s in ipairs(archived) do
        add_session(s)
      end
    end
  end

  table.sort(st.nav_lines)

  vim.bo[st.buf_rail].modifiable = true
  api.nvim_buf_set_lines(st.buf_rail, 0, -1, false, lines)
  vim.bo[st.buf_rail].modifiable = false

  api.nvim_buf_clear_namespace(st.buf_rail, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, st.buf_rail, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  M.highlight_selection()
end

--- Whether the modal is currently open. Used by agentpanel.activity to decide
--- whether a badge re-render is worth doing.
function M.is_open() return M.state.open == true end

--- Re-render the left rail (public entry for the activity monitor's spinner
--- animation and the terminal-exit handler). Safe to call when closed.
function M.render_rail()
  if M.state.open then render_rail() end
end

function M.highlight_selection()
  local st = M.state
  if not (st.buf_rail and api.nvim_buf_is_valid(st.buf_rail)) then return end
  api.nvim_buf_clear_namespace(st.buf_rail, ns + 1, 0, -1)
  for line, id in pairs(st.line_to_id) do
    if id == st.current_id then
      -- No end_row: line_hl_group with a range would shade the next line too.
      pcall(api.nvim_buf_set_extmark, st.buf_rail, ns + 1, line - 1, 0, {
        line_hl_group = "AgentPanelSel",
      })
    end
  end
end

-- Footer hint -------------------------------------------------------------

-- Full-width shortcut cheatsheet shown along the bottom of the modal. Items are
-- listed most-useful-first and only added while they fit, so a narrow terminal
-- drops trailing hints instead of clipping mid-text.
local function render_hint()
  local st = M.state
  if not (st.buf_hint and api.nvim_buf_is_valid(st.buf_hint)) then return end
  local width = geom().hint_w
  local sel = st.current_id and store.get(st.current_id) or nil
  local items = {
    { "↵", "open" },
    { "e", "edit → worktree tab" },
    { "c", "copilot sidecar" },
    { "F", "fork" },
    { "r", "rename" },
    { "a", (sel and sel.archived) and "unarchive" or "archive" },
    { "dd", "delete" },
    { "^h ^l", "switch pane" },
    { "q", "close" },
    { "A", st.archived_expanded and "hide archived" or "show archived" },
    { "cx cc", "new" },
  }
  local line, blen, dispw, hl = "  ", 2, 2, {}
  local function add(seg, group)
    local c0 = blen
    line = line .. seg
    blen = blen + #seg
    dispw = dispw + vim.fn.strdisplaywidth(seg)
    if group then hl[#hl + 1] = { c0, blen, group } end
  end
  for i, it in ipairs(items) do
    local sep = i > 1 and "  ·  " or ""
    local need = vim.fn.strdisplaywidth(sep .. it[1] .. " " .. it[2])
    if dispw + need > width then break end
    if sep ~= "" then add(sep) end
    add(it[1], "AgentPanelKey")
    add(" " .. it[2], "AgentPanelHint")
  end

  vim.bo[st.buf_hint].modifiable = true
  api.nvim_buf_set_lines(st.buf_hint, 0, -1, false, { line })
  vim.bo[st.buf_hint].modifiable = false
  api.nvim_buf_clear_namespace(st.buf_hint, ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(api.nvim_buf_set_extmark, st.buf_hint, ns, 0, h[1], { end_col = h[2], hl_group = h[3] })
  end
end

-- Pane --------------------------------------------------------------------

local function pane_title(s)
  if not s then return " session " end
  local where = s.mode == "worktree" and (cfg.options.icons.worktree .. " " .. (s.branch or "worktree"))
    or (cfg.options.icons.local_dir .. " " .. (s.branch ~= "" and s.branch or "local"))
  return util.truncate(" session  ·  " .. where .. " ", geom().pane_w)
end

local function set_pane_title(s)
  local st = M.state
  if not (st.win_pane and api.nvim_win_is_valid(st.win_pane) and st.pane_cfg) then return end
  st.pane_cfg.title = pane_title(s)
  pcall(api.nvim_win_set_config, st.win_pane, st.pane_cfg)
end

local function show_placeholder(s)
  local st = M.state
  if not (st.buf_placeholder and api.nvim_buf_is_valid(st.buf_placeholder)) then
    st.buf_placeholder = api.nvim_create_buf(false, true)
    vim.bo[st.buf_placeholder].bufhidden = "hide"
  end
  local body
  if not s then
    body = { "", "   No conversation selected.", "", "   cx  start a codex session", "   cc  start a claude session" }
  else
    local agent = cfg.options.agents[s.agent] or cfg.options.agents.codex
    -- A session that has run before (exited) or was restored from disk resumes;
    -- a brand-new one starts fresh (creating its worktree first if needed).
    local resuming = not s._fresh
    body = {
      "",
      "   " .. agent.icon .. "  " .. (s.title or ""),
      "",
      "   dir:    " .. vim.fn.fnamemodify(s.cwd, ":~"),
      "   branch: " .. (s.branch ~= "" and s.branch or "—"),
      "",
      "   ↵  " .. (resuming and ("resume " .. agent.label) or ("start " .. agent.label)),
    }
  end
  api.nvim_buf_set_lines(st.buf_placeholder, 0, -1, false, body)
  if st.win_pane and api.nvim_win_is_valid(st.win_pane) then
    api.nvim_win_set_buf(st.win_pane, st.buf_placeholder)
  end
end

--- Select a session by id (or nil): update rail highlight + pane preview.
--- Does NOT launch a terminal — only shows it if already alive.
function M.select(id)
  local st = M.state
  st.current_id = id
  M.highlight_selection()
  render_hint() -- the `a` hint reflects the selected conversation's archived state
  local s = id and store.get(id) or nil
  set_pane_title(s)
  if s and term.show(s, st.win_pane) then
    -- The session's latest output is now visible → clear its unread bell.
    require("agentpanel.activity").mark_read(s.id)
    return
  end
  show_placeholder(s)
end

--- Launch (if needed) and focus the selected session's terminal.
function M.open_selected()
  local st = M.state
  local s = st.current_id and store.get(st.current_id) or nil
  if not s then return end
  if not (st.win_pane and api.nvim_win_is_valid(st.win_pane)) then return end
  term.ensure(s, st.win_pane) -- sets its own <C-q> back-to-list keymap
  require("agentpanel.activity").mark_read(s.id)
  set_pane_title(s)
  store.touch(s.id)
  render_rail()
  api.nvim_set_current_win(st.win_pane)
  vim.schedule(function()
    if api.nvim_get_current_win() == st.win_pane then vim.cmd.startinsert() end
  end)
end

function M.focus_rail()
  local st = M.state
  if st.win_rail and api.nvim_win_is_valid(st.win_rail) then
    pcall(vim.cmd.stopinsert)
    api.nvim_set_current_win(st.win_rail)
  end
end

-- Navigation --------------------------------------------------------------

local function cursor_line() return api.nvim_win_get_cursor(M.state.win_rail)[1] end

local function goto_session(delta)
  local st = M.state
  local stops = st.nav_lines
  if #stops == 0 then return end
  local cur = cursor_line()
  local target
  if delta > 0 then
    for _, l in ipairs(stops) do
      if l > cur then
        target = l
        break
      end
    end
    target = target or stops[1]
  else
    for i = #stops, 1, -1 do
      if stops[i] < cur then
        target = stops[i]
        break
      end
    end
    target = target or stops[#stops]
  end
  api.nvim_win_set_cursor(st.win_rail, { target, 0 })
end

-- Sync selection to whatever session line the cursor is on.
local function on_cursor_moved()
  local st = M.state
  local id = st.line_to_id[cursor_line()]
  if id and id ~= st.current_id then M.select(id) end
end

-- Actions -----------------------------------------------------------------

local function current_session()
  local st = M.state
  local id = st.line_to_id[cursor_line()] or st.current_id
  return id and store.get(id) or nil
end

-- Expand/collapse the bottom "Archived" section, keeping the cursor on it.
local function toggle_archived_section()
  local st = M.state
  st.archived_expanded = not st.archived_expanded
  render_rail()
  render_hint()
  if st.archived_header_line then
    pcall(api.nvim_win_set_cursor, st.win_rail, { st.archived_header_line, 0 })
  end
end

-- <CR>/click on the rail: toggle the archived section if on its header,
-- otherwise open the conversation under the cursor.
local function rail_enter()
  if cursor_line() == M.state.archived_header_line then
    toggle_archived_section()
  else
    M.open_selected()
  end
end

local function action_edit()
  local s = current_session()
  if not s then return end
  M.close()
  require("agentpanel.editor").open(s)
end

-- `c`: like `e`, but also drops this session's terminal into a copilot sidecar
-- in its worktree tab (creating the tab if needed).
local function action_copilot()
  local s = current_session()
  if not s then return end
  M.close()
  require("agentpanel.editor").open_sidecar(s)
end

-- After the visible set changes, re-render and put the cursor on a sensible row.
local function reselect()
  render_rail()
  if #M.state.session_lines > 0 then
    api.nvim_win_set_cursor(M.state.win_rail, { M.state.session_lines[1], 0 })
    on_cursor_moved()
  else
    M.select(nil)
  end
end

local function action_delete()
  local s = current_session()
  if not s then return end
  local choice = vim.fn.confirm("Delete session “" .. (s.title or "") .. "”?", "&Yes\n&No", 2)
  if choice ~= 1 then return end
  term.close(s)
  store.remove(s.id)
  if M.state.current_id == s.id then M.state.current_id = nil end
  reselect()
end

local function action_rename()
  local s = current_session()
  if not s then return end
  vim.ui.input({ prompt = "Title: ", default = s.title }, function(input)
    if input and input ~= "" then
      s.title = input
      store.save()
      render_rail()
    end
  end)
end

-- `F`: fork the selected conversation. Creates a NEW session that branches off
-- the source's history — the two then diverge independently — and runs in the
-- SAME worktree/cwd as the source. Both codex and claude support forking
-- natively (see agent.fork_id); the first launch issues the fork command and
-- the new conversation's own id is captured for subsequent resumes.
local function action_fork()
  local s = current_session()
  if not s then return end
  local agent = cfg.options.agents[s.agent]
  if not (agent and agent.fork_id) then
    vim.notify("agentpanel: " .. tostring(s.agent) .. " can't fork sessions", vim.log.levels.WARN)
    return
  end
  if not s.agent_session_id then
    vim.notify("agentpanel: open this session once before forking (no captured id yet)", vim.log.levels.WARN)
    return
  end
  local fork = {
    id = util.uid(),
    title = (s.title or agent.label) .. " (fork)",
    agent = s.agent,
    project_name = s.project_name,
    project_root = s.project_root,
    cwd = s.cwd, -- same worktree / dir as the source
    mode = s.mode,
    worktree = s.worktree and vim.deepcopy(s.worktree) or nil,
    branch = s.branch,
    created_at = os.time(),
    last_active = os.time(),
    _fork_from = s.agent_session_id, -- consumed on first launch (terminal.launch_spec)
  }
  store.add(fork)
  M.after_create(fork.id)
end

-- Toggle the selected conversation's archived flag. Archiving moves it to the
-- bottom "Archived" section; unarchiving returns it to its project group.
local function action_archive()
  local s = current_session()
  if not s then return end
  s.archived = not (s.archived == true)
  store.save()
  if M.state.current_id == s.id then M.state.current_id = nil end
  reselect()
  render_hint()
end

-- Open/close --------------------------------------------------------------

local function setup_rail_keymaps(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("j", function() goto_session(1) end, "Next conversation")
  map("k", function() goto_session(-1) end, "Prev conversation")
  map("<Down>", function() goto_session(1) end)
  map("<Up>", function() goto_session(-1) end)
  map("<CR>", rail_enter, "Open / toggle archived")
  map("l", rail_enter)
  map("<Tab>", rail_enter)
  -- Window-style navigation within the modal (smart-splits can't cross floats):
  -- <C-l> enters the session pane; <C-j>/<C-k> move through the list; <C-h>
  -- stays (rail is leftmost) so focus can't escape behind the modal.
  map("<C-l>", function() M.open_selected() end, "Focus session pane")
  map("<C-j>", function() goto_session(1) end)
  map("<C-k>", function() goto_session(-1) end)
  map("<C-h>", function() end)
  -- Mouse: click a conversation to open it, or the Archived header to expand.
  map("<LeftRelease>", function()
    local line = cursor_line()
    if line == M.state.archived_header_line then
      toggle_archived_section()
    elseif M.state.line_to_id[line] then
      M.select(M.state.line_to_id[line])
      M.open_selected()
    end
  end)
  map("e", action_edit, "Drop into editor at worktree")
  -- `c` overlaps the cx/cc prefixes, so it must NOT be nowait: vim waits to see
  -- if cx/cc follow, otherwise fires the copilot drop-in.
  vim.keymap.set("n", "c", action_copilot, { buffer = buf, silent = true, desc = "Drop session into copilot sidecar" })
  map("cx", function() require("agentpanel.newsession").open "codex" end, "New codex session")
  map("cc", function() require("agentpanel.newsession").open "claude" end, "New claude session")
  map("F", action_fork, "Fork conversation (same worktree)")
  map("r", action_rename, "Rename conversation")
  map("a", action_archive, "Archive/unarchive conversation")
  map("A", toggle_archived_section, "Toggle archived section")
  map("dd", action_delete, "Delete conversation")
  map("x", action_delete, "Delete conversation")
  map("q", function() M.close() end, "Close panel")
  map("<Esc>", function() M.close() end, "Close panel")
end

function M.open()
  M.setup_highlights()
  local st = M.state
  if st.open then return end

  local g = geom()

  -- backdrop: a solid panel behind everything so the editor never shows through
  -- the seam between the rail and the pane.
  st.buf_backdrop = api.nvim_create_buf(false, true)
  vim.bo[st.buf_backdrop].bufhidden = "wipe"
  st.backdrop_cfg = {
    relative = "editor",
    width = g.bd_w,
    height = g.bd_h,
    row = g.bd_row,
    col = g.bd_col,
    style = "minimal",
    focusable = false,
    zindex = 45, -- below the rail/pane (50) and hint (60), above the editor
  }
  st.win_backdrop = api.nvim_open_win(st.buf_backdrop, false, st.backdrop_cfg)
  vim.wo[st.win_backdrop].winhighlight = "Normal:AgentPanelBackdrop,NormalNC:AgentPanelBackdrop"

  st.buf_rail = api.nvim_create_buf(false, true)
  vim.bo[st.buf_rail].bufhidden = "wipe"
  vim.bo[st.buf_rail].filetype = "agentpanel"

  st.rail_cfg = {
    relative = "editor",
    width = g.rail_w,
    height = g.height,
    row = g.top,
    col = g.left,
    style = "minimal",
    border = cfg.options.ui.border,
    title = " Agents ",
    title_pos = "left",
  }
  st.win_rail = api.nvim_open_win(st.buf_rail, true, st.rail_cfg)
  vim.wo[st.win_rail].cursorline = false
  vim.wo[st.win_rail].wrap = false

  -- pane (start showing a placeholder buffer)
  if not (st.buf_placeholder and api.nvim_buf_is_valid(st.buf_placeholder)) then
    st.buf_placeholder = api.nvim_create_buf(false, true)
    vim.bo[st.buf_placeholder].bufhidden = "hide"
  end
  st.pane_cfg = {
    relative = "editor",
    width = g.pane_w,
    height = g.height,
    row = g.top,
    col = g.pane_left,
    style = "minimal",
    border = cfg.options.ui.border,
    title = " session ",
    title_pos = "left",
  }
  st.win_pane = api.nvim_open_win(st.buf_placeholder, false, st.pane_cfg)
  vim.wo[st.win_pane].wrap = false

  -- hint line: a non-focusable, borderless full-width strip along the bottom
  st.buf_hint = api.nvim_create_buf(false, true)
  vim.bo[st.buf_hint].bufhidden = "wipe"
  st.hint_cfg = {
    relative = "editor",
    width = g.hint_w,
    height = 1,
    row = g.hint_row,
    col = g.hint_col,
    style = "minimal",
    focusable = false,
    zindex = 60,
  }
  st.win_hint = api.nvim_open_win(st.buf_hint, false, st.hint_cfg)

  setup_rail_keymaps(st.buf_rail)

  local grp = api.nvim_create_augroup("AgentPanelRail", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = grp,
    buffer = st.buf_rail,
    callback = on_cursor_moved,
  })
  -- The floats are one logical modal: if any is closed by any means (:q,
  -- <C-w>c, etc.), tear the whole thing down together.
  api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(args)
      if not M.state.open then return end
      local w = tonumber(args.match)
      if w == M.state.win_rail or w == M.state.win_pane or w == M.state.win_hint or w == M.state.win_backdrop then
        vim.schedule(M.close)
      end
    end,
  })
  -- Follow terminal/editor resizes so the modal always fills the screen.
  api.nvim_create_autocmd("VimResized", {
    group = grp,
    callback = function() vim.schedule(M.relayout) end,
  })
  -- Safety net: whenever a terminal is entered/shown in the session pane, make
  -- sure the back-to-rail nav keymaps are present on it, so they can never be
  -- lost (e.g. if an agent churns its own buffer during a self-upgrade).
  api.nvim_create_autocmd({ "TermEnter", "BufEnter" }, {
    group = grp,
    callback = function(args)
      local st = M.state
      if st.win_pane and api.nvim_win_is_valid(st.win_pane) and api.nvim_win_get_buf(st.win_pane) == args.buf then
        if vim.bo[args.buf].buftype == "terminal" then require("agentpanel.terminal").apply_nav_keymaps(args.buf) end
      end
    end,
  })

  st.open = true
  render_rail()
  render_hint()

  -- initial selection: keep prior current_id if still present, else newest
  local want = st.current_id
  if not (want and store.get(want)) then
    want = st.line_to_id[st.session_lines[1] or -1]
  end
  if want then
    for _, l in ipairs(st.session_lines) do
      if st.line_to_id[l] == want then
        api.nvim_win_set_cursor(st.win_rail, { l, 0 })
        break
      end
    end
    M.select(want)
  else
    M.select(nil)
  end
end

-- Recompute geometry and re-apply it to all three floats (called on resize).
function M.relayout()
  local st = M.state
  if not st.open then return end
  local g = geom()
  local function reapply(win, c, fields)
    if not (win and api.nvim_win_is_valid(win) and c) then return end
    for k, v in pairs(fields) do
      c[k] = v
    end
    pcall(api.nvim_win_set_config, win, c)
  end
  reapply(st.win_backdrop, st.backdrop_cfg, { width = g.bd_w, height = g.bd_h, row = g.bd_row, col = g.bd_col })
  reapply(st.win_rail, st.rail_cfg, { width = g.rail_w, height = g.height, row = g.top, col = g.left })
  reapply(st.win_pane, st.pane_cfg, { width = g.pane_w, height = g.height, row = g.top, col = g.pane_left })
  reapply(st.win_hint, st.hint_cfg, { width = g.hint_w, height = 1, row = g.hint_row, col = g.hint_col })
  render_rail() -- rail_w may have changed → re-truncate rows
  render_hint() -- hint_w may have changed → re-fit shortcuts
end

function M.close()
  local st = M.state
  if not st.open then return end
  -- Flip state + clear window handles first so the WinClosed autocmd (fired as
  -- we close each window) sees the modal as already-closing and no-ops.
  st.open = false
  local pane, rail, hint, backdrop = st.win_pane, st.win_rail, st.win_hint, st.win_backdrop
  st.win_pane, st.win_rail, st.win_hint, st.win_backdrop = nil, nil, nil, nil
  pcall(api.nvim_del_augroup_by_name, "AgentPanelRail")
  pcall(vim.cmd.stopinsert)
  if hint and api.nvim_win_is_valid(hint) then pcall(api.nvim_win_close, hint, true) end
  if pane and api.nvim_win_is_valid(pane) then pcall(api.nvim_win_close, pane, true) end
  if rail and api.nvim_win_is_valid(rail) then pcall(api.nvim_win_close, rail, true) end
  if backdrop and api.nvim_win_is_valid(backdrop) then pcall(api.nvim_win_close, backdrop, true) end
end

function M.toggle()
  if M.state.open then
    M.close()
  else
    M.open()
  end
end

--- Called by the new-session form after a session is created.
function M.after_create(id)
  if not M.state.open then M.open() end
  M.state.current_id = id
  render_rail()
  for _, l in ipairs(M.state.session_lines) do
    if M.state.line_to_id[l] == id then
      pcall(api.nvim_win_set_cursor, M.state.win_rail, { l, 0 })
      break
    end
  end
  M.select(id)
  M.open_selected()
end

return M
