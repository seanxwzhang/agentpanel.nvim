# agentpanel.nvim

A Codex-like **agent panel** for Neovim. A single modal gives you a left rail of
conversations (grouped by project, annotated with the agent and the git
worktree) and a right pane embedding the **live `codex` / `claude` terminal**.
Sessions can run locally or in a fresh git worktree, you can drop back into the
editor at any session's worktree root, and a background activity monitor turns
the rail badge from a spinner into a bell — with an optional sound — the moment
an agent finishes and is waiting on you.

> Extracted from my personal [AstroNvim](https://astronvim.com) config into a
> standalone, framework-agnostic plugin. It depends only on Neovim core and
> `git` — no AstroNvim, heirline, or snacks required.

## Features

- **One modal, many conversations.** `<Leader>m` (or `:AgentPanel`) toggles a
  floating panel. The left rail lists every session grouped by project; the
  right pane is the agent's actual terminal.
- **Codex and Claude.** Start a fresh `codex` or `claude` session, or resume a
  *specific* prior conversation by its captured session id (not just the most
  recent one).
- **Fork a conversation.** `F` on a session branches a new conversation off its
  history — the two diverge independently — running in the **same worktree**.
  Uses each CLI's native fork (`codex fork <id>` / `claude --fork-session
  --resume <id>`).
- **Git worktrees, first-class.** Launch a session in a brand-new
  `git worktree add`'d branch so parallel agents never step on each other. Press
  `e` to drop into the editor with the cwd set to that worktree's root.
- **Live activity monitor.** Each running session is polled; while the agent is
  working the rail shows an animated spinner, and when it goes quiet awaiting
  input it flips to a bell badge, fires a `vim.notify`, and (optionally) plays a
  sound.
- **Persisted sessions.** Conversations survive restarts — metadata is stored as
  JSON under `stdpath("data")/agentpanel`. Archive, rename, and delete from the
  rail.

## Requirements

- **Neovim ≥ 0.10** (uses `vim.system` and `vim.uv`).
- **git** on `PATH`.
- The agent CLIs you want to drive on `PATH`: [`codex`](https://github.com/openai/codex)
  and/or [`claude`](https://www.anthropic.com/claude-code). At least one.
- A **Nerd Font** for the rail/badge icons (configurable — see below).
- *Optional:* [`blink.cmp`](https://github.com/saghen/blink.cmp) — enables
  branch-name completion in the new-session form. Soft dependency; degrades
  gracefully if absent.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "seanxwzhang/agentpanel.nvim",
  dependencies = { "saghen/blink.cmp" }, -- optional
  cmd = { "AgentPanel", "AgentPanelNew" },
  keys = {
    { "<Leader>m", "<cmd>AgentPanel<cr>", desc = "Agent panel" },
  },
  opts = {}, -- passed straight to require("agentpanel").setup()
}
```

`opts` is optional — omit it for the defaults. If you set `opts`, lazy.nvim calls
`require("agentpanel").setup(opts)` for you. With another plugin manager, call
`require("agentpanel").setup({ ... })` yourself once at startup.

## Usage

| Command / key            | Action                                             |
| ------------------------ | -------------------------------------------------- |
| `:AgentPanel` / `<Leader>m` | Toggle the panel                                |
| `:AgentPanelNew [codex\|claude]` | Open the panel at the new-session form     |

### Inside the panel (left rail)

| Key        | Action                                  |
| ---------- | --------------------------------------- |
| `j` / `k`  | Next / previous conversation            |
| `↵` / `l` / `<Tab>` | Open the selected conversation |
| `<C-l>` / `<C-h>` | Switch between rail and session pane |
| `cx` / `cc`| New **c**ode**x** / **c**laude session  |
| `F`        | **F**ork the conversation (same worktree) |
| `e`        | Drop into the editor at the worktree    |
| `c`        | Drop the session into a copilot sidecar |
| `r`        | Rename conversation                     |
| `a`        | Archive / unarchive                     |
| `A`        | Show / hide the archived section        |
| `dd` / `x` | Delete conversation                     |
| `q` / `<Esc>` | Close the panel                      |

## Configuration

All defaults, override any subset via `setup`:

```lua
require("agentpanel").setup {
  -- Where `git worktree add` puts new worktrees: <root>/<project>/<branch>.
  worktree_root = vim.fn.expand "~/worktrees",
  -- Where session metadata is persisted (JSON).
  data_dir = vim.fn.stdpath "data" .. "/agentpanel",
  -- Fallback base branch when a repo's current branch can't be determined.
  default_base_branch = "main",

  -- Per-agent launch configuration. `cmd` starts a fresh session; `resume_id`
  -- continues a SPECIFIC prior conversation (the captured session id is
  -- appended); `resume` is the fallback that continues the most-recent one.
  agents = {
    codex = {
      label = "codex",
      icon = "◆",
      cmd = { "codex" },
      resume_id = { "codex", "resume" }, -- + <session id>
      resume = { "codex", "resume", "--last" },
    },
    claude = {
      label = "claude",
      icon = "✦",
      cmd = { "claude" },
      resume_id = { "claude", "--resume" }, -- + <session id>
      resume = { "claude", "--continue" },
    },
  },

  icons = {
    worktree = "",          -- nf git-branch, shown before the branch
    local_dir = "",         -- nf folder, shown for non-worktree sessions
    tab = "⇥",
    new = "",
    bell = "\239\131\179",   -- nf-fa-bell (U+F0F3), the "awaiting input" badge
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Live session activity → drives the spinner ↔ bell badge and the
  -- "finished, awaiting input" notification.
  activity = {
    enabled = true,
    poll_ms = 120,
    idle_ms = 1200,
    notify = true,
    sound = true,
    sound_name = "Glass",   -- macOS system sound, or an absolute path to audio
    snapshot_lines = 60,
  },

  ui = {
    width = 0.9,
    height = 0.85,
    rail_width = 38,
    border = "rounded",
    sidecar_width = 0.4,
  },
}
```

> **Note on the statusline.** The repo ships an internal
> `agentpanel.statusline` module (a [heirline](https://github.com/rebelot/heirline.nvim)-shaped
> component that shows the active worktree). It is intentionally **not** wired up
> by the plugin — it's left to your own statusline config to consume if you want
> it. The panel works fully without it.

## Development

Hot-reload the panel without restarting Neovim while hacking on it:

```vim
:lua require("agentpanel.reload").run()
```

This drops the cached `agentpanel.*` modules (picking up your edits) while
preserving running agent terminals.

## License

[MIT](./LICENSE)
