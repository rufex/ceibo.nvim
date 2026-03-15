# Ceibo

A Neovim plugin for reviewing git diffs and generating structured code review comments to feed back into AI coding assistants (Claude Code, OpenCode, etc.).

## What it does

- Shows a navigable git diff (all files, including new and deleted)
- Lets you annotate individual lines or visual ranges with typed comments
- Lets you also annotate files or the whole review with general comments
- Exports a structured Markdown review — yank it to clipboard with `y`

## Workflow

```
╔══════════════════╗         ╔══════════════════════════════╗
║  AI assistant    ║         ║     Neovim (ceibo.nvim)      ║
╠══════════════════╣         ╠══════════════════════════════╣
║  1. makes changes║         ║  2. you run :Ceibo           ║
║                  ║         ║  ┌──────────┬──────────────┐ ║
║                  ║         ║  │ files    │  diff view   │ ║
║                  ║         ║  │ ✓ foo.lua│  42 + code   │ ║
║                  ║         ║  │   bar.lua│     ▶ [ISSUE]│ ║
║                  ║         ║  └──────────┴──────────────┘ ║
║                  ║         ║  3. annotate, comment        ║
║  5. paste review ║◀──────y─║  4. press y to  yanks review ║
║     fix issues   ║         ║     to clipboard             ║
╚══════════════════╝         ╚══════════════════════════════╝
```

1. Run your AI assistant (Claude Code, OpenCode, etc.) and let it make changes
2. Open Neovim and run `:Ceibo`
3. Navigate the diff, add comments, mark files reviewed
4. Press `y` to yank the full review Markdown to clipboard
5. Go back to the AI assistant and paste — ask it to address all ISSUE and SUGGESTION comments

## Requirements

- Neovim 0.10+
- Git

## Installation

**lazy.nvim**:

```lua
return {
  "rufex/ceibo.nvim",
}
```

**vim-pack**:

```lua
vim.pack.add({"https://github.com/rufex/ceibo.nvim"})
require("ceibo").setup({})
```

## Usage

```
:Ceibo                 diff vs HEAD (default)
:Ceibo diff=HEAD       same, explicit
:Ceibo diff=main       diff vs any git ref (branch, tag, SHA, HEAD~3 …)
:Ceibo diff=staged     staged changes only
:Ceibo view=unified    switch to unified diff view
:Ceibo view=split      switch to side-by-side split view
:Ceibo list            show all comments in a floating list
```

## Configuration

```lua
require("ceibo").setup({
  -- set false to define all keymaps yourself (see Custom keymaps below)
  set_default_keymaps = true,

  -- default diff view: "unified" | "split"
  view_mode = "unified",

  -- git ref to diff against by default (nil = HEAD)
  base_ref = nil,

  -- comment types shown in the prompt and included in the export header
  -- each entry requires `name` and `description`; `hl` is optional (defaults to "CeiboComment<Name>")
  types = {
    { name = "ISSUE",      description = "bug or problem — fix it"                     },
    { name = "SUGGESTION", description = "improvement to discuss — ask before changing" },
    { name = "NOTE",       description = "informational — no action needed"             },
    { name = "PRAISE",     description = "positive feedback — no action needed"         },
  },

  layout = {
    file_list_width = 30,
  },

  -- define you own keymaps
  keymaps = {
    add_comment    = "c",
    delete_comment = "d",
    yank           = "y",
    submit         = "s",
    next_hunk      = "]h",
    prev_hunk      = "[h",
    next_file      = "]f",
    prev_file      = "[f",
    mark_reviewed  = "r",
    close          = "q",
  },

  -- highlight groups for diff and comments (linked to existing groups by default)
  highlights = {
    CeiboAdd               = { link = "DiffAdd"         },
    CeiboDel               = { link = "DiffDelete"      },
    CeiboHdr               = { link = "DiffText"        },
    CeiboFileHeader        = { link = "Title"            },
    CeiboCommentIssue      = { link = "DiagnosticError" },
    CeiboCommentSuggestion = { link = "DiagnosticWarn"  },
    CeiboCommentNote       = { link = "DiagnosticInfo"  },
    CeiboCommentPraise     = { link = "DiagnosticOk"    },
    CeiboCommentText       = { link = "Comment"         },
    CeiboReviewed          = { link = "DiagnosticOk"    },
    CeiboRangeHL           = { link = "Visual"          },
    CeiboCollapsed         = { link = "Comment"         },
    CeiboDir               = { link = "Directory"       },
  },
})
```

## Session persistence

Comments and reviewed flags are auto-saved to
`stdpath("data")/ceibo/<repo>/session.json` after every change. Reopening
`:Ceibo` restores them automatically. The session file is cleared on submit.

## Acknowledgments

ceibo.nvim is heavily inspired by [tuicr](https://github.com/agavra/tuicr) by [@agavra](https://github.com/agavra) — a terminal UI for the same AI-assisted code review workflow. Most features and behaviour here replicate what tuicr implemented in the first place. If you are not tied to Neovim, try tuicr first: it is more polished and has more features.

