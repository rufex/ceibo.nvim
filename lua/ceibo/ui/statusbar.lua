-- Persistent single-line status bar anchored to the bottom of the editor.
-- Shows global ceibo keys by default; swaps to prompt-specific keys while the
-- comment prompt is open.

local M = {}

local ns = vim.api.nvim_create_namespace("ceibo_statusbar")
local _bufnr = nil
local _win = nil

-- ── internal helpers ────────────────────────────────────────────────────────

local function render(left_chunks, right_chunks)
  if not (_bufnr and vim.api.nvim_buf_is_valid(_bufnr)) then
    return
  end
  vim.bo[_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, { "" })
  vim.bo[_bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(_bufnr, ns, 0, -1)
  if #left_chunks > 0 then
    vim.api.nvim_buf_set_extmark(_bufnr, ns, 0, 0, {
      virt_text = left_chunks,
      virt_text_pos = "eol",
    })
  end
  if right_chunks and #right_chunks > 0 then
    vim.api.nvim_buf_set_extmark(_bufnr, ns, 0, 0, {
      virt_text = right_chunks,
      virt_text_pos = "right_align",
    })
  end
end

-- ── public API ──────────────────────────────────────────────────────────────

-- Create (or re-use) the statusbar window.  Called once from layout.open().
function M.open()
  if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then
    M.set_normal_mode()
    return
  end

  _bufnr = vim.api.nvim_create_buf(false, true)
  _win = vim.api.nvim_open_win(_bufnr, false, {
    relative = "editor",
    row = vim.o.lines - 2, -- one row above the cmdline
    col = 0,
    width = vim.o.columns,
    height = 1,
    style = "minimal",
    zindex = 49,
  })
  vim.wo[_win].winhl = "Normal:Normal"

  M.set_normal_mode()
end

-- Close and forget the statusbar (called when the ceibo tab is closed).
function M.close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  _bufnr = nil
end

-- Normal mode: global ceibo keys.
function M.set_normal_mode()
  local cfg = require("ceibo.config").options
  local km = cfg.keymaps
  local function k(v)
    return v or "–"
  end
  render({
    { "  ", "StatusLine" },
    { k(km.add_comment), "CeiboFileHeader" },
    { " comment  ", "Comment" },
    { k(km.mark_reviewed), "CeiboFileHeader" },
    { " review  ", "Comment" },
    { k(km.yank), "CeiboFileHeader" },
    { " yank  ", "Comment" },
    { k(km.submit), "CeiboFileHeader" },
    { " submit  ", "Comment" },
  }, {
    { "?", "CeiboFileHeader" },
    { " help  ", "Comment" },
  })
end

-- Prompt mode: show current scope/type on the left, prompt keys on the right.
-- scope_idx / type_idx are 1-based indices into scopes / COMMENT_TYPES arrays.
function M.set_prompt_mode(scopes, scope_idx, types, type_idx, hint)
  local sc = scopes[scope_idx]
  local tp = types[type_idx] -- { name, hl, emoji }
  render({
    { "  Scope: ", "Comment" },
    { sc:upper(), "CeiboFileHeader" },
    { "  Type: ", "Comment" },
    { tp.name, tp.hl },
    { "  " .. hint, "CeiboCommentText" },
  }, {
    { "<C-s> save  <Tab> type  <S-Tab> scope  <Esc> cancel  ", "Comment" },
  })
end

return M
