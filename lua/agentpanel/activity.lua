-- agentpanel.activity — per-session liveness for the rail's status badge.
--
-- We hook the AGENT'S OWN session log (the JSONL that codex/claude append to as
-- they work) rather than diffing the terminal screen. Focusing or switching to
-- a session repaints its TUI (cursor, footer, reflow) but writes NOTHING to the
-- log, so it no longer false-flags as "working".
--
-- Per running session we resolve its log file (by captured agent_session_id +
-- cwd) and classify it from two signals:
--   * recent writes — the log grew within `idle_ms` → actively producing output
--   * turn state    — the last lifecycle/message entry, which says whether the
--                     turn is still in flight or has yielded back to the human:
--                       codex : event_msg task_started / user_message  → working
--                               event_msg task_complete / turn_aborted → done
--                       claude: assistant stop_reason "tool_use"       → working
--                               trailing user (prompt / tool_result)   → working
--                               assistant stop_reason "end_turn" / …   → done
-- A session is "working" if it wrote recently OR its turn is mid-flight — so a
-- long-running tool that is silent on disk still counts as working (no false
-- "done"). On the working→done edge we mark the session unread (bell badge) and,
-- unless the user is already looking at it, fire a notification.
--
-- Sessions without a resolvable log (id not captured yet) fall back to the older
-- terminal-tail heuristic so they still animate until capture takes over.
--
-- Runtime activity is stored on terminal.runtime[id] (transient, never
-- persisted): { activity, unread, _log_path, _log_sig, _last_write, _turn,
-- _snap, _last_change }.
local cfg = require "agentpanel.config"

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}
M.frame = 0 -- spinner animation frame, advanced once per tick
local timer = nil -- active vim.fn.timer id while monitoring, else nil
local did_autocmd = false

local function opts() return cfg.options.activity end

-- Log resolution ----------------------------------------------------------
--
-- Map a session to the on-disk conversation log the agent writes. Cached on the
-- runtime once found (the file never moves); re-resolved if it disappears.
local function resolve_log(rt, session)
  if rt._log_path and vim.fn.filereadable(rt._log_path) == 1 then return rt._log_path end
  rt._log_path = nil
  local id = session and session.agent_session_id
  if not id or id == "" then return nil end
  if session.agent == "claude" then
    -- ~/.claude/projects/<cwd-slug>/<id>.jsonl — the filename IS the id.
    local slug = (session.cwd or ""):gsub("[/.]", "-")
    local p = vim.fn.expand "~/.claude/projects/" .. slug .. "/" .. id .. ".jsonl"
    if vim.fn.filereadable(p) == 1 then
      rt._log_path = p
      return p
    end
  else
    -- ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl — id is in the name.
    local m = vim.fn.glob(vim.fn.expand "~/.codex/sessions" .. "/**/rollout-*" .. id .. ".jsonl", true, true)
    if type(m) == "table" and m[1] then
      rt._log_path = m[1]
      return m[1]
    end
  end
  return nil
end

-- Read the last chunk of a (possibly large) log without loading the whole file.
local TAIL_BYTES = 256 * 1024

local function read_tail_lines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek "end" or 0
  local from = math.max(0, size - TAIL_BYTES)
  f:seek("set", from)
  local data = f:read "*a" or ""
  f:close()
  local lines = vim.split(data, "\n", { plain = true })
  if from > 0 and #lines > 1 then table.remove(lines, 1) end -- drop the partial first line
  return lines
end

-- Classify the turn from the tail: "working" (turn in flight) | "waiting" (turn
-- yielded to the human) | nil (couldn't tell — caller holds the current state).
local function parse_turn(path, agent)
  local lines = read_tail_lines(path)
  if not lines then return nil end
  for i = #lines, 1, -1 do
    local ln = lines[i]
    if ln ~= "" then
      local ok, o = pcall(vim.json.decode, ln)
      if ok and type(o) == "table" then
        if agent == "claude" then
          if o.type == "assistant" then
            local sr = (o.message or {}).stop_reason
            return (sr == "tool_use") and "working" or "waiting"
          elseif o.type == "user" then
            return "working" -- a human prompt or a tool_result → assistant owes a reply
          end
        elseif o.type == "event_msg" and o.payload then
          local pt = o.payload.type
          if pt == "task_complete" or pt == "turn_aborted" then return "waiting" end
          if pt == "task_started" or pt == "user_message" then return "working" end
        end
      end
    end
  end
  return nil
end

-- "working" | "waiting" from the agent log, or nil if it has no log yet.
local function classify_from_log(rt, session, now)
  local path = resolve_log(rt, session)
  if not path then return nil end
  local st = uv.fs_stat(path)
  if not st then
    rt._log_path = nil
    return nil
  end
  local sig = string.format("%d:%d.%d", st.size, st.mtime.sec, st.mtime.nsec or 0)
  if rt._log_sig ~= sig then
    rt._log_sig = sig
    rt._last_write = now
    rt._turn = parse_turn(path, session.agent)
  end
  local fresh = rt._last_write and (now - rt._last_write) < (opts().idle_ms or 1200)
  if fresh or rt._turn == "working" then return "working" end
  if rt._turn == "waiting" then return "waiting" end
  return rt.activity -- quiet but state unknown: hold whatever we had
end

-- Snapshot the tail of a terminal buffer — the legacy fallback for sessions with
-- no resolvable agent log (e.g. id not captured yet). A change between snapshots
-- means it is still producing output.
local function snapshot(buf)
  if not (buf and api.nvim_buf_is_valid(buf)) then return nil end
  local n = api.nvim_buf_line_count(buf)
  local from = math.max(0, n - (opts().snapshot_lines or 60))
  return table.concat(api.nvim_buf_get_lines(buf, from, n, false), "\n")
end

local function classify_from_snapshot(rt, now)
  local snap = snapshot(rt.buf)
  if snap ~= rt._snap then
    rt._snap = snap
    rt._last_change = now
    return "working"
  elseif now - (rt._last_change or now) >= (opts().idle_ms or 1200) then
    return "waiting"
  end
  return rt.activity
end

-- Is `buf` visible in any window on the current tab? A session the user can
-- see is treated as already read: no bell, no notification.
local function is_visible(buf)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then return true end
  end
  return false
end

-- Play an audible alert (non-blocking) for the "finished, awaiting input" event.
-- vim.notify alone is silent; this gives a real sound even when nvim is in the
-- background. macOS: afplay a system sound; configurable via activity.sound_name.
local function play_sound()
  local a = opts()
  if not a.sound then return end
  local name = a.sound_name or "Glass"
  local cmd
  if type(name) == "table" then
    cmd = name -- explicit command, e.g. { "paplay", "/path/to.ogg" }
  elseif name:find "/" then
    cmd = { "afplay", name } -- absolute path to an audio file
  else
    cmd = { "afplay", "/System/Library/Sounds/" .. name .. ".aiff" } -- named macOS sound
  end
  pcall(function()
    if vim.system then
      vim.system(cmd, { text = false }) -- async; we never wait on it
    else
      vim.fn.jobstart(cmd, { detach = true })
    end
  end)
end

local function notify_waiting(session)
  local agent = cfg.options.agents[session.agent] or cfg.options.agents.codex
  if opts().notify then
    vim.notify(
      (session.title or agent.label) .. " is waiting for your input",
      vim.log.levels.INFO,
      { title = "Agents  " .. agent.icon .. " " .. agent.label, icon = cfg.options.icons.bell }
    )
  end
  play_sound()
end

-- One detection pass over every live session. Returns true if any badge-visible
-- state changed (so the caller knows to re-render the rail).
local function detect()
  local term = require "agentpanel.terminal"
  local store = require "agentpanel.store"
  local now = uv.now()
  local changed = false
  for id, rt in pairs(term.runtime) do
    if rt.status == "running" and rt.buf and api.nvim_buf_is_valid(rt.buf) then
      -- Authoritative signal: the agent's own session log. Fall back to the
      -- terminal-tail heuristic only while no log is resolvable.
      local state = classify_from_log(rt, store.get(id), now)
      if state == nil then state = classify_from_snapshot(rt, now) end

      if state == "working" then
        if rt.activity ~= "working" then
          rt.activity = "working"
          changed = true
        end
      elseif state == "waiting" then
        if rt.activity == "working" then
          -- working → done edge: the turn yielded back to the human.
          rt.activity = "waiting"
          changed = true
          local s = store.get(id)
          if s and not is_visible(rt.buf) then
            rt.unread = true
            notify_waiting(s)
          end
        elseif rt.activity == nil then
          rt.activity = "waiting" -- settle an unknown initial state without notifying
        end
      end
    end
  end
  return changed
end

local function any_running()
  local term = require "agentpanel.terminal"
  for _, rt in pairs(term.runtime) do
    if rt.status == "running" then return true end
  end
  return false
end

local function any_working()
  local term = require "agentpanel.terminal"
  for _, rt in pairs(term.runtime) do
    if rt.status == "running" and rt.activity == "working" then return true end
  end
  return false
end

local function rerender_if_open()
  local ui = require "agentpanel.ui"
  if ui.is_open() then ui.render_rail() end
end

local function tick()
  M.frame = M.frame + 1
  local changed = detect()
  if not any_running() then
    -- Nothing left to watch: stop the timer, but render once so a just-exited
    -- session drops its spinner.
    M.stop()
    rerender_if_open()
    return
  end
  -- Re-render to advance the spinner (while anything is working) or to reflect a
  -- working↔waiting/unread change. Skip entirely when the panel is closed.
  if changed or any_working() then rerender_if_open() end
end

-- Entering a session's terminal (modal pane or copilot sidecar) marks it read.
function M.ensure_autocmd()
  if did_autocmd then return end
  did_autocmd = true
  api.nvim_create_autocmd({ "BufEnter", "TermEnter" }, {
    group = api.nvim_create_augroup("AgentPanelActivity", { clear = true }),
    callback = function(args)
      local id = vim.b[args.buf].agentpanel_session
      if id then M.mark_read(id) end
    end,
  })
end

--- Start the shared monitor (idempotent). Called when a session terminal is
--- launched; runs until every session has exited, independent of the panel so
--- "finished" notifications fire even while the modal is closed.
function M.start()
  if not opts().enabled then return end
  M.ensure_autocmd()
  if timer then return end
  timer = vim.fn.timer_start(opts().poll_ms or 120, tick, { ["repeat"] = -1 })
end

function M.stop()
  if timer then
    pcall(vim.fn.timer_stop, timer)
    timer = nil
  end
end

--- Clear a session's unread flag (the user has now seen its latest output) and
--- refresh the rail badge.
function M.mark_read(id)
  local rt = require("agentpanel.terminal").runtime[id]
  if rt and rt.unread then
    rt.unread = nil
    rerender_if_open()
  end
end

--- The rail badge for `session`: an animated spinner while working, a bell while
--- there is unread output, otherwise nothing. Returns (glyph, highlight_group).
function M.badge(session)
  local rt = require("agentpanel.terminal").runtime[session.id]
  if not rt then return "", nil end
  if rt.status == "running" and rt.activity == "working" then
    local frames = cfg.options.icons.spinner
    return frames[(M.frame % #frames) + 1], "AgentPanelSpinner"
  end
  if rt.unread then return cfg.options.icons.bell, "AgentPanelBell" end
  return "", nil
end

return M
