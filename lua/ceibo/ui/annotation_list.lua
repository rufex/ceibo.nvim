-- Floating summary of all annotations across the repo.
-- <CR> jumps to the annotated location in the real file.
-- d    deletes the annotation under the cursor and refreshes the list.

local M = {}
local ns = vim.api.nvim_create_namespace("ceibo_annotation_list")

-- Build a sorted list of { file_path, line_nr, end_ln, type, text, scope }
local function collect(store)
  local entries = {}

  local gen = store["__general__"] and store["__general__"][0]
  if gen then
    table.insert(entries, {
      file_path = "__general__",
      line_nr = 0,
      type = gen.type,
      text = gen.text,
      scope = "general",
    })
  end

  local paths = {}
  for fp, _ in pairs(store) do
    if fp ~= "__general__" then
      table.insert(paths, fp)
    end
  end
  table.sort(paths)

  for _, path in ipairs(paths) do
    local file_comments = store[path]
    if file_comments[0] then
      local c = file_comments[0]
      table.insert(entries, {
        file_path = path,
        line_nr = 0,
        type = c.type,
        text = c.text,
        scope = c.scope or "file",
      })
    end
    local sorted = {}
    for ln, c in pairs(file_comments) do
      if ln ~= 0 then
        table.insert(sorted, { ln = ln, c = c })
      end
    end
    table.sort(sorted, function(a, b)
      return a.ln < b.ln
    end)
    for _, entry in ipairs(sorted) do
      table.insert(entries, {
        file_path = path,
        line_nr = entry.ln,
        end_ln = entry.c.end_ln,
        type = entry.c.type,
        text = entry.c.text,
        scope = entry.c.scope or "line",
      })
    end
  end

  return entries
end

-- Build display lines + highlight specs + entry_map from entries.
-- Returns { lines, hl_specs, entry_map, count }.
local function build_display(entries)
  local lines = {}
  local hl_specs = {}
  local entry_map = {}

  local function push(text, entry, specs)
    table.insert(lines, text)
    entry_map[#lines] = entry or false  -- false as sentinel for non-entry rows
    local lnum = #lines - 1
    for _, s in ipairs(specs or {}) do
      table.insert(hl_specs, { lnum = lnum, cs = s[1], ce = s[2], hl = s[3] })
    end
  end

  push(" Annotations  [<CR> jump · d delete · q close]", nil, { { 0, -1, "CeiboFileHeader" } })
  push(string.rep("─", 60), nil, {})

  local last_file = nil
  for _, e in ipairs(entries) do
    local section = e.scope == "general" and "__general__" or e.file_path
    if section ~= last_file then
      if last_file then
        push("", nil, {})
      end
      local header = e.scope == "general" and " [general note]" or (" " .. e.file_path)
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
    local preview = (e.text or ""):match("^([^\n]*)")
    local line = label .. preview

    local type_end = #label - 1
    push(line, e, {
      { 3, 3 + #loc, "CeiboHdr" },
      { 3 + #loc + 2, type_end, type_hl },
      { type_end + 1, -1, "CeiboCommentText" },
    })
  end

  return lines, hl_specs, entry_map
end

-- Write lines into bufnr and apply highlights.
local function render(bufnr, lines, hl_specs)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, s in ipairs(hl_specs) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, s.hl, s.lnum, s.cs, s.ce)
  end
end

function M.open()
  local annotate = require("ceibo.annotate")

  local function current_entries()
    return collect(annotate.get_all())
  end

  local entries = current_entries()
  if #entries == 0 then
    vim.notify("ceibo: no annotations yet", vim.log.levels.INFO)
    return
  end

  local lines, hl_specs, entry_map = build_display(entries)

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
    title = " ceibo annotations: " .. #entries .. " annotation(s) ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].wrap = false

  render(bufnr, lines, hl_specs)

  -- first entry position (skip header + separator)
  local function first_entry_line(emap)
    for i = 1, #emap do
      if emap[i] and emap[i] ~= false then
        return i
      end
    end
    return 1
  end
  vim.api.nvim_win_set_cursor(win, { first_entry_line(entry_map), 0 })

  -- refresh the float in place after a mutation
  local function refresh(cursor_hint)
    local new_entries = current_entries()
    if #new_entries == 0 then
      vim.api.nvim_win_close(win, true)
      vim.notify("ceibo: no annotations remaining", vim.log.levels.INFO)
      return
    end
    local nl, nhl, nem = build_display(new_entries)
    render(bufnr, nl, nhl)
    entry_map = nem
    -- update title
    vim.api.nvim_win_set_config(win, {
      title = " ceibo annotations: " .. #new_entries .. " annotation(s) ",
      title_pos = "center",
    })
    -- restore cursor to same position or clamp
    local target = math.min(cursor_hint or 1, #nl)
    target = math.max(target, first_entry_line(nem))
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end

  -- <CR>: jump to location
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local entry = entry_map[cur]
    if not entry or entry == false then
      return
    end

    if entry.scope == "general" then
      vim.notify("ceibo: general annotation (no specific location)", vim.log.levels.INFO)
      return
    end

    local abs_path = entry.file_path
    if not abs_path:match("^/") then
      abs_path = vim.fn.getcwd() .. "/" .. abs_path
    end
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
    local target_line = (entry.line_nr > 0) and entry.line_nr or 1
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    vim.cmd("normal! zz")
  end, { buffer = bufnr, noremap = true, silent = true })

  -- d: delete annotation under cursor and refresh
  vim.keymap.set("n", "d", function()
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local entry = entry_map[cur]
    if not entry or entry == false then
      return
    end

    -- find the real buffer for this file (if open) so extmarks are cleaned up
    local real_bufnr = nil
    if entry.file_path ~= "__general__" then
      local abs_path = entry.file_path
      if not abs_path:match("^/") then
        abs_path = vim.fn.getcwd() .. "/" .. abs_path
      end
      -- iterate loaded buffers for an exact name match
      for _, bid in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bid) and vim.api.nvim_buf_get_name(bid) == abs_path then
          real_bufnr = bid
          break
        end
      end
    end

    annotate.delete(entry.file_path, entry.line_nr, real_bufnr)
    refresh(cur)
  end, { buffer = bufnr, noremap = true, silent = true })

  -- close
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = bufnr, noremap = true, silent = true })
  end
end

return M
