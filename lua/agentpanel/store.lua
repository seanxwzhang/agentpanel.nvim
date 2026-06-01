-- agentpanel.store — in-memory list of sessions + JSON persistence.
--
-- A session is a plain table of metadata (persisted). Live runtime state
-- (terminal buffer/job) lives in agentpanel.terminal, keyed by session id, so
-- this module stays pure data and is safe to serialize.
--
-- Session shape:
--   { id, title, agent = "codex"|"claude",
--     project_name, project_root,
--     cwd,                      -- where the agent process runs
--     mode = "local"|"worktree",
--     worktree = nil | { path, branch, base },
--     branch,                   -- display branch
--     created_at, last_active,
--     initial_prompt? }
local cfg = require "agentpanel.config"

local M = {}
M.sessions = {} ---@type table[] ordered list
M.index = {} ---@type table<string, table> id -> session

local function path() return cfg.options.data_dir .. "/sessions.json" end

-- Strip transient keys (anything starting with "_") before writing.
local function persistable(s)
  local out = {}
  for k, v in pairs(s) do
    if type(k) ~= "string" or k:sub(1, 1) ~= "_" then out[k] = v end
  end
  return out
end

function M.load()
  M.sessions, M.index = {}, {}
  local p = path()
  if vim.fn.filereadable(p) == 0 then return end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
  if not ok or type(data) ~= "table" then return end
  for _, s in ipairs(data) do
    if type(s) == "table" and s.id then
      M.sessions[#M.sessions + 1] = s
      M.index[s.id] = s
    end
  end
end

function M.save()
  vim.fn.mkdir(cfg.options.data_dir, "p")
  local data = {}
  for _, s in ipairs(M.sessions) do
    data[#data + 1] = persistable(s)
  end
  local ok, json = pcall(vim.json.encode, data)
  if ok then pcall(vim.fn.writefile, { json }, path()) end
end

function M.all() return M.sessions end
function M.get(id) return M.index[id] end

function M.add(session)
  M.sessions[#M.sessions + 1] = session
  M.index[session.id] = session
  M.save()
  return session
end

function M.remove(id)
  M.index[id] = nil
  for i, s in ipairs(M.sessions) do
    if s.id == id then
      table.remove(M.sessions, i)
      break
    end
  end
  M.save()
end

function M.touch(id)
  local s = M.index[id]
  if s then
    s.last_active = os.time()
    M.save()
  end
end

--- Distinct projects seen across sessions, most-recent first. Used to offer
--- recents in the new-session form. Projects accumulate purely from use.
function M.projects()
  local seen, list = {}, {}
  -- newest sessions first
  local ordered = vim.deepcopy(M.sessions)
  table.sort(ordered, function(a, b) return (a.last_active or 0) > (b.last_active or 0) end)
  for _, s in ipairs(ordered) do
    local root = s.project_root
    if root and not seen[root] then
      seen[root] = true
      list[#list + 1] = { name = s.project_name or vim.fn.fnamemodify(root, ":t"), root = root }
    end
  end
  return list
end

return M
