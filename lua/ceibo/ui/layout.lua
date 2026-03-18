-- Opens and manages the ceibo tab layout:
-- [ file list | diff view ]

local M = {}

-- Helper: write lines into a scratch buffer.
local function set_buf_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Apply simple line highlights to a split buffer (old or new side).
-- `side` is "old" (del lines) or "new" (add lines).
local function apply_split_hl(bufnr, lines, side)
  local ns = vim.api.nvim_create_namespace("ceibo_split_hl_" .. side)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for i, line in ipairs(lines) do
    local ch = line:sub(6, 6) -- after the 4-digit line number + space
    if ch == "-" then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "CeiboDel", i - 1, 0, -1)
    elseif ch == "+" then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "CeiboAdd", i - 1, 0, -1)
    elseif line:match("^  ") and line:match("%[") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "CeiboFileHeader", i - 1, 0, -1)
    elseif line:match("^%s*@@") or line:match("^    @@") then
      vim.api.nvim_buf_add_highlight(bufnr, ns, "CeiboHdr", i - 1, 0, -1)
    end
  end
end

function M.open(opts)
  local cfg = require("ceibo.config").options
  local session = require("ceibo.session")
  local diff_view = require("ceibo.ui.diff_view")
  local file_list = require("ceibo.ui.file_list")
  local keymaps = require("ceibo.keymaps")
  local statusbar = require("ceibo.ui.statusbar")

  -- Close any previously open ceibo tab so stale buffers/keymaps don't linger
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "ceibo://review" then
      vim.api.nvim_buf_delete(buf, { force = true })
      break
    end
  end

  -- open a new tab
  vim.cmd("tabnew")
  local tabnr = vim.api.nvim_get_current_tabpage()

  -- create diff buffer in current window
  local diff_bufnr = diff_view.create_buf()
  session.bufnr = diff_bufnr
  vim.api.nvim_win_set_buf(0, diff_bufnr)
  local diff_win = vim.api.nvim_get_current_win()

  -- create file list buffer in a left split
  local fw = cfg.layout.file_list_width
  vim.cmd("topleft " .. fw .. "vsplit")
  local fl_bufnr = file_list.create_buf()
  session.file_list_bufnr = fl_bufnr
  vim.api.nvim_win_set_buf(0, fl_bufnr)
  local fl_win = vim.api.nvim_get_current_win()

  -- render diff
  diff_view.render(diff_bufnr, session.lines, session.line_map)

  -- render file list; result is stored in session.file_lines for live access by keymaps
  file_list.render(fl_bufnr)

  -- set window options
  for _, win in ipairs({ diff_win, fl_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
  end
  vim.wo[diff_win].number = true
  vim.wo[diff_win].winbar = "%!v:lua.require('ceibo.session').winbar_text(line('.'))"
  vim.wo[diff_win].statusline = " ceibo  %=%{&modified?'[+]':''} "

  -- name the diff buffer (used by other code to find it); must be done BEFORE
  -- attaching keymaps so that autocommands triggered by :file don't overwrite
  -- buffer-local bindings like gf.
  vim.api.nvim_buf_set_name(diff_bufnr, "ceibo://review")

  -- keymaps for diff buffer
  keymaps.attach_diff(diff_bufnr, diff_win, fl_bufnr, fl_win)

  -- keymaps for file list buffer (reads session.file_lines at call time)
  keymaps.attach_file_list(fl_bufnr, fl_win)

  -- focus diff window
  vim.api.nvim_set_current_win(diff_win)

  -- open persistent statusbar
  statusbar.open()

  -- close statusbar when the ceibo tab is closed
  vim.api.nvim_create_autocmd("TabClosed", {
    once = true,
    pattern = tostring(tabnr),
    callback = function()
      statusbar.close()
    end,
  })

  vim.notify("ceibo: " .. #session.files .. " files changed. Press ? for help.", vim.log.levels.INFO)

  -- return to beginning
  vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })

  -- if configured to start in split mode, open it now
  if session.view_mode == "split" then
    M.open_split(diff_win)
  end

  return { tabnr = tabnr, diff_win = diff_win, fl_win = fl_win }
end

-- Open the two-buffer side-by-side split.
-- Hides the unified diff window and replaces it with two scrollbound windows.
function M.open_split(diff_win)
  local session = require("ceibo.session")
  local diff = require("ceibo.diff")
  diff_win = diff_win or M._diff_win()
  if not diff_win then
    return
  end

  -- Already open?
  if session.split_old_win and vim.api.nvim_win_is_valid(session.split_old_win) then
    return
  end

  local old_lines = diff.build_old_lines(session.files, { collapsed = session.collapsed })
  local new_lines = diff.build_new_lines(session.files, { collapsed = session.collapsed })

  -- Create scratch buffers
  local old_buf = vim.api.nvim_create_buf(false, true)
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[old_buf].bufhidden = "wipe"
  vim.bo[new_buf].bufhidden = "wipe"
  set_buf_lines(old_buf, old_lines)
  set_buf_lines(new_buf, new_lines)
  apply_split_hl(old_buf, old_lines, "old")
  apply_split_hl(new_buf, new_lines, "new")

  session.split_old_bufnr = old_buf
  session.split_new_bufnr = new_buf

  require("ceibo.keymaps").attach_split(old_buf, new_buf)

  -- Replace the unified diff window content with the old buffer, then vsplit for new
  vim.api.nvim_set_current_win(diff_win)
  vim.api.nvim_win_set_buf(diff_win, old_buf)
  session.split_old_win = diff_win

  vim.cmd("vsplit")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, new_buf)
  session.split_new_win = new_win

  -- Window options for both split windows
  for _, win in ipairs({ diff_win, new_win }) do
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.wo[win].diff = false
  end
  vim.wo[diff_win].statusline = " ceibo  OLD "
  vim.wo[new_win].statusline = " ceibo  NEW "

  -- Synchronise scroll
  vim.api.nvim_set_current_win(diff_win)
  vim.cmd("syncbind")
end

-- Close the split view and restore the unified diff buffer.
function M.close_split()
  local session = require("ceibo.session")

  local old_win = session.split_old_win
  local new_win = session.split_new_win
  if not old_win or not vim.api.nvim_win_is_valid(old_win) then
    return
  end

  -- Close the new-side window
  if new_win and vim.api.nvim_win_is_valid(new_win) then
    vim.api.nvim_win_close(new_win, true)
  end

  -- Restore unified buffer in the old-side window
  if vim.api.nvim_win_is_valid(old_win) then
    vim.api.nvim_win_set_buf(old_win, session.bufnr)
    vim.wo[old_win].scrollbind = false
    vim.wo[old_win].cursorbind = false
    vim.wo[old_win].number = true
    vim.wo[old_win].statusline = " ceibo  %=%{&modified?'[+]':''} "
    vim.wo[old_win].winbar = "%!v:lua.require('ceibo.session').winbar_text(line('.'))"
  end

  session.split_old_win = nil
  session.split_new_win = nil
  session.split_old_bufnr = nil
  session.split_new_bufnr = nil
end

-- Close all ceibo buffers and the review tab.
function M.close()
  local session = require("ceibo.session")
  local statusbar = require("ceibo.ui.statusbar")

  local bufs = {
    session.bufnr,
    session.file_list_bufnr,
    session.split_old_bufnr,
    session.split_new_bufnr,
  }

  statusbar.close()

  -- tabclose first so windows are gone before we wipe buffers
  vim.cmd("tabclose")

  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

-- Find the current diff_win by looking for the buffer named "ceibo://review".
function M._diff_win()
  local session = require("ceibo.session")
  if not session.bufnr then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == session.bufnr then
      return win
    end
  end
  -- In split mode the unified buf is hidden — fall back to split_old_win
  if session.split_old_win and vim.api.nvim_win_is_valid(session.split_old_win) then
    return session.split_old_win
  end
  return nil
end

-- Reload the diff from git (re-fetch + re-parse), then refresh both panels.
-- Used when context_lines changes.
function M.reload()
  local session = require("ceibo.session")
  local diff = require("ceibo.diff")

  local raw, err = diff.get_raw_diff(session.ref, session.staged)
  if not raw then
    vim.notify("ceibo: " .. (err or "git diff failed"), vim.log.levels.ERROR)
    return
  end
  session.files = diff.parse(raw)
  M.refresh()
end

-- Refresh both panels (e.g. after adding a comment or marking reviewed)
function M.refresh()
  local session = require("ceibo.session")
  local diff = require("ceibo.diff")
  local diff_view = require("ceibo.ui.diff_view")
  local file_list = require("ceibo.ui.file_list")

  -- Always rebuild the unified display (used for comments + file list)
  session.lines, session.line_map = diff.build_display(session.files, { collapsed = session.collapsed })

  if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
    diff_view.render(session.bufnr, session.lines, session.line_map)
  end

  if session.file_list_bufnr and vim.api.nvim_buf_is_valid(session.file_list_bufnr) then
    file_list.render(session.file_list_bufnr)
  end

  -- If split view is open, refresh those buffers too
  if session.split_old_bufnr and vim.api.nvim_buf_is_valid(session.split_old_bufnr) then
    local old_lines = diff.build_old_lines(session.files, { collapsed = session.collapsed })
    set_buf_lines(session.split_old_bufnr, old_lines)
    apply_split_hl(session.split_old_bufnr, old_lines, "old")
  end
  if session.split_new_bufnr and vim.api.nvim_buf_is_valid(session.split_new_bufnr) then
    local new_lines = diff.build_new_lines(session.files, { collapsed = session.collapsed })
    set_buf_lines(session.split_new_bufnr, new_lines)
    apply_split_hl(session.split_new_bufnr, new_lines, "new")
  end

  -- force winbar redraw
  vim.cmd("redrawstatus!")
end

return M
