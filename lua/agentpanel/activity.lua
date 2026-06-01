-- agentpanel.activity — per-session liveness for the rail's status badge.
--
-- A session's agent runs in a pty terminal (see agentpanel.terminal). While it
-- is working — codex/claude continuously redraw an animated spinner, a token
-- counter, an elapsed timer — the terminal buffer's tail keeps changing. When
-- it finishes a turn and returns to its input prompt, the tail goes quiet.
--
-- We poll that tail on a single shared timer and classify each live session as:
--   * "working"  — output changed recently      → animated spinner badge
--   * "waiting"  — quiet for `idle_ms` after work → done; awaiting the human
-- On the working→waiting edge we mark the session unread (a bell badge) and,
-- unless the user is already looking at it, fire a notification. Unread clears
-- the moment the session is read (its terminal becomes visible/focused).
--
-- Runtime activity is stored on terminal.runtime[id] (transient, never
-- persisted): { activity, unread, _snap, _last_change }.
local cfg = require "agentpanel.config"

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}
M.frame = 0 -- spinner animation frame, advanced once per tick
local timer = nil -- active vim.fn.timer id while monitoring, else nil
local did_autocmd = false

local function opts() return cfg.options.activity end

-- Snapshot the tail of a terminal buffer — what the agent has most recently
-- drawn. A change between snapshots means it is still producing output.
local function snapshot(buf)
  if not (buf and api.nvim_buf_is_valid(buf)) then return nil end
  local n = api.nvim_buf_line_count(buf)
  local from = math.max(0, n - (opts().snapshot_lines or 60))
  return table.concat(api.nvim_buf_get_lines(buf, from, n, false), "\n")
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
      local snap = snapshot(rt.buf)
      if snap ~= rt._snap then
        rt._snap = snap
        rt._last_change = now
        if rt.activity ~= "working" then
          rt.activity = "working"
          changed = true
        end
      elseif rt.activity == "working" and now - (rt._last_change or now) >= (opts().idle_ms or 1200) then
        -- Quiet long enough after working: the turn is done, awaiting input.
        rt.activity = "waiting"
        changed = true
        local s = store.get(id)
        if s and not is_visible(rt.buf) then
          rt.unread = true
          notify_waiting(s)
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
