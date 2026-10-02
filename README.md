# delta.nvim

</br>
</br>

> [!WARNING]
> This tool is 100% vibecoded. It is designed purely as a personal tool, and I do
> not advise anyone to use it without reading through the code first.

</br>
</br>

Interactive Git review layered onto **your normal editable Neovim buffers**.
The plugin is named `delta.nvim`; the Lua namespace is `delta` and commands use the `Delta` prefix.
This is not a side-by-side diff viewer, a copied source buffer, or a read-only
review application.


- Full source files, with ordinary LSP, Treesitter, diagnostics, completion, undo,
  formatting, and filetype plugins.
- Added lines (`+`) and modified lines (`~`) highlighted in place; staged lines
  use a green `┃` gutter indicator.
- Deleted text displayed as **virtual lines**, never inserted into the file.
- Changed-files sidebar, wrapping file/hunk navigation, explicit reviewed state,
  and progress.
- Staged **and** unstaged changes, plus nonignored untracked files.
- Stage/unstage individual hunks; discard unstaged hunks or restore Delta-base
  hunks with confirmation and Neovim undo.
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
    "Delta", "DeltaClose", "DeltaRefresh", "DeltaToggleReviewed",
    "DeltaMarkReviewed", "DeltaMarkUnreviewed",
    "DeltaNextFile", "DeltaPrevFile", "DeltaNextHunk", "DeltaPrevHunk",
    "DeltaStageHunk", "DeltaUnstageHunk", "DeltaDiscardHunk", "DeltaRestoreBaseHunk",
  },
  config = function()
    require("delta").setup()
  end,
}
```

### Native packages

Clone into `~/.local/share/nvim/site/pack/plugins/start/delta.nvim` (or the
corresponding directory under your `stdpath("data")`). Commands work without
calling `setup()`. For configuration, add this to `init.lua`:

```lua
require("delta").setup({ base = "main" })
```

For local development, add this repository to `runtimepath` before calling
`setup()`.

## Walkthrough

```text
nvim .
:Delta origin/main
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
automatically. `:DeltaRefresh` also refreshes without saving: already-listed
loaded files are compared against their current buffer contents, including
unsaved edits. Newly changed files are discovered from the **filesystem**, so
save a previously unchanged file to include it in the Delta session.

Use `<leader>rr` in the source or `r` in the sidebar to toggle reviewed state.
Opening a file never marks it reviewed. The sidebar shows `N / total reviewed`.
Delta marks are invalidated when refresh detects changed file contents or
filesystem metadata; they are not approval of future edits.

`:DeltaClose` (or `q` in the sidebar) ends the session, clears overlays and Delta
mappings, and leaves your real source buffers and edits intact. Closing/wiping
the sidebar also ends the session.

## Base selection and working-tree semantics

`:Delta <base>` overrides `setup().base`. A base can be a local branch, remote
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
moving refs; restart `:Delta` after switching branches or updating the base.
The target is the current working tree, not the index: changes already committed
on the branch, staged changes, unstaged changes, and untracked files are visible.
Ignored untracked files are excluded. Only explicit stage/unstage commands modify
the Git index. Nothing commits, checks out, or writes source files on your behalf.

A refresh discovers all filesystem changes in the repository, removes files that
now match the base, updates progress, and reapplies overlays to loaded Delta
buffers. If the current file becomes unchanged, its buffer stays open and editable;
the sidebar selects another entry without stealing focus. File navigation then
continues through the remaining entries. Unsaved previously-listed buffers are
retained when their contents still differ even if the filesystem matches the base.

## Staging, unstaging and discarding hunks

These actions are separate from marking files reviewed. Run them in the source
buffer, with the cursor on the relevant change:

| Action | Comparison / effect |
| --- | --- |
| `:DeltaStageHunk` | Index → **saved filesystem**; apply the selected hunk to the index |
| `:DeltaUnstageHunk` | `HEAD` → index; reverse the selected staged hunk in the index |
| `:DeltaDiscardHunk` | Index → current buffer; restore that hunk from the index |
| `:DeltaRestoreBaseHunk` | Delta base → current buffer; restore that hunk from the pinned base |

**Discard preserves staged changes.** Restoring from the Delta base is deliberately
separate: it can reverse changes already committed on your branch, or changes
staged in the index, but only in the working buffer. Neither buffer restore action
modifies the index. Stage/unstage never modify your working file or buffer.

The Delta overlay always compares to the Delta base, so its hunks may differ
from index/staging hunks. Actions recompute the appropriate diff. A hunk under the
cursor is selected; otherwise, candidates overlapping the Delta hunk are used.
If there is no overlap, or several candidates need choosing, `vim.ui.select()`
shows a picker with working-buffer line numbers. Unstage positions account for
unstaged line insertions/deletions; committed review changes alone have nothing
to stage. File mode changes and empty-file additions/deletions have no text hunk;
they are handled as a single metadata action. File-mode changes accompanying a
text hunk are staged/unstaged along with that hunk.

**Stage requires a saved, up-to-date buffer.** Save unsaved edits first (`:w`);
if another process changed the file, reload/reconcile it before staging. Unstage
can operate with unsaved buffer edits because it touches only the index.

Both discard and Delta-base restore always ask for confirmation, with **Cancel**
first. They replace just the selected region in the real source buffer, preserve
unrelated edits, mark it unreviewed, and immediately update the overlay. Use `u`
to undo, or `:w` to save the result to disk. EOF newline changes follow undo/redo
as well. An entirely discarded new file becomes an empty editable file; it is not
automatically deleted from disk.

The sidebar displays `[SU]`: `S` means staged changes relative to `HEAD`, `U` means
unstaged/untracked filesystem changes relative to the index; `-` means none.
For example, `○ M [S-] source.lua` has staged changes only. These flags refresh
on save, manual refresh, and stage/unstage; unsaved edits are not filesystem state.
The `M`/`A`/`D` column still describes the Delta-base comparison.

Source gutter signs also reflect staging: ordinary Delta changes use `+`, `~`,
or `-`; currently staged changes use `┃` linked to the theme's green
`DiagnosticOk` highlight. This is calculated per line, not per file or review
hunk. If you edit a staged line again, its unstaged replacement uses the ordinary
sign after refresh, while other staged lines remain green. Committed branch
changes are not currently staged and retain their ordinary Delta signs.
Staging/unstaging refreshes these indicators automatically; save or manually
refresh after editing or changing the index externally. Line backgrounds and
virtual deletions still describe the Delta-base diff, independently of staging.

Index mutations use `git apply --cached` (reversed for unstage) with the normal
Git index lock, a private alternate index, and atomic publication. Buffer/session,
index-entry, and `HEAD` checks cancel stale actions instead of silently applying
an old selection. Concurrent Git writers are respected; locks are released on
failure/cancellation. Closing the session cancels pending actions. A hunk picker
or confirmation remains pending until you choose/cancel it; other hunk actions
are blocked until then.

## Commands

| Command | Action |
| --- | --- |
| `:Delta [base]` | Start/replace the repository's Delta session |
| `:DeltaClose` | End Delta and clean up |
| `:DeltaRefresh` | Refresh discovery and loaded-file overlays |
| `:DeltaToggleReviewed` | Toggle the current/selected file |
| `:DeltaMarkReviewed` | Mark the current/selected file reviewed |
| `:DeltaMarkUnreviewed` | Mark it unreviewed |
| `:DeltaNextFile`, `:DeltaPrevFile` | Open next/previous changed file, wrapping |
| `:DeltaNextHunk`, `:DeltaPrevHunk` | Jump between hunk anchors, wrapping |
| `:DeltaStageHunk` | Stage selected unstaged hunk (save first) |
| `:DeltaUnstageHunk` | Unstage selected staged hunk |
| `:DeltaDiscardHunk` | Confirm and restore hunk from the index, in buffer |
| `:DeltaRestoreBaseHunk` | Confirm and restore hunk from the Delta base, in buffer |

Hunk navigation uses real source line numbers. A pure deletion anchors to the
following real line, or the last line for an EOF deletion. Deleted virtual text
is not a cursor destination. If there are no hunks/files, navigation is a no-op.

## Mappings

Source mappings are **buffer-local** and only installed on files in the Delta session.
Existing local mappings are restored on close (unless you replaced the mapping
while reviewing). Global mappings are never modified. Set any mapping to `false`
or `""` to disable it.

| Source mapping | Action |
| --- | --- |
| `]h`, `[h` | Next/previous hunk |
| `]f`, `[f` | Next/previous file |
| `<leader>rr` | Toggle reviewed |
| `<leader>rs` | Stage hunk |
| `<leader>ru` | Unstage hunk |
| `<leader>rd` | Discard unstaged hunk (confirmation) |
| `<leader>rb` | Restore Delta-base hunk (confirmation) |

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
require("delta").setup({
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
    stage_hunk = "<leader>rs",
    unstage_hunk = "<leader>ru",
    discard_hunk = "<leader>rd",
    restore_base_hunk = "<leader>rb",
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
local delta = require("delta")
delta.start("main") -- asynchronous
delta.refresh()     -- asynchronous
delta.close()
delta.next_file()
delta.prev_file()
delta.next_hunk()
delta.prev_hunk()
delta.toggle_reviewed()
delta.mark_reviewed()
delta.mark_unreviewed()
delta.stage_hunk()
delta.unstage_hunk()
delta.discard_hunk()       -- confirmation, buffer-only; :w to save
delta.restore_base_hunk()  -- confirmation, buffer-only; :w to save
local progress = delta.progress() -- { reviewed = 4, total = 11 }
local session = delta.get_session() -- nil when inactive; inspect, do not mutate
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
| `DeltaAdd`, `DeltaAddSign` | `DiffAdd` |
| `DeltaDelete`, `DeltaDeleteSign`, `DeltaVirtualDelete` | `DiffDelete` |
| `DeltaChange`, `DeltaChangeSign` | `DiffChange` |
| `DeltaStagedSign` | `DiagnosticOk` (staged `┃` gutter indicator) |

Definitions use `default = true` and are reapplied on `ColorScheme`.

## Architecture

- `git.lua`: argument-array `vim.system()` calls, root/base/merge-base resolution,
  NUL-delimited file discovery, conflict checks, lazy base content retrieval.
- `diff.lua`: unified hunk parser and `vim.diff()` comparison of base text to the
  real buffer; zero-context hunks, omitted/zero counts, no-newline markers.
- `session.lua`: explicitly owned session state, async invalidation tokens,
  buffer lifecycle, refresh, mapping restoration, navigation and progress.
- `operations.lua`: fresh action-specific diffs, hunk selection, confirmation,
  safety checks, staging/unstaging/discard/Delta-base restore.
- `index.lua`: raw filesystem snapshots and locked alternate-index transactions.
- `staging.lua`: maps staged index hunks into working-buffer lines, excluding
  unstaged replacements, for accurate per-line gutter indicators.
- `buffer.lua`: source text, minimal hunk replacement, and undo-aware EOF options.
- `decorations.lua`: one namespace, extmark line highlights/signs, virtual deletions.
- `sidebar.lua`: scratch sidebar only; never a replacement source buffer.
- `config.lua`, `commands.lua`, `init.lua`: configuration, commands, public API.

Base text comes from Git, but hunks are computed against the actual editable
buffer using Neovim's diff engine. This supports unsaved edits and avoids
external diff drivers/textconv and manual offset maintenance.

## Limitations / deliberate v1 choices

- Fully deleted files use a **read-only scratch buffer containing the base file**,
  highlighted as deleted. This exception is explicit (`delta-deleted://…` buffer
  name); existing regular files always use their real buffers.
- Renames appear as deletion + addition (`--no-renames`), not `R` entries.
- Binary content has no inline overlay. Gitlinks/submodule directories and symlinks
  are listed but cannot be opened for inline review; a warning explains this.
- Unresolved merge conflicts are rejected. There is no conflict resolution UI.
- Hunk actions require an open Delta file and ordinary UTF-8 text (Unix or DOS
  line endings). Changing UTF-8 BOM presence via buffer restore is rejected;
  existing BOMs are preserved. Files outside the base-delta list are not accessible
  through these commands. Binary files, symlinks, and submodules are not supported.
- Fully deleted files support stage/unstage from their read-only representation.
  Buffer-only discard/Delta-base restore requires an existing editable source
  file; use Git's file-level restore outside the plugin to recreate a missing file.
- Delta state is in-memory only. No persistent state, automatic approval,
  branch-change watcher, filesystem watcher, or typing-time diff calculation.
- Text comparisons use Neovim's decoded buffer text; unusual encodings, Git
  clean/smudge filters, and custom attributes may not exactly reproduce Git's
  byte-level diff. Use Delta on ordinary text files; binary/encoded workflows need care.
- Very large text files or deletions can take time to diff/render on the main
  thread. Git discovery/content retrieval is asynchronous and full diffs are lazy.
- Mapping configuration is intended to be set before starting a session.

## Testing

Run from the repository root:

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/operations.lua
```

No test framework dependency. Tests exercise parser/zero-count/no-newline cases,
virtual deletion placement without source mutation, and temporary Git repositories:
real buffers, staged/unstaged/untracked/deleted files, unusual path characters,
manual/automatic refresh, progress, navigation, mapping restoration and cancellation.
Hunk-operation tests cover partial stage/unstage, index-preserving discard,
committed Delta-base restore, unsaved/stale buffers, confirmation cancellation,
quoted paths, intent-to-add, empty/executable/deleted files, EOF undo/redo branches,
external index updates, lock cleanup, session-close cancellation, DOS/BOM text,
missing indexes, split indexes, linked-worktree isolation, and staged gutter
updates for additions/modifications/deletions, shifted lines, and unsaved edits.

For a manual smoke test, change/add/delete files in a disposable Git repository,
run `:Delta main`, and confirm that deleted lines have no real line numbers.
Edit an actual source line, save, check the updated overlay, mark it reviewed,
then `:DeltaClose`. Check that LSP, undo, source buffer contents, and your original
mappings still work. Use `use_merge_base = false` to compare directly to `main`.

For hunk actions, make two separated changes in a tracked file and save. Run
`:DeltaStageHunk` on one and verify with `git diff --cached`; the other change
should remain in `git diff`. Run `:DeltaUnstageHunk` to reverse just that staging.
Try `:DeltaDiscardHunk`, confirm, check that only the selected buffer region was
restored, then `u` to undo or `:w` to persist. For the distinction between index and
base restore, commit a branch change and confirm that `:DeltaRestoreBaseHunk`
can reverse it in the buffer without changing the commit or index.

## License

MIT; see [LICENSE](LICENSE).
