-- Annotation flow: comment on any file in the codebase (not tied to a git diff).
--
-- Comment scopes:
--   line    → anchored to { file_path, line_nr }  (line_nr >= 1)
--   file    → anchored to { file_path, 0 }
--   general → anchored to { "__general__", 0 }
--
-- Annotations are persisted in <data_dir>/annotations.json, independently of
-- the diff session (session.json).  Extmarks are placed in the real file buffer
-- on BufEnter and refreshed on add/delete.

local M = {}

-- { [file_path] = { [line_nr] = { type, text, end_ln, scope, extmark_id } } }
local store = {}
local ns = vim.api.nvim_create_namespace("ceibo_annotations")

local _uv = vim.uv or vim.loop
local _save_timer = nil

local GENERAL_KEY = "__general__"

-- ── persistence ──────────────────────────────────────────────────────────────

local function annotations_path()
  return require("ceibo.storage").data_dir() .. "/annotations.json"
end

local function flush_save()
  local serialisable = {}
  for file_path, lines in pairs(store) do
    serialisable[file_path] = {}
    for line_nr, c in pairs(lines) do
      serialisable[file_path][tostring(line_nr)] = {
        type = c.type,
        text = c.text,
        end_ln = c.end_ln,
        scope = c.scope,
      }
    end
  end
  local ok, encoded = pcall(vim.fn.json_encode, serialisable)
  if not ok then
    return
  end
  local f, err = io.open(annotations_path(), "w")
  if not f then
    vim.notify("ceibo: could not save annotations: " .. (err or "unknown"), vim.log.levels.WARN)
    return
  end
  f:write(encoded)
  f:close()
end

function M.save()
  if _save_timer then
    _save_timer:stop()
    _save_timer:close()
    _save_timer = nil
  end
  _save_timer = _uv.new_timer()
  _save_timer:start(
    200,
    0,
    vim.schedule_wrap(function()
      if _save_timer then
        _save_timer:close()
        _save_timer = nil
      end
      flush_save()
    end)
  )
end

function M.load()
  local f = io.open(annotations_path(), "r")
  if not f then
    return
  end
  local raw = f:read("*a")
  f:close()
  if raw == "" then
    return
  end
  local ok, decoded = pcall(vim.fn.json_decode, raw)
  if not ok or type(decoded) ~= "table" then
    return
  end
  store = {}
  for file_path, lines in pairs(decoded) do
    store[file_path] = {}
    for line_nr_str, c in pairs(lines) do
      store[file_path][tonumber(line_nr_str)] = {
        type = c.type,
        text = c.text,
        end_ln = c.end_ln,
        scope = c.scope,
      }
    end
  end
end

-- ── CRUD ─────────────────────────────────────────────────────────────────────

function M.get_all()
  return store
end

function M.get(file_path, line_nr)
  return store[file_path] and store[file_path][line_nr]
end

function M.get_file(file_path)
  return store[file_path] and store[file_path][0]
end

function M.get_general()
  return store[GENERAL_KEY] and store[GENERAL_KEY][0]
end

function M.count()
  local n = 0
  for _, lines in pairs(store) do
    for _ in pairs(lines) do
      n = n + 1
    end
  end
  return n
end

-- Place or replace an annotation.
-- bufnr is the real file buffer (may be nil if the file is not open).
function M.add(file_path, line_nr, ctype, text, bufnr, end_ln, scope)
  scope = scope or "line"
  if not store[file_path] then
    store[file_path] = {}
  end

  -- remove old extmark if the buffer is open
  local existing = store[file_path][line_nr]
  if existing and existing.extmark_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_del_extmark(bufnr, ns, existing.extmark_id)
  end

  local extmark_id = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    extmark_id = M._place_extmark(bufnr, line_nr, end_ln, ctype, text, scope)
  end

  store[file_path][line_nr] = {
    type = ctype,
    text = text,
    end_ln = end_ln,
    scope = scope,
    extmark_id = extmark_id,
  }
  M.save()
end

function M.delete(file_path, line_nr, bufnr)
  if not store[file_path] then
    return
  end
  local c = store[file_path][line_nr]
  if c and c.extmark_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_del_extmark(bufnr, ns, c.extmark_id)
  end
  store[file_path][line_nr] = nil
  if next(store[file_path]) == nil then
    store[file_path] = nil
  end
  M.save()
end

-- ── extmarks ─────────────────────────────────────────────────────────────────

local SCOPE_LABEL = { line = "", file = " [file]", general = " [general]" }

-- Place an extmark in a real file buffer.
-- line_nr is 1-based actual file line; 0 means file-scoped (placed at line 1).
function M._place_extmark(bufnr, line_nr, end_ln, ctype, text, scope)
  local type_hl = "CeiboComment" .. ctype:sub(1, 1) .. ctype:sub(2):lower()
  local scope_label = SCOPE_LABEL[scope] or ""
  local range_label = (end_ln and end_ln ~= line_nr and scope == "line")
      and ("lines " .. line_nr .. "–" .. end_ln .. " ")
    or ""

  -- for file-scoped (line_nr=0) and general, anchor to buffer line 1 (0-indexed: 0)
  local row = line_nr > 0 and (line_nr - 1) or 0

  -- clamp to the actual buffer length so stale annotations on deleted lines don't error
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  if buf_line_count == 0 then
    return nil
  end
  row = math.min(row, buf_line_count - 1)

  local ext_opts = {
    virt_text = {
      { "  ▶ [" .. ctype .. "]" .. scope_label .. " ", type_hl },
      { range_label .. text, "CeiboCommentText" },
    },
    virt_text_pos = "eol",
  }
  if end_ln and end_ln ~= line_nr and scope == "line" and end_ln > line_nr then
    ext_opts.end_row = math.min(end_ln - 1, buf_line_count - 1)
    ext_opts.hl_group = "CeiboRangeHL"
    ext_opts.hl_eol = true
  end
  return vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, ext_opts)
end

-- Render all annotations for a given file path into a buffer.
-- Called from BufEnter autocmd and after add/delete.
function M.render_for_buf(bufnr, file_path)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- buffer must be loaded (line count > 0) before we can place extmarks
  if vim.api.nvim_buf_line_count(bufnr) == 0 then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local file_comments = store[file_path]
  if file_comments then
    for line_nr, c in pairs(file_comments) do
      c.extmark_id = M._place_extmark(bufnr, line_nr, c.end_ln, c.type, c.text, c.scope or "line")
    end
  end

  -- general annotation: also rendered on every buffer at line 1
  local gen = store[GENERAL_KEY] and store[GENERAL_KEY][0]
  if gen then
    gen.extmark_id = M._place_extmark(bufnr, 0, nil, gen.type, gen.text, "general")
  end
end

-- ── prompt ───────────────────────────────────────────────────────────────────
-- Opens the same floating input used by the diff flow.
-- opts: { file_path, line_nr, end_ln, bufnr }
-- scope cycling: line → file → general  (same as diff prompt, but no display_line needed)
function M.prompt(opts)
  local TYPES = require("ceibo.config").get_types()
  local scopes = { "line", "file", "general" }

  local type_idx = 1
  local scope_idx = 1

  -- pre-fill if re-editing an existing annotation
  local existing = M.get(opts.file_path, opts.line_nr)
  if existing then
    local et = existing.type
    for i, t in ipairs(TYPES) do
      if t.name == et then
        type_idx = i
        break
      end
    end
  end

  local function resolve_anchor()
    local sc = scopes[scope_idx]
    if sc == "general" then
      return GENERAL_KEY, 0
    elseif sc == "file" then
      return opts.file_path, 0
    else
      return opts.file_path, opts.line_nr
    end
  end

  local function existing_text()
    local fp, ln = resolve_anchor()
    local c
    if fp == GENERAL_KEY then
      c = M.get_general()
    elseif ln == 0 then
      c = M.get_file(fp)
    else
      c = M.get(fp, ln)
    end
    return c and c.text or ""
  end

  local win_width = math.max(60, math.floor(vim.o.columns * 0.55))
  local max_height = math.max(3, math.floor(vim.o.lines * 0.30))

  local function header_chunks()
    local sc = scopes[scope_idx]
    local tp = TYPES[type_idx]
    return {
      { " Scope: ", "Comment" },
      { sc:upper(), "CeiboFileHeader" },
      { "  Type: ", "Comment" },
      { tp.name, tp.hl },
      { " ", "Normal" },
    }
  end

  local function location_hint()
    local sc = scopes[scope_idx]
    if sc == "line" then
      return (opts.end_ln and opts.end_ln ~= opts.line_nr)
          and ("lines " .. opts.line_nr .. "–" .. opts.end_ln)
        or ("line " .. (opts.line_nr or "?"))
    elseif sc == "file" then
      return opts.file_path
    else
      return "whole codebase"
    end
  end

  local function text_to_lines(t)
    if not t or t == "" then
      return { "" }
    end
    local lines = {}
    for ln in (t .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, ln)
    end
    return lines
  end

  local input_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, text_to_lines(existing_text()))

  local function centered_row(h)
    return math.max(0, math.floor((vim.o.lines - h - 2) / 2))
  end

  local init_h = math.min(max_height, math.max(1, #vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)))

  local input_win = vim.api.nvim_open_win(input_bufnr, true, {
    relative = "editor",
    row = centered_row(init_h),
    col = math.floor((vim.o.columns - win_width) / 2),
    width = win_width,
    height = init_h,
    style = "minimal",
    border = "rounded",
    title = header_chunks(),
    title_pos = "left",
    zindex = 50,
  })

  vim.wo[input_win].winhl = "Normal:Normal,FloatBorder:FloatBorder"
  vim.cmd("startinsert!")

  local function go_eol()
    local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    local last = #lines
    local col = #(lines[last] or "")
    pcall(vim.api.nvim_win_set_cursor, input_win, { last, col })
  end

  local function auto_resize()
    if not vim.api.nvim_win_is_valid(input_win) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    local h = math.min(max_height, math.max(1, #lines))
    vim.api.nvim_win_set_config(input_win, {
      height = h,
      row = centered_row(h),
      col = math.floor((vim.o.columns - win_width) / 2),
      relative = "editor",
    })
  end

  local resize_augroup = vim.api.nvim_create_augroup("ceibo_annotate_resize", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_bufnr,
    group = resize_augroup,
    callback = auto_resize,
  })

  local function refresh_title()
    vim.api.nvim_win_set_config(input_win, {
      title = header_chunks(),
      title_pos = "left",
    })
  end

  local function load_scope_text()
    local text = existing_text()
    vim.bo[input_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, text_to_lines(text))
    auto_resize()
    go_eol()
  end

  local function save_and_close()
    local raw_lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    local text = table.concat(raw_lines, "\n"):match("^%s*(.-)%s*$")
    local fp, ln = resolve_anchor()
    local sc = scopes[scope_idx]
    local tp = TYPES[type_idx].name
    local end_ln = (sc == "line") and opts.end_ln or nil

    vim.api.nvim_del_augroup_by_id(resize_augroup)
    vim.api.nvim_win_close(input_win, true)
    vim.cmd("stopinsert")

    if text == "" then
      M.delete(fp, ln, opts.bufnr)
    else
      M.add(fp, ln, tp, text, opts.bufnr, end_ln, sc)
    end
  end

  local function cancel()
    vim.api.nvim_del_augroup_by_id(resize_augroup)
    vim.api.nvim_win_close(input_win, true)
    vim.cmd("stopinsert")
  end

  local function imap(lhs, rhs)
    vim.keymap.set("i", lhs, rhs, { buffer = input_bufnr, noremap = true, silent = true })
  end
  local function nmap(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = input_bufnr, noremap = true, silent = true })
  end

  imap("<Tab>", function()
    type_idx = (type_idx % #TYPES) + 1
    refresh_title()
  end)

  imap("<S-Tab>", function()
    scope_idx = (scope_idx % #scopes) + 1
    refresh_title()
    load_scope_text()
  end)

  imap("<C-s>", save_and_close)
  nmap("<C-s>", save_and_close)
  imap("<Esc>", cancel)
  nmap("<Esc>", cancel)
  nmap("q", cancel)

  go_eol()
end

-- ── public commands ───────────────────────────────────────────────────────────

-- Add/edit annotation at cursor in the current buffer.
-- Works in normal mode (single line) and is called with range in visual mode.
function M.cmd_comment(range_given, line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    vim.notify("ceibo: buffer has no file path", vim.log.levels.WARN)
    return
  end
  -- make path relative to cwd when possible
  local cwd = vim.fn.getcwd()
  if file_path:sub(1, #cwd + 1) == cwd .. "/" then
    file_path = file_path:sub(#cwd + 2)
  end

  local line_nr, end_ln
  if range_given then
    line_nr = line1
    end_ln = (line2 ~= line1) and line2 or nil
  else
    line_nr = vim.api.nvim_win_get_cursor(0)[1]
    end_ln = nil
  end

  M.prompt({
    file_path = file_path,
    line_nr = line_nr,
    end_ln = end_ln,
    bufnr = bufnr,
  })
end

-- Delete the line-scoped annotation at the cursor in the current buffer.
function M.cmd_delete()
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    vim.notify("ceibo: buffer has no file path", vim.log.levels.WARN)
    return
  end
  local cwd = vim.fn.getcwd()
  if file_path:sub(1, #cwd + 1) == cwd .. "/" then
    file_path = file_path:sub(#cwd + 2)
  end

  local line_nr = vim.api.nvim_win_get_cursor(0)[1]
  local c = M.get(file_path, line_nr)
  if not c then
    vim.notify("ceibo: no annotation at line " .. line_nr, vim.log.levels.INFO)
    return
  end

  M.delete(file_path, line_nr, bufnr)
  vim.notify("ceibo: annotation deleted", vim.log.levels.INFO)
end

-- ── BufEnter wiring ──────────────────────────────────────────────────────────

-- Attach the BufEnter autocmd that renders annotations in real file buffers.
-- Called once from setup (init.lua).
function M.setup_autocmd()
  M.load()
  local group = vim.api.nvim_create_augroup("CeiboAnnotations", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local file_path = vim.api.nvim_buf_get_name(ev.buf)
      if file_path == "" then
        return
      end
      local cwd = vim.fn.getcwd()
      if file_path:sub(1, #cwd + 1) == cwd .. "/" then
        file_path = file_path:sub(#cwd + 2)
      end
      -- only render if we have annotations for this file (or general)
      if store[file_path] or store[GENERAL_KEY] then
        M.render_for_buf(ev.buf, file_path)
      end
    end,
  })
end

return M
