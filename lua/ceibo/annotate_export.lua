-- Generates the Markdown annotation document from the annotation store.
-- This is separate from export.lua (which handles the diff review flow).

local M = {}

-- Extract up to `radius` lines of context around `target_ln` from the real file.
local function get_file_context(file_path, target_ln, radius)
  -- resolve absolute path
  local abs_path = file_path
  if not file_path:match("^/") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end

  local f = io.open(abs_path, "r")
  if not f then
    return nil
  end
  local all_lines = {}
  for line in f:lines() do
    table.insert(all_lines, line)
  end
  f:close()

  local from = math.max(1, target_ln - radius)
  local to = math.min(#all_lines, target_ln + radius)
  if from > to then
    return nil
  end

  local result = {}
  for i = from, to do
    local prefix = (i == target_ln) and ">" or " "
    table.insert(result, string.format("%s %4d │ %s", prefix, i, all_lines[i] or ""))
  end
  return result
end

function M.build_markdown()
  local annotate = require("ceibo.annotate")
  local cfg = require("ceibo.config")
  local TYPES = cfg.get_types()
  local store = annotate.get_all()

  local out = {}
  local function w(s)
    table.insert(out, s)
  end

  -- introduction
  w("I have annotated the following code.")
  w("")

  -- format legend
  w("Format: [SCOPE] [TYPE] <file>:<line> >> <comment>")
  w("")

  -- type definitions
  w("## Comment types")
  w("")
  for _, t in ipairs(TYPES) do
    w("- **" .. t.name .. "**: " .. t.description)
  end
  w("")

  -- scope definitions
  w("## Comment scopes")
  w("")
  w("- **LINE**: anchored to a specific line or range in the file")
  w("- **FILE**: applies to the entire file")
  w("- **GENERAL**: applies to the whole codebase note")
  w("")

  -- comments
  w("## Annotations")
  w("")

  local has_comments = false

  -- general first
  local general = store["__general__"] and store["__general__"][0]
  if general then
    has_comments = true
    w("[GENERAL] [" .. general.type .. "] (no location) >> " .. general.text)
    w("")
  end

  -- collect all non-general file paths and sort them
  local paths = {}
  for fp, _ in pairs(store) do
    if fp ~= "__general__" then
      table.insert(paths, fp)
    end
  end
  table.sort(paths)

  for _, path in ipairs(paths) do
    local file_comments = store[path]

    -- file-scoped comment (line_nr == 0)
    local file_note = file_comments[0]
    if file_note then
      has_comments = true
      w("[FILE] [" .. file_note.type .. "] " .. path .. " >> " .. file_note.text)
      w("")
    end

    -- line comments, sorted by line number
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
      has_comments = true
      local ln = entry.ln
      local c = entry.c
      local location = (c.end_ln and c.end_ln ~= ln) and (path .. ":" .. ln .. "-" .. c.end_ln)
        or (path .. ":" .. ln)
      w("[LINE] [" .. c.type .. "] " .. location .. " >> " .. c.text)

      local ctx = get_file_context(path, ln, 2)
      if ctx then
        w("```")
        for _, cl in ipairs(ctx) do
          w(cl)
        end
        w("```")
      end
      w("")
    end
  end

  if not has_comments then
    w("_No annotations._")
  end

  return table.concat(out, "\n")
end

function M.yank()
  local md = M.build_markdown()
  vim.fn.setreg("+", md)
  vim.fn.setreg('"', md)
  vim.notify(
    "ceibo: annotations copied to clipboard (" .. require("ceibo.annotate").count() .. " annotation(s))",
    vim.log.levels.INFO
  )
end

function M.report()
  local storage = require("ceibo.storage")
  local md = M.build_markdown()

  local outpath = storage.data_dir() .. "/annotations.md"
  local f, err = io.open(outpath, "w")
  if not f then
    vim.notify("ceibo: could not write annotations report: " .. (err or ""), vim.log.levels.ERROR)
    return nil
  end
  f:write(md)
  f:close()

  -- also yank
  vim.fn.setreg("+", md)
  vim.fn.setreg('"', md)

  vim.notify("ceibo: annotations report written to " .. outpath .. " (also copied to clipboard)", vim.log.levels.INFO)
  return outpath
end

return M
