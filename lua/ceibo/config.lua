local M = {}

M.defaults = {
  -- Comment types. Each entry requires `name` and `description`.
  -- `hl` is optional; defaults to "CeiboComment<Name>" (e.g. CeiboCommentIssue).
  -- The description is included in the export header so the AI knows what each type means.
  types = {
    { name = "ISSUE", description = "bug or problem — fix it" },
    { name = "SUGGESTION", description = "improvement to discuss — ask before changing" },
    { name = "NOTE", description = "informational — no action needed" },
    { name = "PRAISE", description = "positive feedback — no action needed" },
  },
  -- set to false to skip all default keymaps (define your own in config)
  set_default_keymaps = true,
  -- default diff view mode: "unified" | "split"
  view_mode = "unified",
  -- git ref to diff against (nil = working tree vs HEAD)
  base_ref = nil,
  -- window layout
  layout = {
    file_list_width = 30,
    position = "left", -- reserved for future use; not yet implemented
  },
  -- keymaps (set to false to disable)
  keymaps = {
    add_comment = "c",
    delete_comment = "d",
    yank = "y",
    submit = "s",
    next_hunk = "]h",
    prev_hunk = "[h",
    next_file = "]f",
    prev_file = "[f",
    mark_reviewed = "r",
    close = "q",
  },
  -- Highlight groups. Each entry is passed directly to vim.api.nvim_set_hl().
  -- Use `link` to inherit from an existing group, or set fg/bg/bold/italic etc.
  -- Defaults link to standard Neovim diff/ui groups so any colorscheme works.
  highlights = {
    -- diff lines
    CeiboAdd = { link = "DiffAdd" },
    CeiboDel = { link = "DiffDelete" },
    CeiboHdr = { link = "DiffText" },
    -- file header bar
    CeiboFileHeader = { link = "Title" },
    -- inline comment labels  ▶ [TYPE]
    CeiboCommentIssue = { link = "DiagnosticError" },
    CeiboCommentSuggestion = { link = "DiagnosticWarn" },
    CeiboCommentNote = { link = "DiagnosticInfo" },
    CeiboCommentPraise = { link = "DiagnosticOk" },
    -- comment body text
    CeiboCommentText = { link = "Comment" },
    -- reviewed ✓ marker in file list
    CeiboReviewed = { link = "DiagnosticOk" },
    -- background highlight for visual range comments
    CeiboRangeHL = { link = "Visual" },
    -- collapsed file placeholder line
    CeiboCollapsed = { link = "Comment" },
    -- directory rows in the file tree
    CeiboDir = { link = "Directory" },
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Returns the resolved types list, filling in `hl` from the name when not set.
-- e.g. { name = "ISSUE", description = "...", hl = "CeiboCommentIssue" }
function M.get_types()
  local types = M.options.types or M.defaults.types
  local resolved = {}
  for _, t in ipairs(types) do
    local name_title = t.name:sub(1, 1) .. t.name:sub(2):lower()
    resolved[#resolved + 1] = {
      name = t.name,
      description = t.description or "",
      hl = t.hl or ("CeiboComment" .. name_title),
    }
  end
  return resolved
end

return M
