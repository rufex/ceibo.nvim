-- Parses unified diff output into structured tables.
-- Returns a list of file entries:
--   { old_path, new_path, status, hunks = { { header, lines = { {type, content, old_ln, new_ln} } } } }
-- type is one of: "add", "del", "ctx", "hdr"

local M = {}

-- Run a command and return stdout, or nil + err.
-- Note: `git diff --no-index` returns exit code 1 when files differ (not an error);
-- we treat any non-zero exit as an error only when stdout is empty.
local function run(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 and (result.stdout == nil or result.stdout == "") then
    return nil, result.stderr ~= "" and result.stderr or ("exit code " .. result.code)
  end
  return result.stdout or "", nil
end

-- Get raw unified diff text (tracked changes + untracked new files)
function M.get_raw_diff(ref, staged)
  local session = require("ceibo.session")
  local ctx = session.context_lines or 3
  local cmd = { "git", "diff", "--no-color", "-U" .. ctx }
  if staged then
    table.insert(cmd, "--staged")
  else
    table.insert(cmd, ref or "HEAD")
  end
  local out, err = run(cmd)
  if not out then
    return nil, err or "git diff failed"
  end

  -- append diffs for untracked (never-staged) new files
  if not staged then
    local ls = vim.system({ "git", "ls-files", "--others", "--exclude-standard" }, { text = true }):wait()
    for path in (ls.stdout or ""):gmatch("[^\n]+") do
      -- exit code 1 is normal when files differ; stdout still has the diff
      local r = vim
        .system({ "git", "diff", "--no-color", "--no-index", "--", "/dev/null", path }, { text = true })
        :wait()
      if r.stdout and r.stdout ~= "" then
        out = out .. r.stdout
      end
    end
  end

  return out, nil
end

-- Parse unified diff text into file table
function M.parse(diff_text)
  local files = {}
  local current_file = nil
  local current_hunk = nil
  local old_ln, new_ln = 0, 0

  for line in (diff_text .. "\n"):gmatch("([^\n]*)\n") do
    -- New file header
    if line:match("^diff %-%-git ") then
      current_file = {
        old_path = "",
        new_path = "",
        status = "M",
        hunks = {},
        is_binary = false,
      }
      table.insert(files, current_file)
      current_hunk = nil
    elseif current_file and line:match("^new file mode") then
      current_file.status = "A"
    elseif current_file and line:match("^deleted file mode") then
      current_file.status = "D"
    elseif current_file and line:match("^rename from ") then
      current_file.old_path = line:match("^rename from (.+)$") or ""
      current_file.status = "R"
    elseif current_file and line:match("^rename to ") then
      current_file.new_path = line:match("^rename to (.+)$") or ""
    elseif current_file and line:match("^Binary files") then
      current_file.is_binary = true
    elseif current_file and line:match("^%-%-%-") then
      local p = line:match("^%-%-%- a/(.+)$") or line:match("^%-%-%- (.+)$")
      if p and p ~= "/dev/null" then
        current_file.old_path = p
      end
      if line:match("/dev/null") then
        current_file.status = "A"
      end
    elseif current_file and line:match("^%+%+%+") then
      local p = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
      if p and p ~= "/dev/null" then
        current_file.new_path = p
      end
      if line:match("/dev/null") then
        current_file.status = "D"
      end
      -- fallback: derive new_path from old_path if not set
      if current_file.new_path == "" and current_file.old_path ~= "" then
        current_file.new_path = current_file.old_path
      end
      if current_file.old_path == "" and current_file.new_path ~= "" then
        current_file.old_path = current_file.new_path
      end
    elseif current_file and line:match("^@@") then
      -- @@ -old_start[,old_count] +new_start[,new_count] @@ [context]
      -- The ,count part is optional; the pattern handles both forms.
      local os, _, ns, _ = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      old_ln = tonumber(os) or 1
      new_ln = tonumber(ns) or 1
      current_hunk = {
        header = line,
        old_start = old_ln,
        new_start = new_ln,
        lines = {},
      }
      table.insert(current_file.hunks, current_hunk)
      table.insert(current_hunk.lines, { type = "hdr", content = line, old_ln = nil, new_ln = nil })
    elseif current_hunk then
      if line:sub(1, 1) == "+" then
        table.insert(current_hunk.lines, { type = "add", content = line:sub(2), old_ln = nil, new_ln = new_ln })
        new_ln = new_ln + 1
      elseif line:sub(1, 1) == "-" then
        table.insert(current_hunk.lines, { type = "del", content = line:sub(2), old_ln = old_ln, new_ln = nil })
        old_ln = old_ln + 1
      elseif line:sub(1, 1) == " " or line == "" then
        table.insert(current_hunk.lines, { type = "ctx", content = line:sub(2), old_ln = old_ln, new_ln = new_ln })
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      end
    end
  end

  -- ensure paths are populated from diff header if missing
  for _, f in ipairs(files) do
    if f.new_path == "" then
      f.new_path = f.old_path
    end
    if f.old_path == "" then
      f.old_path = f.new_path
    end
  end

  return files
end

-- Build display lines from parsed files.
-- Returns lines (list of strings) and a line_map (list of {file_idx, hunk_idx, line_idx, new_ln})
-- opts.collapsed: { [file_path] = true } — files whose hunks are hidden
function M.build_display(files, opts)
  opts = opts or {}
  local collapsed = opts.collapsed or {}
  local lines = {}
  local line_map = {} -- index = display line number (1-based)

  local function push(text, meta)
    table.insert(lines, text)
    table.insert(line_map, meta or {})
  end

  for fi, file in ipairs(files) do
    local path = file.new_path ~= "" and file.new_path or file.old_path
    push("", {})
    push(string.rep("─", 60), {})
    push("  " .. path .. "  [" .. file.status .. "]", { file_idx = fi, is_file_header = true })
    push(string.rep("─", 60), {})

    if collapsed[path] then
      -- emit a single placeholder instead of hunk lines
      push("  [≡ collapsed — press r to expand]", { file_idx = fi, is_collapsed_placeholder = true })
    else
      if file.is_binary then
        push("  [binary file — diff not shown]", { file_idx = fi })
      end

      for hi, hunk in ipairs(file.hunks) do
        for li, dl in ipairs(hunk.lines) do
          local prefix
          if dl.type == "hdr" then
            prefix = "    "
          elseif dl.type == "add" then
            prefix = string.format("%4s + ", dl.new_ln and tostring(dl.new_ln) or "")
          elseif dl.type == "del" then
            prefix = string.format("%4s - ", dl.old_ln and tostring(dl.old_ln) or "")
          else
            prefix = string.format("%4s   ", dl.new_ln and tostring(dl.new_ln) or "")
          end
          push(prefix .. (dl.content or ""), {
            file_idx = fi,
            hunk_idx = hi,
            line_idx = li,
            new_ln = dl.new_ln,
            old_ln = dl.old_ln,
            line_type = dl.type,
          })
        end
        push("", {})
      end
    end
  end

  return lines, line_map
end

-- Build display lines for the split view OLD (left) buffer.
-- Shows: del lines + ctx lines. add lines are replaced by blank padding so
-- both buffers stay in sync line-for-line (scrollbind works correctly).
-- opts.collapsed: { [file_path] = true }
function M.build_old_lines(files, opts)
  opts = opts or {}
  local collapsed = opts.collapsed or {}
  local lines = {}

  local function push(text)
    table.insert(lines, text)
  end

  for _, file in ipairs(files) do
    local path = file.new_path ~= "" and file.new_path or file.old_path
    push("")
    push(string.rep("─", 60))
    push("  " .. (file.old_path ~= "" and file.old_path or path) .. "  [" .. file.status .. "]")
    push(string.rep("─", 60))

    if collapsed[path] then
      push("  [≡ collapsed]")
    else
      if file.is_binary then
        push("  [binary]")
      end
      for _, hunk in ipairs(file.hunks) do
        -- Count dels and adds per run to emit matching blank padding
        local i = 1
        local hl = hunk.lines
        while i <= #hl do
          local dl = hl[i]
          if dl.type == "hdr" then
            push("    " .. (dl.content or ""))
            i = i + 1
          elseif dl.type == "ctx" then
            push(string.format("%4s   ", dl.old_ln and tostring(dl.old_ln) or "") .. (dl.content or ""))
            i = i + 1
          else
            local dels, adds = {}, {}
            while i <= #hl and hl[i].type == "del" do
              table.insert(dels, hl[i])
              i = i + 1
            end
            while i <= #hl and hl[i].type == "add" do
              table.insert(adds, hl[i])
              i = i + 1
            end
            local n = math.max(#dels, #adds)
            for j = 1, n do
              local d = dels[j]
              if d then
                push(string.format("%4s - ", tostring(d.old_ln or "")) .. (d.content or ""))
              else
                push("") -- blank padding to stay in sync with new buffer
              end
            end
          end
        end
        push("")
      end
    end
  end

  return lines
end

-- Build display lines for the split view NEW (right) buffer.
-- Shows: add lines + ctx lines. del lines are replaced by blank padding.
function M.build_new_lines(files, opts)
  opts = opts or {}
  local collapsed = opts.collapsed or {}
  local lines = {}

  local function push(text)
    table.insert(lines, text)
  end

  for _, file in ipairs(files) do
    local path = file.new_path ~= "" and file.new_path or file.old_path
    push("")
    push(string.rep("─", 60))
    push("  " .. path .. "  [" .. file.status .. "]")
    push(string.rep("─", 60))

    if collapsed[path] then
      push("  [≡ collapsed]")
    else
      if file.is_binary then
        push("  [binary]")
      end
      for _, hunk in ipairs(file.hunks) do
        local i = 1
        local hl = hunk.lines
        while i <= #hl do
          local dl = hl[i]
          if dl.type == "hdr" then
            push("    " .. (dl.content or ""))
            i = i + 1
          elseif dl.type == "ctx" then
            push(string.format("%4s   ", dl.new_ln and tostring(dl.new_ln) or "") .. (dl.content or ""))
            i = i + 1
          else
            local dels, adds = {}, {}
            while i <= #hl and hl[i].type == "del" do
              table.insert(dels, hl[i])
              i = i + 1
            end
            while i <= #hl and hl[i].type == "add" do
              table.insert(adds, hl[i])
              i = i + 1
            end
            local n = math.max(#dels, #adds)
            for j = 1, n do
              local a = adds[j]
              if a then
                push(string.format("%4s + ", tostring(a.new_ln or "")) .. (a.content or ""))
              else
                push("") -- blank padding to stay in sync with old buffer
              end
            end
          end
        end
        push("")
      end
    end
  end

  return lines
end

-- Count added/removed lines for a parsed file entry
function M.count_changes(file)
  local added, removed = 0, 0
  for _, hunk in ipairs(file.hunks) do
    for _, dl in ipairs(hunk.lines) do
      if dl.type == "add" then
        added = added + 1
      elseif dl.type == "del" then
        removed = removed + 1
      end
    end
  end
  return added, removed
end

return M
