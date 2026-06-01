-- agentpanel.reload — hot-reload the panel without restarting nvim.
--
-- Run:  :lua require("agentpanel.reload").run()
--
-- Drops the cached agentpanel.* modules so edited code is picked up, while
-- preserving the live terminal runtime (running agent buffers/jobs) and the
-- statusline component (heirline holds a live reference to it). Re-seeds and
-- restarts the activity monitor for any session still running.
local M = {}

function M.run()
  local L = package.loaded

  -- Close the panel first: its windows/keymaps/autocmds close over old modules.
  local ui = L["agentpanel.ui"]
  if ui and ui.state and ui.state.open then pcall(ui.close) end

  -- Hold onto the live runtime so running sessions survive the reload.
  local term = L["agentpanel.terminal"]
  local rt = term and term.runtime

  -- Drop cached modules. Keep `statusline` (heirline references its component)
  -- and `reload` (this module) so their identities stay stable.
  for name in pairs(L) do
    if (name == "agentpanel" or name:match "^agentpanel%.")
      and name ~= "agentpanel.statusline"
      and name ~= "agentpanel.reload"
    then
      L[name] = nil
    end
  end

  -- Re-initialise config / store / highlights against the fresh modules.
  require("agentpanel").setup()

  -- Restore live sessions and resume monitoring them.
  if rt then
    local T = require "agentpanel.terminal"
    T.runtime = rt
    local now = (vim.uv or vim.loop).now()
    local seed = false
    for _, r in pairs(rt) do
      if r.status == "running" then
        r.activity = r.activity or "working"
        r._last_change = r._last_change or now
        seed = true
      end
    end
    if seed then require("agentpanel.activity").start() end
  end

  vim.notify("agentpanel reloaded", vim.log.levels.INFO)
end

return M
