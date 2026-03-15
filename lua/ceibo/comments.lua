-- Comment storage and virtual text management.
--
-- Three comment scopes:
--   line     → anchored to { file_path, line_nr }  (line_nr >= 1)
--   file     → anchored to { file_path, 0 }        (sentinel line_nr = 0)
--   general  → anchored to { "__general__",  0 }
--
-- Virtual text is rendered in the diff buffer via extmarks.

local M = {}

-- { [file_path] = { [line_nr] = { type, text, extmark_id } } }
-- file_path "__general__" holds the single general comment at key 0.
local store = {}
local ns = vim.api.nvim_create_namespace("ceibo_comments")

local _uv = vim.uv or vim.loop -- luv handle; vim.uv in nvim ≥0.10, vim.loop before
local _save_timer = nil -- debounce handle

local GENERAL_KEY = "__general__"

-- ── persistence ────────────────────────────────────────────────────────────

-- Return the absolute path to the session auto-save file.
local function session_path()
  return require("ceibo.storage").data_dir() .. "/session.json"
end

local function flush_save()
  local session = require("ceibo.session")
  local serialisable = {
    comments = {},
    reviewed = session.reviewed or {},
    collapsed = session.collapsed or {},
  }
  for file_path, lines in pairs(store) do
    serialisable.comments[file_path] = {}
    for line_nr, c in pairs(lines) do
      serialisable.comments[file_path][tostring(line_nr)] = {
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
  local f, err = io.open(session_path(), "w")
  if not f then
    vim.notify("ceibo: could not save session: " .. (err or "unknown"), vim.log.levels.WARN)
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
  local f = io.open(session_path(), "r")
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

  local comments_data = decoded.comments or decoded
  local reviewed_data = decoded.reviewed or {}
  local collapsed_data = decoded.collapsed or {}

  store = {}
  for file_path, lines in pairs(comments_data) do
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

  local session = require("ceibo.session")
  for path, v in pairs(reviewed_data) do
    if v then
      session.reviewed[path] = true
    end
  end
  for path, v in pairs(collapsed_data) do
    if v then
      session.collapsed[path] = true
    end
  end
end

function M.reset()
  store = {}
end

-- Delete every comment and persist the empty state.
function M.reset_all(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  store = {}
  M.save()
end

function M.get_all()
  return store
end

-- ── CRUD ───────────────────────────────────────────────────────────────────

-- scope: "line" | "file" | "general"
-- For file scope  → line_nr = 0, file_path = actual path
-- For general     → line_nr = 0, file_path = GENERAL_KEY
function M.add(file_path, line_nr, ctype, text, bufnr, display_line, end_ln, display_end_line, scope)
  scope = scope or "line"
  if not store[file_path] then
    store[file_path] = {}
  end

  local existing = store[file_path][line_nr]
  if existing and existing.extmark_id and bufnr then
    vim.api.nvim_buf_del_extmark(bufnr, ns, existing.extmark_id)
  end

  local extmark_id = nil
  if bufnr and display_line then
    extmark_id = M._place_extmark(bufnr, display_line, display_end_line, ctype, text, end_ln, line_nr, scope)
  end

  store[file_path][line_nr] = {
    type = ctype,
    text = text,
    end_ln = end_ln,
    scope = scope,
    extmark_id = extmark_id,
    display_line = display_line,
    display_end_line = display_end_line,
  }
  M.save()
end

function M.delete(file_path, line_nr, bufnr)
  if not store[file_path] then
    return
  end
  local c = store[file_path][line_nr]
  if c and c.extmark_id and bufnr then
    vim.api.nvim_buf_del_extmark(bufnr, ns, c.extmark_id)
  end
  store[file_path][line_nr] = nil
  M.save()
end

-- Get a line-scoped comment
function M.get(file_path, line_nr)
  if not store[file_path] then
    return nil
  end
  return store[file_path][line_nr]
end

-- Get the file-scoped comment for a path
function M.get_file(file_path)
  if not store[file_path] then
    return nil
  end
  return store[file_path][0]
end

-- Get the general comment
function M.get_general()
  if not store[GENERAL_KEY] then
    return nil
  end
  return store[GENERAL_KEY][0]
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

-- ── extmark helpers ────────────────────────────────────────────────────────

local SCOPE_LABEL = { line = "", file = " [file]", general = " [general]" }

function M._place_extmark(bufnr, display_line, display_end_line, ctype, text, end_ln, line_nr, scope)
  local type_hl = "CeiboComment" .. ctype:sub(1, 1) .. ctype:sub(2):lower()
  local range_label = (end_ln and end_ln ~= line_nr and (scope == "line"))
      and ("lines " .. line_nr .. "–" .. end_ln .. " ")
    or ""
  local scope_label = SCOPE_LABEL[scope] or ""

  local ext_opts = {
    virt_text = {
      { "  ▶ [" .. ctype .. "]" .. scope_label .. " ", type_hl },
      { range_label .. text, "CeiboCommentText" },
    },
    virt_text_pos = "eol",
  }
  if display_end_line and display_end_line > display_line then
    ext_opts.end_row = display_end_line - 1
    ext_opts.hl_group = "CeiboRangeHL"
    ext_opts.hl_eol = true
  end
  return vim.api.nvim_buf_set_extmark(bufnr, ns, display_line - 1, 0, ext_opts)
end

-- Re-render all extmarks after a buffer refresh.
function M.render_all(bufnr, line_map)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local session = require("ceibo.session")

  -- Build reverse index: idx[file_path][new_ln] = display_line (1-based)
  -- Also track the first display line per file for file-scoped comments.
  local idx = {} -- idx[fp][ln] = display_line
  local file_hdr = {} -- file_hdr[fp] = display_line of file header
  local first_disp = nil -- display line 1 for general comment

  for di, meta in ipairs(line_map) do
    if first_disp == nil then
      first_disp = di
    end
    if meta.file_idx and meta.is_file_header then
      local f = session.files and session.files[meta.file_idx]
      if f then
        local fp = f.new_path ~= "" and f.new_path or f.old_path
        if not file_hdr[fp] then
          file_hdr[fp] = di
        end
      end
    end
    if meta.file_idx and meta.new_ln then
      local f = session.files and session.files[meta.file_idx]
      if f then
        local fp = f.new_path ~= "" and f.new_path or f.old_path
        if not idx[fp] then
          idx[fp] = {}
        end
        if not idx[fp][meta.new_ln] then
          idx[fp][meta.new_ln] = di
        end
      end
    end
  end

  for file_path, lines in pairs(store) do
    for line_nr, c in pairs(lines) do
      local di

      if file_path == GENERAL_KEY then
        -- general comment: pin to display line 1
        di = first_disp or 1
      elseif line_nr == 0 then
        -- file-scoped comment: pin to the file header line
        di = file_hdr[file_path]
      else
        -- line comment
        di = idx[file_path] and idx[file_path][line_nr]
      end

      if di then
        local display_end = nil
        if c.end_ln and c.end_ln ~= line_nr and line_nr > 0 then
          display_end = idx[file_path] and idx[file_path][c.end_ln]
        end
        c.extmark_id = M._place_extmark(bufnr, di, display_end, c.type, c.text, c.end_ln, line_nr, c.scope or "line")
        c.display_line = di
        c.display_end_line = display_end
      end
    end
  end
end

-- ── prompt ─────────────────────────────────────────────────────────────────
-- Opens an inline floating input window.
-- TAB   → cycle comment type forward
-- S-TAB → cycle scope (line → file → general)
-- CR    → save   ESC/q → cancel
--
-- opts: { file_path, line_nr, end_ln, display_line, display_end_line, bufnr, on_save, existing, scope }
function M.prompt(opts)
  local TYPES = require("ceibo.config").get_types()
  local scopes = { "line", "file", "general" }

  -- initial state
  local type_idx = 1
  local scope_idx = 1

  -- respect existing comment state if re-opening
  if opts.existing then
    local et = opts.existing.type
    for i, t in ipairs(TYPES) do
      if t.name == et then
        type_idx = i
        break
      end
    end
  end
  if opts.scope then
    for i, s in ipairs(scopes) do
      if s == opts.scope then
        scope_idx = i
        break
      end
    end
  end

  -- helper: resolve (file_path, line_nr) for current scope
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

  -- helper: fetch existing text for the current scope
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

  -- ── build the floating window ───────────────────────────────────────────
  local win_width = math.max(60, math.floor(vim.o.columns * 0.55))
  local max_height = math.max(3, math.floor(vim.o.lines * 0.30))
  local statusbar = require("ceibo.ui.statusbar")

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
    return sc == "line"
        and (opts.end_ln and opts.end_ln ~= opts.line_nr and ("lines " .. opts.line_nr .. "–" .. opts.end_ln) or ("line " .. (opts.line_nr or "?")))
      or (sc == "file" and opts.file_path or "whole review")
  end

  -- split stored text (may contain \n) into lines for the buffer
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

  -- compute centered row for a window of the given height
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
  statusbar.set_prompt_mode(scopes, scope_idx, TYPES, type_idx, location_hint())

  -- move cursor to end of last line
  local function go_eol()
    local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    local last = #lines
    local col = #(lines[last] or "")
    pcall(vim.api.nvim_win_set_cursor, input_win, { last, col })
  end

  -- resize the float to fit current line count
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

  -- auto-resize on every buffer change
  local resize_augroup = vim.api.nvim_create_augroup("ceibo_prompt_resize", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_bufnr,
    group = resize_augroup,
    callback = auto_resize,
  })

  -- ── helpers ─────────────────────────────────────────────────────────────

  local function refresh_title()
    vim.api.nvim_win_set_config(input_win, {
      title = header_chunks(),
      title_pos = "left",
    })
    statusbar.set_prompt_mode(scopes, scope_idx, TYPES, type_idx, location_hint())
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

    vim.api.nvim_del_augroup_by_id(resize_augroup)
    vim.api.nvim_win_close(input_win, true)
    vim.cmd("stopinsert")
    statusbar.set_normal_mode()

    if text == "" then
      M.delete(fp, ln, opts.bufnr)
    else
      local end_ln, disp_end
      if sc == "line" then
        end_ln = opts.end_ln
        disp_end = opts.display_end_line
      end
      M.add(fp, ln, tp, text, opts.bufnr, opts.display_line, end_ln, disp_end, sc)
    end
    if opts.on_save then
      opts.on_save()
    end
  end

  local function cancel()
    vim.api.nvim_del_augroup_by_id(resize_augroup)
    vim.api.nvim_win_close(input_win, true)
    vim.cmd("stopinsert")
    statusbar.set_normal_mode()
  end

  -- ── keymaps inside the float ─────────────────────────────────────────────

  local function imap(lhs, rhs)
    vim.keymap.set("i", lhs, rhs, { buffer = input_bufnr, noremap = true, silent = true })
  end
  local function nmap(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = input_bufnr, noremap = true, silent = true })
  end

  -- TAB: cycle type
  imap("<Tab>", function()
    type_idx = (type_idx % #TYPES) + 1
    refresh_title()
  end)

  -- S-TAB: cycle scope, load existing text for that scope
  imap("<S-Tab>", function()
    scope_idx = (scope_idx % #scopes) + 1
    refresh_title()
    load_scope_text()
  end)

  -- C-s: save (insert + normal)
  imap("<C-s>", save_and_close)
  nmap("<C-s>", save_and_close)

  -- ESC / q: cancel
  imap("<Esc>", cancel)
  nmap("<Esc>", cancel)
  nmap("q", cancel)

  go_eol()
end

-- Apply highlight groups from config.
-- Explicit entries in options.highlights take precedence.
-- Any type whose hl group is not explicitly defined falls back to DiagnosticInfo.
function M.setup_highlights()
  local cfg = require("ceibo.config")
  local hls = cfg.options.highlights
  for name, def in pairs(hls) do
    vim.api.nvim_set_hl(0, name, def)
  end
  -- ensure every configured type has a highlight group
  for _, t in ipairs(cfg.get_types()) do
    if not hls[t.hl] then
      vim.api.nvim_set_hl(0, t.hl, { link = "DiagnosticInfo" })
    end
  end
end

return M
