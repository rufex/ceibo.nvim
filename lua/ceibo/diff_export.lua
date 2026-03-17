-- Generates the Markdown review document and writes it to disk.

local M = {}

function M.build_markdown()
  local session = require("ceibo.session")
  local comments = require("ceibo.comments")
  local cfg = require("ceibo.config")
  local TYPES = cfg.get_types()
  local store = comments.get_all()

  local lines = {}
  local function w(s)
    table.insert(lines, s)
  end

  -- introduction
  w("I have reviewed your changes, here is my feedback.")
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
  w("- **GENERAL**: applies to the whole review")
  w("")

  -- comments
  w("## Comments")
  w("")

  local has_comments = false

  -- general comment first
  local general = store["__general__"] and store["__general__"][0]
  if general then
    has_comments = true
    w("[GENERAL] [" .. general.type .. "] (no location) >> " .. general.text)
  end

  -- per-file comments
  for _, file in ipairs(session.files) do
    local path = file.new_path ~= "" and file.new_path or file.old_path
    local file_comments = store[path]
    if not file_comments then
      goto continue
    end

    -- file-scoped comment (line_nr == 0)
    local file_note = file_comments[0]
    if file_note then
      has_comments = true
      w("[FILE] [" .. file_note.type .. "] " .. path .. " >> " .. file_note.text)
    end

    -- line comments, sorted
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
      local location = (c.end_ln and c.end_ln ~= ln) and (path .. ":" .. ln .. "-" .. c.end_ln) or (path .. ":" .. ln)
      w("[LINE] [" .. c.type .. "] " .. location .. " >> " .. c.text)

      local ctx = M.get_diff_context(file, ln, 2)
      if ctx then
        w("```diff")
        for _, cl in ipairs(ctx) do
          w(cl)
        end
        w("```")
      end
    end

    ::continue::
  end

  if not has_comments then
    w("_No comments._")
  end

  return table.concat(lines, "\n")
end

-- Extract up to `radius` lines of diff context around new_ln from a parsed file.
-- Deleted lines (no new_ln) are included when the surrounding new_ln is within radius.
function M.get_diff_context(file, target_ln, radius)
  local result = {}
  for _, hunk in ipairs(file.hunks) do
    local last_new_ln = hunk.new_start
    for _, dl in ipairs(hunk.lines) do
      if dl.new_ln then
        last_new_ln = dl.new_ln
      end
      if dl.type == "hdr" then
        -- skip
      elseif dl.type == "del" then
        if math.abs(last_new_ln - target_ln) <= radius then
          table.insert(result, "-" .. (dl.content or ""))
        end
      elseif dl.new_ln and math.abs(dl.new_ln - target_ln) <= radius then
        local prefix = dl.type == "add" and "+" or " "
        table.insert(result, prefix .. (dl.content or ""))
      end
    end
  end
  if #result == 0 then
    return nil
  end
  return result
end

-- Write review to the configured output path and return it
function M.submit()
  local storage = require("ceibo.storage")
  local md = M.build_markdown()

  local outpath = storage.data_dir() .. "/review.md"

  local f, err = io.open(outpath, "w")
  if not f then
    vim.notify("ceibo: could not write review: " .. (err or ""), vim.log.levels.ERROR)
    return nil
  end
  f:write(md)
  f:close()

  -- clear the auto-save session now that review is submitted
  os.remove(storage.data_dir() .. "/session.json")

  return outpath
end

-- Yank to clipboard without writing
function M.yank()
  local md = M.build_markdown()
  vim.fn.setreg("+", md)
  vim.fn.setreg('"', md)
  vim.notify(
    "ceibo: review copied to clipboard (" .. require("ceibo.comments").count() .. " comments)",
    vim.log.levels.INFO
  )
end

return M
