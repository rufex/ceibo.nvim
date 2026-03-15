-- Renders the diff buffer and applies syntax highlights.

local M = {}

local function apply_highlights(bufnr, line_map)
  local ns = vim.api.nvim_create_namespace("ceibo_diff_hl")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for i, meta in ipairs(line_map) do
    local lnum = i - 1 -- 0-based
    local t = meta.line_type
    local hl
    if meta.is_file_header then
      hl = "CeiboFileHeader"
    elseif meta.is_collapsed_placeholder then
      hl = "CeiboCollapsed"
    elseif t == "add" then
      hl = "CeiboAdd"
    elseif t == "del" then
      hl = "CeiboDel"
    elseif t == "hdr" then
      hl = "CeiboHdr"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(bufnr, ns, hl, lnum, 0, -1)
    end
  end
end

function M.create_buf()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "ceibo"
  return bufnr
end

function M.render(bufnr, lines, line_map)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  apply_highlights(bufnr, line_map)
  require("ceibo.comments").render_all(bufnr, line_map)
end

-- Move cursor to the next/prev hunk header or file header
function M.jump(direction, target)
  -- target: "hunk" | "file"
  local session = require("ceibo.session")
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = #session.line_map

  local function matches(i)
    local m = session.line_map[i]
    if not m then
      return false
    end
    if target == "file" then
      return m.is_file_header
    end
    if target == "hunk" then
      return m.line_type == "hdr"
    end
    return false
  end

  if direction == "next" then
    for i = cur + 1, total do
      if matches(i) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  else
    for i = cur - 1, 1, -1 do
      if matches(i) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end
end

return M
