-- Left panel: file tree with status indicators.

local M = {}

local ns = vim.api.nvim_create_namespace("ceibo_files_hl")

function M.create_buf()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "ceibo_files"
  return bufnr
end

-- ── tree builder ───────────────────────────────────────────────────────────

-- Split a path into segments: "lua/ceibo/ui/foo.lua" → {"lua","ceibo","ui","foo.lua"}
local function split_path(path)
  local segs = {}
  for s in path:gmatch("[^/]+") do
    table.insert(segs, s)
  end
  return segs
end

-- Insert a file into the trie.
-- Each trie node: { children = { [name] = node }, fi = nil|number, name = string }
local function trie_insert(root, segments, fi)
  local node = root
  for _, seg in ipairs(segments) do
    if not node.children[seg] then
      node.children[seg] = { children = {}, fi = nil, name = seg }
    end
    node = node.children[seg]
  end
  node.fi = fi
end

-- Merge single-child directory chains: if a dir node has exactly one child
-- and that child is also a dir (fi == nil), merge their names.
-- Returns the (possibly merged) node; mutates in place.
local function merge_chains(node)
  -- recurse children first
  for name, child in pairs(node.children) do
    node.children[name] = merge_chains(child)
  end

  -- count children
  local count = 0
  local only_name, only_child
  for name, child in pairs(node.children) do
    count = count + 1
    only_name = name
    only_child = child
  end

  -- merge: this node is a dir (fi==nil, not root), has exactly one child,
  -- and that child is also a dir
  if node.fi == nil and node.name and count == 1 and only_child.fi == nil then
    only_child.name = node.name .. "/" .. only_child.name
    -- hoist only_child's children up (the merged node replaces this node)
    return only_child
  end

  return node
end

-- Depth-first walk of trie, emitting a flat list of render nodes.
-- Each node: { type="dir"|"file", label=string, fi=nil|number, depth=number }
local function walk(trie_node, depth, out)
  -- collect and sort children: dirs first, then files, both alphabetically
  local dirs = {}
  local files = {}
  for _, child in pairs(trie_node.children) do
    if child.fi == nil then
      table.insert(dirs, child)
    else
      table.insert(files, child)
    end
  end
  table.sort(dirs, function(a, b)
    return a.name < b.name
  end)
  table.sort(files, function(a, b)
    return a.name < b.name
  end)

  for _, child in ipairs(dirs) do
    table.insert(out, { type = "dir", label = child.name .. "/", depth = depth })
    walk(child, depth + 1, out)
  end
  for _, child in ipairs(files) do
    table.insert(out, { type = "file", label = child.name, fi = child.fi, depth = depth })
  end
end

-- Build a flat ordered list of render nodes from session.files.
local function build_tree(files)
  local root = { children = {}, fi = nil, name = nil }

  for fi, file in ipairs(files) do
    local path = file.new_path ~= "" and file.new_path or file.old_path
    local segs = split_path(path)
    trie_insert(root, segs, fi)
  end

  root = merge_chains(root)

  local out = {}
  walk(root, 0, out)
  return out
end

-- ── render ─────────────────────────────────────────────────────────────────

function M.render(bufnr)
  local session = require("ceibo.session")
  local comments = require("ceibo.comments")
  local diff = require("ceibo.diff")
  local store = comments.get_all()

  -- dynamic panel width
  local fl_win = vim.fn.bufwinid(bufnr)
  local win_width = (fl_win ~= -1) and vim.api.nvim_win_get_width(fl_win) or 40

  local lines = {}
  local file_lines = {} -- display line index → file_idx (written to session.file_lines)
  local hl_specs = {} -- { lnum(0-based), col_start, col_end, hl_group }

  local function push(text, fi, specs)
    table.insert(lines, text)
    table.insert(file_lines, fi)
    local lnum = #lines - 1
    for _, s in ipairs(specs or {}) do
      table.insert(hl_specs, { lnum = lnum, cs = s[1], ce = s[2], hl = s[3] })
    end
  end

  push(" Files", nil, { { 0, -1, "CeiboFileHeader" } })
  push(string.rep("─", win_width), nil, {})

  local tree = build_tree(session.files)

  for _, node in ipairs(tree) do
    local indent = string.rep("  ", node.depth)

    if node.type == "dir" then
      -- directory row: full line highlighted as CeiboDir
      local line = indent .. node.label
      push(line, nil, { { 0, -1, "CeiboDir" } })
    else
      -- file row
      local fi = node.fi
      local file = session.files[fi]
      local path = file.new_path ~= "" and file.new_path or file.old_path
      local added, removed = diff.count_changes(file)
      local reviewed = session.is_reviewed(path)

      local nc = 0
      if store[path] then
        for _ in pairs(store[path]) do
          nc = nc + 1
        end
      end

      local rev_mark = reviewed and "✓ " or "  "
      local status = ({ A = "A", D = "D", R = "R" })[file.status] or "M"
      local counts = string.format(" +%d -%d", added, removed)
      local badge = nc > 0 and (" [" .. nc .. "]") or ""

      local line = indent .. rev_mark .. status .. " " .. node.label .. counts .. badge
      local specs = {}

      local base = #indent -- byte offset where content starts after indent

      -- ✓ highlight
      if reviewed then
        table.insert(specs, { base, base + #rev_mark, "CeiboReviewed" })
      end

      -- status letter
      local status_hl = file.status == "A" and "CeiboAdd"
        or file.status == "D" and "CeiboDel"
        or file.status == "R" and "CeiboHdr"
        or "Normal"
      local s_cs = base + #rev_mark
      table.insert(specs, { s_cs, s_cs + 1, status_hl })

      -- +N -M
      local counts_start = base + #rev_mark + 1 + 1 + #node.label -- indent+rev+status+" "+label
      local plus_end = counts_start + #string.format(" +%d", added)
      table.insert(specs, { counts_start, plus_end, "CeiboAdd" })
      table.insert(specs, { plus_end, counts_start + #counts, "CeiboDel" })

      -- comment badge
      if nc > 0 then
        local badge_start = counts_start + #counts
        table.insert(specs, { badge_start, badge_start + #badge, "CeiboCommentNote" })
      end

      push(line, fi, specs)
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, s in ipairs(hl_specs) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, s.hl, s.lnum, s.cs, s.ce)
  end

  -- Keep session in sync so keymaps always have the current mapping
  session.file_lines = file_lines

  return file_lines
end

-- ── navigation ─────────────────────────────────────────────────────────────

-- Jump the diff view to the file at the given panel line
function M.jump_to_file(panel_line, file_lines)
  local fi = file_lines[panel_line]
  if not fi then
    return
  end

  local session = require("ceibo.session")
  for di, meta in ipairs(session.line_map) do
    if meta.file_idx == fi and meta.is_file_header then
      local diff_win = M.get_diff_win()
      if diff_win then
        vim.api.nvim_set_current_win(diff_win)
        vim.api.nvim_win_set_cursor(diff_win, { di, 0 })
      end
      return
    end
  end
end

function M.get_diff_win()
  local session = require("ceibo.session")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == session.bufnr then
      return win
    end
  end
  return nil
end

return M
