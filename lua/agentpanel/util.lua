-- agentpanel.util — tiny shared helpers (no state).
local M = {}

--- Monotonic-ish unique id from wall clock + high-res timer.
function M.uid()
  local hr = (vim.uv or vim.loop).hrtime()
  return string.format("%x-%x", os.time(), hr % 0xffffffff)
end

--- Human relative time, e.g. "12s" / "4m" / "3h" / "6d".
function M.rel_time(ts)
  if not ts then return "" end
  local d = os.time() - ts
  if d < 0 then d = 0 end
  if d < 60 then return d .. "s" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

--- Branch/path-safe slug. Keeps slashes optionally.
---@param s string
---@param keep_slash? boolean
function M.slug(s, keep_slash)
  s = (s or ""):lower()
  local pat = keep_slash and "[^%w%-%./]" or "[^%w%-%.]"
  s = s:gsub("%s+", "-"):gsub(pat, "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if s == "" then s = "session" end
  return s
end

--- Truncate to a display width, appending an ellipsis when cut.
function M.truncate(s, width)
  s = s or ""
  if vim.fn.strdisplaywidth(s) <= width then return s end
  if width <= 1 then return "…" end
  -- strcharpart works on character indices; good enough for our labels.
  local out = s
  while vim.fn.strdisplaywidth(out) > width - 1 and #out > 0 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

--- Pad/space a string to an exact display width (left aligned).
function M.pad(s, width)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w >= width then return s end
  return s .. string.rep(" ", width - w)
end

return M
