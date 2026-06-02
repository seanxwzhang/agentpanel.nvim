-- agentpanel.config — central defaults for the agent panel.
-- Override any of these via require("agentpanel").setup { ... } (wired from
-- lua/plugins/agentpanel.lua).
local M = {}

M.defaults = {
  -- Where `git worktree add` puts new worktrees: <root>/<project>/<branch>.
  worktree_root = vim.fn.expand "~/worktrees",
  -- Where session metadata is persisted (JSON).
  data_dir = vim.fn.stdpath "data" .. "/agentpanel",
  -- Fallback base branch when a repo's current branch can't be determined.
  default_base_branch = "main",

  -- Per-agent launch configuration:
  --   cmd        start a fresh interactive session (a prompt may be appended)
  --   resume_id  continue a SPECIFIC prior conversation — the captured agent
  --              session id is appended (this is what keeps the rail entry and
  --              the live conversation in sync)
  --   resume     fallback when no session id was captured (e.g. legacy sessions
  --              created before id-capture, or capture failed). These resume the
  --              most-recent conversation, so they are NOT session-specific.
  --   fork_id    branch a NEW conversation off a SPECIFIC prior session — the
  --              source's captured agent session id is appended. The fork shares
  --              the source's history but then diverges independently. Used by
  --              the rail's `F` action (forks in the source's same worktree/cwd).
  agents = {
    codex = {
      label = "codex",
      icon = "◆",
      cmd = { "codex" },
      resume_id = { "codex", "resume" }, -- + <session id>
      resume = { "codex", "resume", "--last" },
      fork_id = { "codex", "fork" }, -- + <source session id>
    },
    claude = {
      label = "claude",
      icon = "✦",
      cmd = { "claude" },
      resume_id = { "claude", "--resume" }, -- + <session id>
      resume = { "claude", "--continue" },
      fork_id = { "claude", "--fork-session", "--resume" }, -- + <source session id>
    },
  },

  icons = {
    worktree = "", -- nf git-branch; shown before the branch in the statusline + rail
    local_dir = "", -- nf folder; shown for non-worktree (local) sessions
    tab = "⇥", -- shown before the nvim tab number in the rail when a session has an open tab
    new = "",
    bell = "\239\131\179", -- nf-fa-bell (U+F0F3); rail badge for unread output / awaiting input
    -- Spinner frames animated in the rail while a session's agent is working.
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Live session activity: detects whether each session's agent is still
  -- working (its terminal keeps redrawing) or has gone quiet awaiting input,
  -- which drives the rail status badge (spinner ↔ bell) and the "finished"
  -- notification. See agentpanel.activity.
  activity = {
    enabled = true,
    poll_ms = 120, -- spinner frame + activity poll cadence (ms)
    idle_ms = 1200, -- quiet time after working before a session counts as "waiting"
    notify = true, -- vim.notify when an agent finishes and is waiting for input
    sound = true, -- play an audible sound on that same "finished, awaiting input" alert
    -- macOS system sound name (played from /System/Library/Sounds/<name>.aiff) or
    -- an absolute path to any audio file. Other names: Ping, Hero, Submarine, Funk…
    sound_name = "Glass",
    snapshot_lines = 60, -- terminal tail lines compared to detect ongoing output
  },

  ui = {
    width = 0.9, -- fraction of columns for the whole modal
    height = 0.85, -- fraction of lines
    rail_width = 38, -- left rail text width (columns)
    border = "rounded",
    sidecar_width = 0.4, -- fraction of columns for the `c` copilot sidecar split
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts) M.options = vim.tbl_deep_extend("force", M.options, opts or {}) end

return M
