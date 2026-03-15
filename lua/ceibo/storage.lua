-- Resolves and creates the per-repo data directory under stdpath("data").
--
-- Path: $XDG_DATA_HOME/nvim/ceibo/<repo-key>/
-- where <repo-key> is the sanitised basename of the repo root, suffixed with
-- a short hash of the absolute path to avoid collisions between same-named repos.

local M = {}

local _cached_dir = nil

-- Return a short, stable key for the current repo.
local function repo_key()
  local root = vim.fn.getcwd()
  -- try to find the actual repo root
  local out = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null")
  if vim.v.shell_error == 0 then
    root = vim.trim(out)
  end

  -- basename of root
  local name = root:match("[^/]+$") or "unknown"
  -- cheap djb2-style hash of the full path → 6 hex chars
  local h = 5381
  for i = 1, #root do
    h = ((h * 33) + root:byte(i)) % 0xFFFFFF
  end
  return name .. "-" .. string.format("%06x", h)
end

-- Return (and create if needed) the data directory for this repo.
function M.data_dir()
  if _cached_dir then
    return _cached_dir
  end

  local base = vim.fn.stdpath("data") .. "/ceibo/" .. repo_key()
  vim.fn.mkdir(base, "p")
  _cached_dir = base
  return base
end

-- Clear the cache (used when switching repos within a session).
function M.reset()
  _cached_dir = nil
end

return M
