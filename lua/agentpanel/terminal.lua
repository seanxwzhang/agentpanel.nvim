-- agentpanel.terminal — one long-lived terminal per session.
--
-- Session model (deliberately simple & robust):
--   * A session IS a terminal buffer + job. There is exactly one per session
--     for its whole lifetime; we never swap buffers mid-session, so anything
--     the agent does to itself (self-upgrade, re-exec, sub-shells) stays inside
--     that one pty and our keymaps survive.
--   * First launch of a worktree session runs `git worktree add` first, then
--     `exec`s the agent in the new worktree — all in the same terminal. The
--     git step is a separate statement (not `&&`), so a post-checkout hook that
--     SIGPIPEs (git-lfs/husky → exit 141) can't stop the agent from starting.
--   * First launch of a local session just `exec`s the agent in its cwd.
--   * Re-opening a stopped session (process exited, or restored from disk on a
--     fresh nvim) relaunches with the agent's resume command
--     (`codex resume --last` / `claude --continue`).
local cfg = require "agentpanel.config"
local store = require "agentpanel.store"

local M = {}
-- id -> { buf, job, status = "running"|"exited" }
M.runtime = {}

function M.is_alive(session)
  local rt = M.runtime[session.id]
  if not rt or not rt.buf or not vim.api.nvim_buf_is_valid(rt.buf) then return false end
  return rt.status == "running"
end

function M.buf(session)
  local rt = M.runtime[session.id]
  if rt and rt.buf and vim.api.nvim_buf_is_valid(rt.buf) then return rt.buf end
  return nil
end

local function shelljoin(list)
  local parts = {}
  for _, a in ipairs(list) do
    parts[#parts + 1] = vim.fn.shellescape(a)
  end
  return table.concat(parts, " ")
end

local function first_existing_dir(...)
  for _, d in ipairs { ... } do
    if d and d ~= "" and vim.fn.isdirectory(d) == 1 then return d end
  end
  return vim.fn.expand "~"
end

-- Context-aware window navigation for a session terminal.
--   * Inside the modal pane (a float smart-splits can't traverse): <C-h>/<C-q>
--     jump back to the rail, and the other directions are swallowed so focus
--     can't escape the modal to a window behind it.
--   * Anywhere else (e.g. dropped into a sidecar split via `c`): behave like
--     normal window navigation so the keys keep working.
local function nav(dir)
  local ui = require "agentpanel.ui"
  local in_modal = ui.state.open
    and ui.state.win_pane
    and vim.api.nvim_win_is_valid(ui.state.win_pane)
    and vim.api.nvim_get_current_win() == ui.state.win_pane
  if in_modal then
    if dir == "h" or dir == "rail" then ui.focus_rail() end
    return
  end
  pcall(vim.cmd.stopinsert)
  pcall(vim.cmd, "wincmd " .. (dir == "rail" and "h" or dir))
end

--- Apply the nav keymaps to a session terminal buffer (idempotent). Re-appliable
--- as a safety net via ui's TermEnter/BufEnter autocmd.
function M.apply_nav_keymaps(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "n", "t" }, "<C-q>", function() nav "rail" end, vim.tbl_extend("force", opts, { desc = "agentpanel: list / window-left" }))
  for _, k in ipairs { "h", "j", "k", "l" } do
    vim.keymap.set({ "n", "t" }, "<C-" .. k .. ">", function() nav(k) end, opts)
  end
end

-- Delete a buffer, first detaching it from any window showing it. Deleting a
-- buffer that is currently displayed in a floating window would close that
-- window, so we swap those windows to a throwaway scratch buffer first.
local function wipe_buf(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_buf, win, vim.api.nvim_create_buf(false, true))
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function needs_worktree(session)
  return session.mode == "worktree" and session.worktree and vim.fn.isdirectory(session.cwd) == 0
end

-- Session-id capture ------------------------------------------------------
--
-- The rail's session id (store uid) is ours, not the agent's. To resume the
-- EXACT conversation we launched — instead of "the most recent" — we read the
-- real agent session id out of the CLI's on-disk session log shortly after
-- launch, keyed by the session's unique cwd, and persist it on the session.
-- Resume then uses `<resume_id> <id>` (see launch_spec). Capture runs after
-- every launch and only ever overwrites the stored id when it finds a matching
-- log, so a launch that writes nothing yet leaves the previous id intact.

local function same_path(a, b)
  if not a or not b then return false end
  return a == b or vim.fn.resolve(a) == vim.fn.resolve(b)
end

-- Newest codex rollout (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) whose
-- session_meta cwd matches and which was written at/after this launch.
local function find_codex_id(session, launch_time)
  local dir = vim.fn.expand "~/.codex/sessions/" .. os.date("%Y/%m/%d", launch_time)
  if vim.fn.isdirectory(dir) == 0 then return nil end
  local best_id, best_mtime
  for _, f in ipairs(vim.fn.globpath(dir, "rollout-*.jsonl", false, true)) do
    local mtime = vim.fn.getftime(f)
    if mtime >= launch_time - 2 and (not best_mtime or mtime >= best_mtime) then
      local first = (vim.fn.readfile(f, "", 1) or {})[1]
      local ok, obj = pcall(vim.json.decode, first or "")
      local p = ok and type(obj) == "table" and obj.payload or nil
      -- Skip the source conversation when capturing a fork's id: the fork runs
      -- in the source's cwd, so a still-warm source log could otherwise win.
      if p and p.id and p.id ~= session._fork_from and same_path(p.cwd, session.cwd) then
        best_id, best_mtime = p.id, mtime
      end
    end
  end
  return best_id
end

-- Newest claude conversation (~/.claude/projects/<cwd-slug>/<id>.jsonl) for the
-- session's cwd, written at/after launch. The filename IS the session id.
local function find_claude_id(session, launch_time)
  local dir = vim.fn.expand "~/.claude/projects/" .. (session.cwd or ""):gsub("[/.]", "-")
  if vim.fn.isdirectory(dir) == 0 then return nil end
  local best_id, best_mtime
  for _, f in ipairs(vim.fn.globpath(dir, "*.jsonl", false, true)) do
    local mtime = vim.fn.getftime(f)
    local id = vim.fn.fnamemodify(f, ":t:r") -- filename IS the session id
    -- Skip the source conversation when capturing a fork's id (same cwd slug).
    if id ~= session._fork_from and mtime >= launch_time - 2 and (not best_mtime or mtime >= best_mtime) then
      best_id, best_mtime = id, mtime
    end
  end
  return best_id
end

-- Poll for the agent session id for a few seconds after launch (the log appears
-- a beat after the process starts) and persist it on the session when found.
local function capture_session_id(session)
  local launch_time = os.time()
  local finder = session.agent == "claude" and find_claude_id or find_codex_id
  local tries = 0
  local function attempt()
    tries = tries + 1
    local id = finder(session, launch_time)
    if id then
      local s = store.get(session.id) or session
      if s.agent_session_id ~= id then
        s.agent_session_id = id
        store.save()
      end
    elseif tries < 10 then
      vim.defer_fn(attempt, 1000)
    end
  end
  vim.defer_fn(attempt, 800)
end

-- Resolve the command + cwd for a session's single terminal.
local function launch_spec(session)
  local agent = cfg.options.agents[session.agent] or cfg.options.agents.codex
  -- _fresh: created this nvim run and never launched -> start command.
  -- Otherwise resume: by captured session id when we have one (exact
  -- conversation), else fall back to the agent's "most recent" resume command.
  local agentcmd
  if session._fresh then
    agentcmd = agent.cmd
  elseif session.agent_session_id and agent.resume_id then
    -- Once we've captured our OWN id (a fork mints a fresh one on first launch),
    -- resume that exact conversation. Checked before _fork_from so re-opening a
    -- fork resumes it rather than forking the source again.
    agentcmd = vim.list_extend(vim.deepcopy(agent.resume_id), { session.agent_session_id })
  elseif session._fork_from and agent.fork_id then
    -- First launch of a fork: branch a new conversation off the source's id.
    agentcmd = vim.list_extend(vim.deepcopy(agent.fork_id), { session._fork_from })
  else
    agentcmd = agent.resume or agent.cmd
  end

  if needs_worktree(session) then
    -- Create the worktree, then exec the (fresh) agent inside it. A fresh
    -- worktree means _fresh is true, so agentcmd is the normal start command.
    local wt = session.worktree
    local add = { "git", "-C", session.project_root, "worktree", "add", "-b", wt.branch, wt.path }
    if wt.base and wt.base ~= "" then add[#add + 1] = wt.base end
    local script = table.concat({
      shelljoin(add), -- standalone: its exit code is intentionally ignored
      "cd " .. vim.fn.shellescape(wt.path) .. " && exec " .. shelljoin(agentcmd),
    }, "\n")
    return { "/bin/sh", "-c", script }, first_existing_dir(session.project_root, session.cwd)
  end

  -- Local or resume: run the agent directly in its cwd.
  return vim.deepcopy(agentcmd), first_existing_dir(session.cwd, session.project_root)
end

--- Ensure a live terminal exists for `session`, displayed in `win`. Launches or
--- resumes it as needed and returns the terminal buffer.
function M.ensure(session, win)
  if M.is_alive(session) then
    local b = M.buf(session)
    if b and win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_buf(win, b) end
    return b
  end

  local prev = M.runtime[session.id]
  local cmd, cwd = launch_spec(session)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  -- Now that the pane shows the new buffer, drop the old dead one (if any).
  if prev and prev.buf and prev.buf ~= buf then wipe_buf(prev.buf) end
  local job
  vim.api.nvim_win_call(win, function()
    job = vim.fn.jobstart(cmd, {
      term = true,
      cwd = cwd,
      on_exit = function()
        local rt = M.runtime[session.id]
        if rt then
          rt.status = "exited"
          rt.activity, rt.unread = nil, nil
        end
        -- Drop the spinner immediately if the panel is showing this session.
        local ok, ui = pcall(require, "agentpanel.ui")
        if ok and ui.is_open() then ui.render_rail() end
      end,
    })
  end)
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].agentpanel_session = session.id
  M.apply_nav_keymaps(buf)
  M.runtime[session.id] = { buf = buf, job = job, status = job > 0 and "running" or "exited" }
  session._fresh = false -- next launch resumes
  store.touch(session.id)
  -- Learn (or refresh) the agent's own session id so the next resume targets
  -- THIS conversation rather than "the most recent" one.
  if job > 0 then
    capture_session_id(session)
    if cfg.options.activity and cfg.options.activity.enabled then
      -- Treat the launch itself as activity, then let the monitor watch the pty:
      -- it'll fall to "waiting" once the agent settles at its prompt.
      local rt = M.runtime[session.id]
      rt.activity, rt._last_change = "working", (vim.uv or vim.loop).now()
      require("agentpanel.activity").start()
    end
  end
  return buf
end

--- Show the session's terminal in `win` if alive; otherwise return false so the
--- caller can show a placeholder (avoids auto-launching on mere selection).
function M.show(session, win)
  local b = M.buf(session)
  if b and win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_buf(win, b)
    return true
  end
  return false
end

--- Stop the agent and drop its buffer.
function M.close(session)
  local rt = M.runtime[session.id]
  if rt then
    if rt.job and rt.job > 0 then pcall(vim.fn.jobstop, rt.job) end
    wipe_buf(rt.buf)
    M.runtime[session.id] = nil
  end
end

return M
