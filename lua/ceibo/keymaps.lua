-- All buffer-local keymaps for ceibo windows.

local M = {}

local function map(mode, bufnr, lhs, rhs, desc)
  if not lhs then
    return
  end -- keymap = false in config disables the binding
  vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, noremap = true, silent = true, desc = desc })
end

local function nmap(bufnr, lhs, rhs, desc)
  map("n", bufnr, lhs, rhs, desc)
end
local function vmap(bufnr, lhs, rhs, desc)
  map("v", bufnr, lhs, rhs, desc)
end

-- Resolve the visual selection to { file_path, start_ln, end_ln, display_start, display_end }.
-- Returns nil if the start is not on a code line.
-- If the selection spans two files, clips the end back to the last line of the start file.
local function visual_range(session)
  -- '< and '> are only updated after leaving visual mode
  local start_disp = vim.fn.line("'<")
  local end_disp = vim.fn.line("'>")

  local file_path, start_ln = session.line_info(start_disp)
  local end_fp, end_ln = session.line_info(end_disp)
  if not file_path or not start_ln then
    return nil
  end

  -- clip cross-file selections to the start file
  if end_fp and end_fp ~= file_path then
    vim.notify("ceibo: selection spans multiple files — clipped to start file", vim.log.levels.WARN)
    end_ln = nil
    for i = end_disp, start_disp, -1 do
      local fp, ln = session.line_info(i)
      if fp == file_path and ln then
        end_ln = ln
        end_disp = i
        break
      end
    end
  end

  -- if end landed on a non-code line, walk backwards within the same file
  if not end_ln then
    for i = end_disp, start_disp, -1 do
      local fp, ln = session.line_info(i)
      if fp == file_path and ln then
        end_ln = ln
        end_disp = i
        break
      end
    end
  end

  return file_path, start_ln, end_ln or start_ln, start_disp, end_disp
end

function M.attach_diff(diff_bufnr, diff_win, fl_bufnr, fl_win)
  local cfg = require("ceibo.config").options
  if not cfg.set_default_keymaps then
    return
  end
  local km = cfg.keymaps
  local session = require("ceibo.session")
  local comments = require("ceibo.comments")
  local layout = require("ceibo.ui.layout")
  local export = require("ceibo.diff_export")
  local dv = require("ceibo.ui.diff_view")

  -- normal mode: add comment at cursor line
  nmap(diff_bufnr, km.add_comment, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local file_path, new_ln = session.line_info(cur)
    if not file_path or not new_ln then
      vim.notify("ceibo: cursor is not on a diff line with a line number", vim.log.levels.WARN)
      return
    end
    comments.prompt({
      file_path = file_path,
      line_nr = new_ln,
      display_line = cur,
      bufnr = diff_bufnr,
      existing = comments.get(file_path, new_ln),
      on_save = function()
        layout.refresh()
      end,
    })
  end, "Add comment at line")

  -- visual mode: add range comment over selection
  vmap(diff_bufnr, km.add_comment, function()
    -- exit visual so '< '> are set
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      local file_path, start_ln, end_ln, dstart, dend = visual_range(session)
      if not file_path then
        vim.notify("ceibo: selection not on diff lines", vim.log.levels.WARN)
        return
      end
      comments.prompt({
        file_path = file_path,
        line_nr = start_ln,
        end_ln = end_ln,
        display_line = dstart,
        display_end_line = dend,
        bufnr = diff_bufnr,
        existing = comments.get(file_path, start_ln),
        on_save = function()
          layout.refresh()
        end,
      })
    end)
  end, "Add range comment")

  -- delete comment at cursor line
  nmap(diff_bufnr, km.delete_comment, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local file_path, new_ln = session.line_info(cur)
    if not file_path then
      return
    end
    -- when cursor is on a file header, new_ln is nil → delete the file-scoped comment
    local ln = new_ln or 0
    comments.delete(file_path, ln, diff_bufnr)
    layout.refresh()
    vim.notify("ceibo: comment deleted", vim.log.levels.INFO)
  end, "Delete comment")

  -- remove ALL comments
  nmap(diff_bufnr, "X", function()
    comments.reset_all(diff_bufnr)
    layout.refresh()
    vim.notify("ceibo: all comments removed", vim.log.levels.INFO)
  end, "Remove all comments")

  -- yank to clipboard
  nmap(diff_bufnr, km.yank, function()
    export.yank()
  end, "Yank review to clipboard")

  -- submit: write review and quit
  nmap(diff_bufnr, km.submit, function()
    local outpath = export.submit()
    if outpath then
      -- Warn if other modified buffers exist (ceibo is launched from Claude Code and
      -- calls :qa to exit Neovim, which would discard unsaved work in other buffers)
      local modified_count = 0
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if buf ~= diff_bufnr and vim.bo[buf].modified then
          modified_count = modified_count + 1
        end
      end
      if modified_count > 0 then
        vim.notify(
          string.format(
            "ceibo: review written to %s\nWARNING: %d unsaved buffer(s) will be lost on exit.",
            outpath,
            modified_count
          ),
          vim.log.levels.WARN
        )
      else
        vim.notify("ceibo: review written to " .. outpath, vim.log.levels.INFO)
      end
      vim.defer_fn(function()
        vim.cmd("qa")
      end, 300)
    end
  end, "Submit review and exit")

  -- navigation
  nmap(diff_bufnr, km.next_hunk, function()
    dv.jump("next", "hunk")
  end, "Next hunk")
  nmap(diff_bufnr, km.prev_hunk, function()
    dv.jump("prev", "hunk")
  end, "Prev hunk")
  nmap(diff_bufnr, km.next_file, function()
    dv.jump("next", "file")
  end, "Next file")
  nmap(diff_bufnr, km.prev_file, function()
    dv.jump("prev", "file")
  end, "Prev file")

  -- mark current file reviewed + collapse; unmark + expand if already reviewed
  nmap(diff_bufnr, km.mark_reviewed, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local file_path = session.line_info(cur)
    if not file_path then
      return
    end

    session.toggle_reviewed(file_path)
    session.toggle_collapsed(file_path)
    layout.refresh()

    local now_reviewed = session.is_reviewed(file_path)
    local mark = now_reviewed and "✓ reviewed + collapsed" or "unmarked + expanded"
    vim.notify("ceibo: " .. file_path .. " " .. mark, vim.log.levels.INFO)

    -- after collapse: move to next file header; after expand: stay on own header
    local new_line_map = session.line_map
    if now_reviewed then
      -- collapsed — find next file header after current position
      local landed = false
      for i = cur + 1, #new_line_map do
        if new_line_map[i].is_file_header then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          landed = true
          break
        end
      end
      if not landed then
        -- no next file — land on own header
        for i = cur, 1, -1 do
          if new_line_map[i] and new_line_map[i].is_file_header then
            local f = session.files[new_line_map[i].file_idx]
            local fp = f and (f.new_path ~= "" and f.new_path or f.old_path)
            if fp == file_path then
              vim.api.nvim_win_set_cursor(0, { i, 0 })
              break
            end
          end
        end
      end
    else
      -- expanded — land on own file header
      for i = 1, #new_line_map do
        if new_line_map[i].is_file_header then
          local f = session.files[new_line_map[i].file_idx]
          local fp = f and (f.new_path ~= "" and f.new_path or f.old_path)
          if fp == file_path then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            break
          end
        end
      end
    end
  end, "Toggle file reviewed + collapse")

  -- open actual file at current line in a new tab
  nmap(diff_bufnr, "gf", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local file_path, new_ln = session.line_info(cur)
    if not file_path then
      vim.notify("ceibo: no file at cursor", vim.log.levels.WARN)
      return
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(file_path))
    if new_ln then
      vim.api.nvim_win_set_cursor(0, { new_ln, 0 })
    end
  end, "Open file in new tab")

  -- comment list float
  nmap(diff_bufnr, "<leader>cl", function()
    require("ceibo.ui.comment_list").open()
  end, "List all comments")

  -- toggle line wrap
  nmap(diff_bufnr, "W", function()
    vim.wo[diff_win].wrap = not vim.wo[diff_win].wrap
  end, "Toggle line wrap")

  -- increase / decrease diff context lines
  nmap(diff_bufnr, "+", function()
    session.context_lines = session.context_lines + 1
    require("ceibo.ui.layout").reload()
    vim.notify("ceibo: context lines → " .. session.context_lines, vim.log.levels.INFO)
  end, "Increase context lines")

  nmap(diff_bufnr, "-", function()
    session.context_lines = math.max(0, session.context_lines - 1)
    require("ceibo.ui.layout").reload()
    vim.notify("ceibo: context lines → " .. session.context_lines, vim.log.levels.INFO)
  end, "Decrease context lines")

  -- close
  nmap(diff_bufnr, km.close, function()
    require("ceibo.ui.layout").close()
  end, "Close review tab")

  -- help
  nmap(diff_bufnr, "?", function()
    M.show_help()
  end, "Show help")
end

function M.attach_split(old_bufnr, new_bufnr)
  local cfg = require("ceibo.config").options
  if not cfg.set_default_keymaps then
    return
  end

  local km = cfg.keymaps
  for _, bufnr in ipairs({ old_bufnr, new_bufnr }) do
    nmap(bufnr, km.close, function()
      require("ceibo.ui.layout").close()
    end, "Close review tab")
  end
end

function M.attach_file_list(fl_bufnr, fl_win)
  local cfg = require("ceibo.config").options
  if not cfg.set_default_keymaps then
    return
  end

  -- All keymaps read from session.file_lines at call time so they stay
  -- in sync after layout.refresh() re-renders the panel.
  nmap(fl_bufnr, "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    require("ceibo.ui.file_list").jump_to_file(cur, require("ceibo.session").file_lines)
  end, "Jump to file")

  nmap(fl_bufnr, "r", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local session = require("ceibo.session")
    local fi = session.file_lines[cur]
    if not fi then
      return
    end
    local file = session.files[fi]
    if not file then
      return
    end
    local path = file.new_path ~= "" and file.new_path or file.old_path
    session.toggle_reviewed(path)
    session.toggle_collapsed(path)
    require("ceibo.ui.layout").refresh()
  end, "Toggle reviewed + collapse")

  -- open actual file in new tab
  nmap(fl_bufnr, "gf", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local session = require("ceibo.session")
    local fi = session.file_lines[cur]
    if not fi then
      return
    end
    local file = session.files[fi]
    if not file then
      return
    end
    local path = file.new_path ~= "" and file.new_path or file.old_path
    if file.status == "D" then
      vim.notify("ceibo: file was deleted", vim.log.levels.WARN)
      return
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  end, "Open file in new tab")

  nmap(fl_bufnr, "q", function()
    require("ceibo.ui.layout").close()
  end, "Close")
end

function M.show_help()
  local cfg = require("ceibo.config").options
  local km = cfg.keymaps
  local function k(v)
    return v or "(disabled)"
  end
  local lines = {
    "",
    "  Diff window",
    "  " .. k(km.add_comment) .. "          Add/edit comment (normal: line, visual: range)",
    "  " .. k(km.delete_comment) .. "          Delete comment at cursor",
    "  X          Remove ALL comments",
    "  " .. k(km.yank) .. "          Yank review to clipboard",
    "  " .. k(km.submit) .. "          Submit → .git/ceibo_review.md + exit",
    "  " .. k(km.mark_reviewed) .. "          Toggle reviewed ✓ + collapse/expand",
    "  " .. k(km.next_hunk) .. " / " .. k(km.prev_hunk) .. "     Next/prev hunk",
    "  " .. k(km.next_file) .. " / " .. k(km.prev_file) .. "     Next/prev file",
    "  gf         Open file in new tab",
    "  W          Toggle line wrap",
    "  + / -      Increase / decrease context lines",
    "  " .. k(km.close) .. "          Close review tab",
    "  ?          This help",
    "",
    "  Comment prompt",
    "  <Tab>      Cycle type  (ISSUE → SUGGESTION → NOTE → PRAISE)",
    "  <S-Tab>    Cycle scope (line → file → general)",
    "  <C-s>      Save",
    "  <Esc>      Cancel",
    "",
    "  File list",
    "  <CR>       Jump to file in diff",
    "  r          Toggle reviewed ✓ + collapse/expand",
    "  gf         Open file in new tab",
    "  q          Close",
    "",
    "  q / <Esc>  Close this window",
    "",
  }

  -- fit width to longest line
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = width + 2 -- padding

  local height = math.min(#lines, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ceibo.nvim — keybindings ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close, { buffer = bufnr, noremap = true, silent = true })
  end
end

return M
