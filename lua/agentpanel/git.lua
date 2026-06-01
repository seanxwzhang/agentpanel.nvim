-- agentpanel.git — thin synchronous wrappers around the git CLI.
local M = {}

local function lines(args)
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then return {} end
  return out
end

--- Absolute repo top-level for `dir`, or nil if not a git repo.
function M.toplevel(dir)
  if not dir or dir == "" then return nil end
  local out = lines { "git", "-C", dir, "rev-parse", "--show-toplevel" }
  return out[1]
end

--- True when `dir` lives inside a *linked* worktree (git-dir != common-dir).
--- Both paths are requested in absolute/canonical form so the comparison is
--- not fooled by relative output (`.git`) or symlinked paths.
function M.is_worktree(dir)
  if not dir or dir == "" then return false end
  local gd = lines { "git", "-C", dir, "rev-parse", "--path-format=absolute", "--absolute-git-dir" }
  local cd = lines { "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" }
  if not gd[1] or not cd[1] then return false end
  local a = gd[1]:gsub("/$", "")
  local b = cd[1]:gsub("/$", "")
  return a ~= b
end

--- Basename of the worktree root if `dir` is a linked worktree, else nil.
function M.worktree_label(dir)
  if not M.is_worktree(dir) then return nil end
  local top = M.toplevel(dir)
  return top and vim.fn.fnamemodify(top, ":t") or nil
end

function M.current_branch(dir)
  local out = lines { "git", "-C", dir, "branch", "--show-current" }
  return out[1]
end

--- Local branch names for the repo containing `dir`.
function M.branches(dir)
  return lines { "git", "-C", dir, "branch", "--format=%(refname:short)" }
end

-- NOTE: worktree creation is intentionally not done here. It runs inside the
-- session terminal (see agentpanel.terminal.creation_script) so the checkout
-- streams as visible logs and never blocks the editor.

return M
