-- Holds runtime state for the current review session.
-- Single source of truth shared across all modules.

local M = {}

M.files = {} -- parsed file list from diff.lua
M.lines = {} -- display lines (strings)
M.line_map = {} -- per-display-line metadata
M.reviewed = {} -- { [file_path] = true }
M.collapsed = {} -- { [file_path] = true }
M.bufnr = nil -- diff buffer
M.file_list_bufnr = nil
M.ref = nil -- git ref being diffed
M.staged = false
M.git_dir = nil -- absolute path to .git dir (handles worktrees)
M.file_lines = {} -- file panel: display line → file_idx (kept in sync with renders)
M.context_lines = 3 -- lines of context shown around each hunk (-U flag)
M.view_mode = "unified" -- "unified" | "split"
-- split-view state (nil when not open)
M.split_old_bufnr = nil
M.split_new_bufnr = nil
M.split_old_win = nil
M.split_new_win = nil

function M.reset()
  M.files = {}
  M.lines = {}
  M.line_map = {}
  M.reviewed = {}
  M.collapsed = {}
  M.bufnr = nil
  M.file_list_bufnr = nil
  M.ref = nil
  M.staged = false
  M.git_dir = nil
  M.file_lines = {}
  M.context_lines = 3
  M.view_mode = require("ceibo.config").options.view_mode or "unified"
  M.split_old_bufnr = nil
  M.split_new_bufnr = nil
  M.split_old_win = nil
  M.split_new_win = nil
  require("ceibo.storage").reset()
  require("ceibo.comments").reset()
end

function M.is_reviewed(file_path)
  return M.reviewed[file_path] == true
end

function M.toggle_reviewed(file_path)
  -- Store nil (not false) when un-toggling so pairs() counts only truly reviewed files
  M.reviewed[file_path] = not M.reviewed[file_path] or nil
end

function M.is_collapsed(file_path)
  return M.collapsed[file_path] == true
end

function M.toggle_collapsed(file_path)
  M.collapsed[file_path] = not M.collapsed[file_path] or nil
end

-- Given a display line number, return the file_path and new_ln (if applicable)
function M.line_info(display_ln)
  local meta = M.line_map[display_ln]
  if not meta or not meta.file_idx then
    return nil, nil
  end
  local file = M.files[meta.file_idx]
  if not file then
    return nil, nil
  end
  local path = file.new_path ~= "" and file.new_path or file.old_path
  return path, meta.new_ln, meta
end

-- Return a string for the winbar of the diff window
function M.winbar_text(display_ln)
  local meta = M.line_map[display_ln]
  local comments = require("ceibo.comments")

  -- current file
  local file_part = ""
  if meta and meta.file_idx and M.files[meta.file_idx] then
    local f = M.files[meta.file_idx]
    local path = f.new_path ~= "" and f.new_path or f.old_path
    local reviewed = M.is_reviewed(path) and " ✓" or ""
    local status_map = { A = "+new", D = "-del", M = "~mod", R = "~ren" }
    local status = status_map[f.status] or ""
    file_part = "%#CeiboFileHeader# " .. path .. " %#CeiboHdr#" .. status .. reviewed .. " "
  end

  -- global stats
  local n_files = #M.files
  local n_reviewed = 0
  for _ in pairs(M.reviewed) do
    n_reviewed = n_reviewed + 1
  end
  local n_comments = comments.count()

  local stats = "%#Comment# files:"
    .. n_reviewed
    .. "/"
    .. n_files
    .. "  comments:"
    .. n_comments
    .. (M.staged and "  [staged]" or "")
    .. " "

  -- line number hint
  local ln_part = ""
  if meta and meta.new_ln then
    ln_part = "%#Normal# :" .. meta.new_ln .. " "
  end

  return file_part .. "%=" .. ln_part .. stats
end

return M
