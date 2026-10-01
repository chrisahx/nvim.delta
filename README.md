# delta.nvim

Interactive Git review layered onto **your normal editable Neovim buffers**.
The repository is named `delta.nvim`; the Lua namespace and commands are `review`.
This is not a side-by-side diff viewer, a copied source buffer, or a read-only
review application.

- Full source files, with ordinary LSP, Treesitter, diagnostics, completion, undo,
  formatting, and filetype plugins.
- Added lines (`+`) and modified lines (`~`) highlighted in place.
- Deleted text displayed as **virtual lines**, never inserted into the file.
- Changed-files sidebar, wrapping file/hunk navigation, explicit reviewed state,
  and progress.
- Staged **and** unstaged changes, plus nonignored untracked files.
- Asynchronous Git processes, lazy base-content loading, refresh on save.
- No runtime dependencies besides Git and Neovim.

> Screenshot placeholder: full editable source buffer with inline deleted lines
> and a changed-files sidebar.

## Requirements

- Neovim **0.10+**
- `git` on `$PATH`
- A Git working tree with an existing base commit. Merge-base mode also requires
  a valid `HEAD` and shared history with the base.

## Installation

Replace `USER` with the repository owner when publishing this repository.

### lazy.nvim

```lua
{
  "USER/delta.nvim",
  cmd = {
    "Review", "ReviewClose", "ReviewRefresh", "ReviewToggleReviewed",
    "ReviewMarkReviewed", "ReviewMarkUnreviewed",
    "ReviewNextFile", "ReviewPrevFile", "ReviewNextHunk", "ReviewPrevHunk",
  },
  config = function()
    require("review").setup()
  end,
}
```

### Native packages

Clone into `~/.local/share/nvim/site/pack/plugins/start/delta.nvim` (or the
corresponding directory under your `stdpath("data")`). Commands work without
calling `setup()`. For configuration, add this to `init.lua`:

```lua
require("review").setup({ base = "main" })
```

For local development, add this repository to `runtimepath` before calling
`setup()`.

## Walkthrough

```text
nvim .
:Review origin/main
```

The sidebar lists changed files. Use `j`/`k` and `<CR>` to open one. The source
window displays the actual file, with additions/modifications highlighted and
old deleted text inline. Deletions have a `- ` prefix; they have no real line
number and cannot be edited.

```text
]h    next change         [h    previous change
]f    next changed file   [f    previous changed file
```

Edit normally, then `:w`. Git file discovery and the overlay refresh
automatically. `:ReviewRefresh` also refreshes without saving: already-listed
loaded files are compared against their current buffer contents, including
unsaved edits. Newly changed files are discovered from the **filesystem**, so
save a previously unchanged file to include it in the review.

Use `<leader>rr` in the source or `r` in the sidebar to toggle reviewed state.
Opening a file never marks it reviewed. The sidebar shows `N / total reviewed`.
Review marks are invalidated when refresh detects changed file contents or
filesystem metadata; they are not approval of future edits.

`:ReviewClose` (or `q` in the sidebar) ends the session, clears overlays and review
mappings, and leaves your real source buffers and edits intact. Closing/wiping
the sidebar also ends the session.

## Base selection and working-tree semantics

`:Review <base>` overrides `setup().base`. A base can be a local branch, remote
tracking branch, tag, or arbitrary commit/revision expression. Without an explicit
or configured base, candidates are tried in this order:

1. `origin/main`
2. `main`
3. `origin/master`
4. `master`

By default, `use_merge_base = true` resolves the comparison commit to
`merge-base(base, HEAD)`, suitable for reviewing a branch/PR. Set it to `false`
to compare directly against the resolved base commit.

The comparison commit is pinned for the session. Refresh does **not** re-resolve
moving refs; restart `:Review` after switching branches or updating the base.
The target is the current working tree, not the index: changes already committed
on the branch, staged changes, unstaged changes, and untracked files are visible.
Ignored untracked files are excluded. Nothing stages, commits, checks out, or
writes source files on your behalf.

A refresh discovers all filesystem changes in the repository, removes files that
now match the base, updates progress, and reapplies overlays to loaded review
buffers. If the current file becomes unchanged, its buffer stays open and editable;
the sidebar selects another entry without stealing focus. File navigation then
continues through the remaining entries. Unsaved previously-listed buffers are
retained when their contents still differ even if the filesystem matches the base.

## Commands

| Command | Action |
| --- | --- |
| `:Review [base]` | Start/replace the repository's review session |
| `:ReviewClose` | End review and clean up |
| `:ReviewRefresh` | Refresh discovery and loaded-file overlays |
| `:ReviewToggleReviewed` | Toggle the current/selected file |
| `:ReviewMarkReviewed` | Mark the current/selected file reviewed |
| `:ReviewMarkUnreviewed` | Mark it unreviewed |
| `:ReviewNextFile`, `:ReviewPrevFile` | Open next/previous changed file, wrapping |
| `:ReviewNextHunk`, `:ReviewPrevHunk` | Jump between hunk anchors, wrapping |

Hunk navigation uses real source line numbers. A pure deletion anchors to the
following real line, or the last line for an EOF deletion. Deleted virtual text
is not a cursor destination. If there are no hunks/files, navigation is a no-op.

## Mappings

Source mappings are **buffer-local** and only installed on files in the review.
Existing local mappings are restored on close (unless you replaced the mapping
while reviewing). Global mappings are never modified. Set any mapping to `false`
or `""` to disable it.

| Source mapping | Action |
| --- | --- |
| `]h`, `[h` | Next/previous hunk |
| `]f`, `[f` | Next/previous file |
| `<leader>rr` | Toggle reviewed |

| Sidebar mapping | Action |
| --- | --- |
| `<CR>` | Open selected file |
| `j`, `k` | Ordinary cursor navigation |
| `]f`, `[f` | Next/previous file |
| `r` | Toggle selected file reviewed |
| `R` | Refresh |
| `q` | Close session |

## Configuration (all defaults)

```lua
require("review").setup({
  base = nil,                    -- autodetect, or a revision string
  use_merge_base = true,         -- false compares directly to base
  sidebar = {
    width = 35,                  -- columns
    position = "left",           -- "left" or "right"
  },
  mappings = {
    next_hunk = "]h",
    prev_hunk = "[h",
    next_file = "]f",
    prev_file = "[f",
    toggle_reviewed = "<leader>rr",
  },
  sidebar_mappings = {
    open = "<CR>",
    toggle_reviewed = "r",
    refresh = "R",
    close = "q",
  },
  refresh = {
    on_write = true,             -- refresh on any write inside the repository
  },
})
```

No Git command runs on every keystroke. While typing, existing extmarks follow
Neovim's normal extmark movement; their hunk metadata may be stale until save or
manual refresh. Correct refresh is preferred over offset bookkeeping.

### Lua API

```lua
local review = require("review")
review.start("main") -- asynchronous
review.refresh()     -- asynchronous
review.close()
review.next_file()
review.prev_file()
review.next_hunk()
review.prev_hunk()
review.toggle_reviewed()
review.mark_reviewed()
review.mark_unreviewed()
local progress = review.progress() -- { reviewed = 4, total = 11 }
local session = review.get_session() -- nil when inactive; inspect, do not mutate
```

Use these functions in your own mappings. `get_session()` exposes repository root,
base name, resolved `commit`, files, selection index, buffer ownership, generation,
and decoration namespace. File records contain status, reviewed state, cached
base text, and structured parsed hunks; hunks are populated lazily on opening or
refreshing loaded files. There is one active session per Neovim instance.

### Highlights

Default links are overrideable with `nvim_set_hl` / colorscheme definitions:

| Group | Default link |
| --- | --- |
| `ReviewAdd`, `ReviewAddSign` | `DiffAdd` |
| `ReviewDelete`, `ReviewDeleteSign`, `ReviewVirtualDelete` | `DiffDelete` |
| `ReviewChange`, `ReviewChangeSign` | `DiffChange` |

Definitions use `default = true` and are reapplied on `ColorScheme`.

## Architecture

- `git.lua`: argument-array `vim.system()` calls, root/base/merge-base resolution,
  NUL-delimited file discovery, conflict checks, lazy base content retrieval.
- `diff.lua`: unified hunk parser and `vim.diff()` comparison of base text to the
  real buffer; zero-context hunks, omitted/zero counts, no-newline markers.
- `session.lua`: explicitly owned session state, async invalidation tokens,
  buffer lifecycle, refresh, mapping restoration, navigation and progress.
- `decorations.lua`: one namespace, extmark line highlights/signs, virtual deletions.
- `sidebar.lua`: scratch sidebar only; never a replacement source buffer.
- `config.lua`, `commands.lua`, `init.lua`: configuration, commands, public API.

Base text comes from Git, but hunks are computed against the actual editable
buffer using Neovim's diff engine. This supports unsaved edits and avoids
external diff drivers/textconv and manual offset maintenance.

## Limitations / deliberate v1 choices

- Fully deleted files use a **read-only scratch buffer containing the base file**,
  highlighted as deleted. This exception is explicit (`review-deleted://…` buffer
  name); existing regular files always use their real buffers.
- Renames appear as deletion + addition (`--no-renames`), not `R` entries.
- Binary content has no inline overlay. Gitlinks/submodule directories and symlinks
  are listed but cannot be opened for inline review; a warning explains this.
- Unresolved merge conflicts are rejected. No staging, hunk revert, or conflict UI.
- Review state is in-memory only. No persistent state, automatic approval,
  branch-change watcher, filesystem watcher, or typing-time diff calculation.
- Text comparisons use Neovim's decoded buffer text; unusual encodings, Git
  clean/smudge filters, and custom attributes may not exactly reproduce Git's
  byte-level diff. Review ordinary text files; binary/encoded workflows need care.
- Very large text files or deletions can take time to diff/render on the main
  thread. Git discovery/content retrieval is asynchronous and full diffs are lazy.
- Mapping configuration is intended to be set before starting a session.

## Testing

Run from the repository root:

```sh
nvim --headless -u NONE -l tests/run.lua
```

No test framework dependency. Tests exercise parser/zero-count/no-newline cases,
virtual deletion placement without source mutation, and temporary Git repositories:
real buffers, staged/unstaged/untracked/deleted files, unusual path characters,
manual/automatic refresh, progress, navigation, mapping restoration and cancellation.

For a manual smoke test, change/add/delete files in a disposable Git repository,
run `:Review main`, and confirm that deleted lines have no real line numbers.
Edit an actual source line, save, check the updated overlay, mark it reviewed,
then `:ReviewClose`. Check that LSP, undo, source buffer contents, and your original
mappings still work. Use `use_merge_base = false` to compare directly to `main`.

## License

MIT; see [LICENSE](LICENSE).
