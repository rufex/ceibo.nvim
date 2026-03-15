-- ceibo.nvim — git diff reviewer for Claude Code
-- Entry point: require("ceibo").setup(opts)

local M = {}

function M.setup(opts)
  require("ceibo.config").setup(opts)
  require("ceibo.comments").setup_highlights()

  -- re-apply when colorscheme changes so linked groups stay correct
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CeiboHighlights", { clear = true }),
    callback = function()
      require("ceibo.comments").setup_highlights()
    end,
  })

  vim.api.nvim_create_user_command("Ceibo", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args)

    if arg == "" or arg == "diff=HEAD" then
      M.open({})
    elseif arg == "diff=staged" then
      M.open({ staged = true })
    elseif arg:match("^diff=(.+)$") then
      local ref = arg:match("^diff=(.+)$")
      M.open({ ref = ref })
    elseif arg == "view=unified" then
      M.open({ view_mode = "unified" })
    elseif arg == "view=split" then
      M.open({ view_mode = "split" })
    elseif arg == "list" then
      require("ceibo.ui.comment_list").open()
    else
      vim.notify(
        "ceibo: unknown argument '"
          .. arg
          .. "'\n"
          .. "Usage: :Ceibo [diff=<ref>|diff=staged|view=unified|view=split|list]",
        vim.log.levels.ERROR
      )
    end
  end, {
    nargs = "?",
    complete = function()
      return { "diff=HEAD", "diff=staged", "view=unified", "view=split", "list" }
    end,
    desc = "ceibo: open diff review or list comments",
  })
end

function M.open(opts)
  opts = opts or {}

  local cfg = require("ceibo.config").options
  local session = require("ceibo.session")
  local diff = require("ceibo.diff")
  local layout = require("ceibo.ui.layout")

  session.reset()

  -- resolve the git dir once (handles worktrees where .git is a file, not a dir)
  local gd = vim.system({ "git", "rev-parse", "--git-dir" }, { text = true }):wait()
  if gd.code == 0 then
    local p = vim.trim(gd.stdout)
    -- make absolute
    if not p:match("^/") then
      p = vim.fn.getcwd() .. "/" .. p
    end
    session.git_dir = p
  end

  -- explicit opts.ref wins, then config base_ref, then nil (→ HEAD in diff.lua)
  session.ref = opts.ref or cfg.base_ref
  session.staged = opts.staged or false
  -- explicit opts.view_mode overrides the config default
  if opts.view_mode then
    session.view_mode = opts.view_mode
  end

  -- fetch raw diff
  local raw, err = diff.get_raw_diff(session.ref, session.staged)
  if not raw then
    vim.notify("ceibo: " .. (err or "git diff failed"), vim.log.levels.ERROR)
    return
  end

  if raw == "" then
    vim.notify("ceibo: no changes detected", vim.log.levels.INFO)
    return
  end

  -- parse
  session.files = diff.parse(raw)
  if #session.files == 0 then
    vim.notify("ceibo: no changed files found in diff", vim.log.levels.WARN)
    return
  end

  -- restore comments + reviewed flags from previous session if any
  local comments = require("ceibo.comments")
  comments.load()
  local restored = comments.count()
  if restored > 0 then
    vim.notify("ceibo: restored " .. restored .. " comment(s) from previous session", vim.log.levels.INFO)
  end

  -- build display (after load so collapsed state is restored before building)
  session.lines, session.line_map = diff.build_display(session.files, { collapsed = session.collapsed })

  -- open UI
  layout.open(opts)
end

return M
