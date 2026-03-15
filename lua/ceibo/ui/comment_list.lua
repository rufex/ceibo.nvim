-- Floating summary of all comments. <CR> jumps to location in diff.

local M = {}
local ns = vim.api.nvim_create_namespace("ceibo_list")

local function file_path_for(file)
  return file.new_path ~= "" and file.new_path or file.old_path
end

-- Build sorted list of { file_path, line_nr, end_ln, type, text, file_idx, scope }
local function collect(session, store)
  local entries = {}
  for fi, file in ipairs(session.files) do
    local path = file_path_for(file)
    local file_comments = store[path]
    if file_comments then
      for line_nr, c in pairs(file_comments) do
        table.insert(entries, {
          file_path = path,
          file_idx = fi,
          line_nr = line_nr,
          end_ln = c.end_ln,
          type = c.type,
          text = c.text,
          scope = c.scope or "line",
        })
      end
    end
  end
  -- general comment
  local gen = store["__general__"] and store["__general__"][0]
  if gen then
    table.insert(entries, {
      file_path = "__general__",
      file_idx = 0,
      line_nr = 0,
      type = gen.type,
      text = gen.text,
      scope = "general",
    })
  end
  table.sort(entries, function(a, b)
    if a.file_idx ~= b.file_idx then
      return a.file_idx < b.file_idx
    end
    return a.line_nr < b.line_nr
  end)
  return entries
end

function M.open()
  local session = require("ceibo.session")
  local comments = require("ceibo.comments")
  local store = comments.get_all()

  local entries = collect(session, store)

  if #entries == 0 then
    vim.notify("ceibo: no comments yet", vim.log.levels.INFO)
    return
  end

  -- build display lines + highlight specs
  local lines = {}
  local hl_specs = {}
  local entry_map = {} -- display line → entry

  local function push(text, entry, specs)
    table.insert(lines, text)
    table.insert(entry_map, entry)
    local lnum = #lines - 1
    for _, s in ipairs(specs or {}) do
      table.insert(hl_specs, { lnum = lnum, cs = s[1], ce = s[2], hl = s[3] })
    end
  end

  push(" Comments  [<CR> jump · q close]", nil, { { 0, -1, "CeiboFileHeader" } })
  push(string.rep("─", 60), nil, {})

  local last_file = nil
  for _, e in ipairs(entries) do
    -- section header
    local section = e.scope == "general" and "__general__" or e.file_path
    if section ~= last_file then
      if last_file then
        push("", nil, {})
      end
      local header = e.scope == "general" and " [general review note]" or (" " .. e.file_path)
      push(header, nil, { { 0, -1, "Title" } })
      last_file = section
    end

    local type_hl = "CeiboComment" .. e.type:sub(1, 1) .. e.type:sub(2):lower()
    local loc
    if e.scope == "general" then
      loc = "general"
    elseif e.scope == "file" or e.line_nr == 0 then
      loc = "file"
    elseif e.end_ln and e.end_ln ~= e.line_nr then
      loc = e.line_nr .. "–" .. e.end_ln
    else
      loc = tostring(e.line_nr)
    end
    local label = string.format("   :%s [%s] ", loc, e.type)
    -- show only first line of multi-line comments
    local preview = (e.text or ""):match("^([^\n]*)")
    local line = label .. preview

    local type_end = #label - 1
    push(line, e, {
      { 3, 3 + #loc, "CeiboHdr" },
      { 3 + #loc + 2, type_end, type_hl },
      { type_end + 1, -1, "CeiboCommentText" },
    })
  end

  -- floating window
  local width = math.max(60, math.floor(vim.o.columns * 0.55))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = false

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = " ceibo: " .. #entries .. " comment(s) ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].wrap = false

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, s in ipairs(hl_specs) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, s.hl, s.lnum, s.cs, s.ce)
  end

  -- jump to entry on <CR>
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local entry = entry_map[cur]
    if not entry then
      return
    end
    vim.api.nvim_win_close(win, true)

    local diff_win = require("ceibo.ui.file_list").get_diff_win()
    if not diff_win then
      return
    end

    -- general comment → jump to line 1
    if entry.scope == "general" then
      vim.api.nvim_set_current_win(diff_win)
      vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
      return
    end

    -- file-scoped comment → jump to file header line
    if entry.scope == "file" or entry.line_nr == 0 then
      for di, meta in ipairs(session.line_map) do
        if meta.is_file_header and meta.file_idx == entry.file_idx then
          vim.api.nvim_set_current_win(diff_win)
          vim.api.nvim_win_set_cursor(diff_win, { di, 0 })
          return
        end
      end
      vim.notify("ceibo: could not locate file in diff view", vim.log.levels.WARN)
      return
    end

    -- line-scoped comment → jump to matching new_ln
    for di, meta in ipairs(session.line_map) do
      if meta.file_idx == entry.file_idx and meta.new_ln == entry.line_nr then
        vim.api.nvim_set_current_win(diff_win)
        vim.api.nvim_win_set_cursor(diff_win, { di, 0 })
        return
      end
    end
    vim.notify("ceibo: could not locate line in diff view", vim.log.levels.WARN)
  end, { buffer = bufnr, noremap = true, silent = true })

  -- close
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = bufnr, noremap = true, silent = true })
  end

  -- position cursor on the first actual entry (skip header + separator lines)
  local first_entry_line = #lines -- fallback: last line
  for i, e in ipairs(entry_map) do
    if e ~= nil then
      first_entry_line = i
      break
    end
  end
  vim.api.nvim_win_set_cursor(win, { first_entry_line, 0 })
end

return M
