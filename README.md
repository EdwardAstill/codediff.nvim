# codediff.nvim

**Review diffs, prepare commits, and keep Git operations explicit.**

This is Edward Astill's personal fork of [CodeDiff](https://github.com/esmuellert/codediff.nvim). Its default Git status view is a floating four-pane review workspace, not upstream's full-tab Explorer. It retains the VSCode-style diff engine, live refresh, revision/history views, and conflict resolution.

Git review does not require an agent. The optional [OMP handoff](#send-a-hunk-to-omp) adds a selected hunk to your existing OMP draft only when requested; it never submits a model request automatically.

## Quick start

After [installation](#installation), save your file edits and run `:CodeDiff` inside a Git repository.

1. Press `h` for review shortcuts; press `h` again to return.
2. In **Unstaged**, use `i`/`k` or arrows to choose a file, then Enter to preview it.
3. Use Tab to focus a numbered diff pane and `[`/`]` to select a hunk. Press `s` to stage it. For an entire file or folder, use `s` on its row in the tree instead.
4. Inspect **Staged** before committing. Press `c`, check the displayed HEAD, type a message, then Ctrl-s to commit the index.
5. Press `q` to close review and restore your editor's keys and chrome.

Need to undo a choice? [Unstage and revert are different](#stage-unstage-and-revert). Other tasks: [stash](#stash-tracked-changes), [branches/worktrees](#inspect-branches-and-worktrees), [OMP](#send-a-hunk-to-omp), [troubleshooting](#safety-and-troubleshooting), and [upgrading](#upgrading-this-fork). `:CodeDiff help` works without opening a review; `:help codediff` opens the full manual.

## Features

- **Live review:** Diffs stay synchronized with repository changes while you edit.
- **VSCode style diffs:** Review side-by-side or inline changes with line- and character-level highlighting.
- **Four-pane review:** Unstaged above Staged on the narrow left; numbered Before and After diffs beside them.
- **Git staging:** Stage or unstage individual hunks, files, or folders. Revert restores working-file content independently of the index.
- **Repository actions:** Commit the index, stash tracked changes, and inspect local branches or worktrees in separate popups.
- **Explicit OMP handoff:** Add the selected hunk with an optional message to an existing draft; ordinary Git review stays independent.
- **Other comparison modes:** Review revisions, pull requests, and history in native tab layouts.
- **Focused navigation:** Move between files and hunks, fold unchanged code, and track moved blocks.
- **Conflict resolution:** Resolve merge conflicts per block or across the whole file.
- **Editor-native context:** Keep Tree-sitter syntax highlighting in revision buffers.

## Installation

### Prerequisites

- Neovim 0.10 or newer: the review UI uses `vim.system()` and floating-window footers
- Git for repository workflows
- `curl` or `wget` on Unix, or PowerShell on Windows, for automatic downloads
- A Nerd Font is optional for the default Explorer folder icons

**No compiler required on supported platforms.** The plugin automatically downloads pre-built binaries from upstream GitHub releases; this fork does not publish binaries.

### Using lazy.nvim

**Minimal installation:**
```lua
{
  "EdwardAstill/codediff.nvim",
  cmd = "CodeDiff",
}
```

To add a launcher, include `keys = { { "<leader>d", "<cmd>CodeDiff<cr>", desc = "Review changes" } }` in the plugin spec. This is Space d only if your leader is Space. Install [EdwardAstill/omp.nvim](https://github.com/EdwardAstill/omp.nvim) separately if you want the optional `o` handoff; no OMP dependency is needed for Git actions.

### Automatic installation

CodeDiff automatically downloads the matching diff library on first use and after plugin updates. No build step is required.

The diff library and Linux OpenMP runtime come from [upstream codediff.nvim releases](https://github.com/esmuellert/codediff.nvim/releases), matching the unchanged `VERSION` file. Live refresh also uses the separately versioned `codediff-watcher` from [upstream codediff releases](https://github.com/esmuellert/codediff/releases). These download sources are intentionally preserved; they do not point at this fork's empty release page. Watcher archive extraction requires `tar` on Unix or PowerShell on Windows.

To install it explicitly or force a reinstall when troubleshooting:

```vim
" Install or update the diff library
:CodeDiff install

" Force reinstall
:CodeDiff install!
```

### Manual Installation

To install without a plugin manager, follow these steps. The example uses a Unix-style path; on Windows, choose a local directory and use that path in both the clone command and the runtime path setting.

1. **Clone the repository:**
```bash
git clone https://github.com/EdwardAstill/codediff.nvim ~/.local/share/nvim/codediff.nvim
```

2. **Add to your Neovim runtime path in `init.lua`:**
```lua
vim.opt.rtp:append("~/.local/share/nvim/codediff.nvim")
```

3. **Restart Neovim and use `:CodeDiff`.**

The diff library is still downloaded automatically on first use, even without a plugin manager.

#### Optional: manually install the diff library

If automatic downloads are unavailable, or you prefer to build the diff library yourself, use one of the options below.

Place the library in the plugin root directory using one of these filenames:
- `libvscode_diff.so` or `libvscode_diff_<version>.so` (Linux/BSD)
- `libvscode_diff.dylib` or `libvscode_diff_<version>.dylib` (macOS)
- `libvscode_diff.dll` or `libvscode_diff_<version>.dll` (Windows)

**Option A: Download from GitHub releases** (recommended)

1. Choose the [release](https://github.com/esmuellert/codediff.nvim/releases) matching your installed plugin version.
2. Download the binary for your operating system and Neovim's CPU architecture.
3. Place it in the plugin root directory and rename it using one of the filenames listed above.

If no pre-built binary is available for your platform, use Option B.

**Linux users**: If `libgomp.so.1` is unavailable to Neovim, also download `libgomp_linux_{arch}_{version}.so.1` from the same release for the same architecture and rename it to `libgomp.so.1` in the plugin root directory.

**Option B: Build from source**

Build requirements: a C11 compiler. CMake 3.15 or newer is optional for the developer build.

Run the following commands from the plugin root directory. For the Unix example above, first run `cd ~/.local/share/nvim/codediff.nvim`.

Using build scripts (no CMake required):
```bash
# Linux/macOS/BSD
./build.sh
```

```cmd
REM Windows
build.cmd
```

Or using CMake:
```bash
cmake -B build
cmake --build build
```

Both methods automatically place the library in the plugin root directory.

## Configuration

The full reference below includes settings for native revision/history/inline views. The status popup deliberately fixes its four-pane arrangement, narrow tree sizing, tree view mode, numbering, and [review controls](#review-controls); native `explorer.width`, `position`, `view_mode`, and `keymaps.view`/`keymaps.explorer` bindings are not a popup-layout editor. Setting `diff.layout = "inline"` opts into a native inline status view instead of the popup.

<details>
<summary><strong>Full configuration reference</strong></summary>

```lua
{
  "EdwardAstill/codediff.nvim",
  cmd = "CodeDiff",
  opts = {
    -- Highlight configuration
    highlights = {
      -- Line-level: accepts highlight group names or hex colors (e.g., "#2ea043")
      line_insert = "DiffAdd",      -- Line-level insertions
      line_delete = "DiffDelete",   -- Line-level deletions

      -- Character-level: accepts highlight group names or hex colors
      -- If specified, these override char_brightness calculation
      char_insert = nil,            -- Character-level insertions (nil = auto-derive)
      char_delete = nil,            -- Character-level deletions (nil = auto-derive)

      -- Brightness multiplier (only used when char_insert/char_delete are nil)
      -- nil = auto-detect based on background (1.4 for dark, 0.92 for light)
      char_brightness = nil,        -- Auto-adjust based on your colorscheme

      -- Conflict sign highlights (for merge conflict views)
      -- Accepts highlight group names or hex colors (e.g., "#f0883e")
      -- nil = use default fallback chain
      conflict_sign = nil,          -- Unresolved: DiagnosticSignWarn -> #f0883e
      conflict_sign_resolved = nil, -- Resolved: Comment -> #6e7681
      conflict_sign_accepted = nil, -- Accepted: GitSignsAdd -> DiagnosticSignOk -> #3fb950
      conflict_sign_rejected = nil, -- Rejected: GitSignsDelete -> DiagnosticSignError -> #f85149
    },

    -- Diff view behavior
    diff = {
      layout = "side-by-side",             -- Diff layout: "side-by-side" (two panes) or "inline" (single pane with virtual lines)
      filler_text = "╱",                   -- Repeated filler pattern; use "" for blank alignment rows
      disable_inlay_hints = true,         -- Disable inlay hints in diff windows for cleaner view
      max_computation_time_ms = 5000,     -- Maximum time for diff computation (VSCode default)
      ignore_trim_whitespace = false,     -- Ignore leading and trailing whitespace changes
      hide_merge_artifacts = false,       -- Hide merge tool temp files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*)
      original_position = "left",         -- Position of original (old) content: "left" or "right"
      conflict_ours_position = "right",   -- Position of ours (:2) in conflict view: "left" or "right"
      conflict_result_position = "bottom", -- "bottom" (default): result below diff panes or "center": result between diff panes (three columns)
      conflict_result_height = 30,         -- Height of result pane in bottom layout (% of total height)
      conflict_result_width_ratio = { 1, 1, 1 }, -- Width ratio for center layout panes {left, center, right} (e.g., {1, 2, 1} for wider result)
      cycle_next_hunk = true,             -- Wrap around when navigating hunks (]c/[c): false to stop at first/last
      cycle_next_file = true,             -- Wrap around when navigating files (]f/[f): false to stop at first/last
      cycle_hunks_across_files = false,   -- ]c/[c at file boundary hops to first/last hunk of next/prev file (explorer/history)
      jump_to_first_change = true,        -- Auto-scroll to first change when opening a diff: false to stay at same line
      highlight_added_deleted_files = false, -- Tint full contents of added, untracked, and deleted files
      highlight_priority = 100,           -- Priority for line-level diff highlights (increase to override LSP highlights)
      gutter_signs = false,                -- Gutter +/- signs; see Gutter signs below
      compute_moves = false,              -- Detect moved code blocks (opt-in, matches VSCode experimental.showMoves)
      compact_context_lines = 3,          -- Number of context lines around hunks in compact mode
      compact_sync_folds = true,          -- Sync fold open/close across panes (mirrors Vim diff mode behavior)
      compact = false,                    -- Default compact preference for each CodeDiff session; toggle with gc
    },

    -- Explorer panel configuration
    explorer = {
      position = "left",  -- Native Explorer: "left" or "bottom"; popup placement is fixed
      hidden = false,  -- Initial visibility state
      width = 40,         -- Native Explorer width (columns); popup uses its own narrow sizing
      height = 15,        -- Native bottom Explorer height (lines)
      auto_refresh = true,  -- Native file watching with polling fallback; native Explorer also has R
      indent_markers = true,  -- Show indent markers in tree view (│, ├, └)
      initial_focus = "explorer",  -- Initial focus: "explorer", "original", or "modified"
      icons = {
        folder_closed = "\u{e5ff}", -- Nerd Font folder icon
        folder_open = "\u{e5fe}",   -- Nerd Font open-folder icon
      },
      view_mode = "list",    -- Native Explorer: "list" or "tree"; popup always uses trees
      flatten_dirs = true,   -- Flatten single-child directory chains in tree view
      file_filter = {
        ignore = { ".git/**", ".jj/**" },  -- Glob patterns to hide (e.g., {"*.lock", "dist/*"})
      },
      untracked = "all",  -- Untracked scan: "all", "normal" (collapse dirs), or "no" (skip; use for huge work trees like GIT_WORK_TREE=$HOME that hang, #389)
      focus_on_select = false,  -- Jump to modified pane after selecting a file (default: stay in explorer)
      auto_open_on_cursor = false, -- Preview on cursor movement; popup uses i/k/Up/Down
      status_right_margin = 1,  -- Trailing cells between status symbol (M/A/D) and right edge; increase if Nerd Font icons clip it
      line_stats = {
        enabled = false,         -- Fetch and show Git line statistics
        count_untracked = false, -- Count untracked file lines as insertions
        max_untracked_bytes = 1024 * 1024, -- Skip larger untracked files
      },
      ellipsis = "…",          -- Text appended to truncated Explorer regions
      formatters = {  -- Optional function(ctx) -> line layout callbacks; omit to use the built-ins
        file = nil,   -- File rows
        folder = nil, -- Directory rows in tree view
        group = nil,  -- Section headers such as Changes and Staged Changes
      },
      visible_groups = {       -- Which groups to show (can be toggled at runtime)
        staged = true,
        unstaged = true,
        conflicts = true,
      },
    },

    -- History panel configuration (for :CodeDiff history)
    history = {
      position = "bottom",  -- "left" or "bottom" (default: bottom)
      width = 40,           -- Width when position is "left" (columns)
      height = 15,          -- Height when position is "bottom" (lines)
      initial_focus = "history",  -- Initial focus: "history", "original", or "modified"
      view_mode = "list",   -- "list" or "tree" for files under commits
      date_format = "%ar",  -- Commit date rendering: "%ar" (default, relative), "%ai" (ISO), "%ad" (git default), or any strftime string (e.g. "%Y/%m/%d %H:%M:%S")
    },

    -- Keymaps for revision/history/inline views; the status popup uses review controls below.
    keymaps = {
      view = {
        quit = "q",                    -- Close diff workspace
        toggle_explorer = "<leader>b",  -- Toggle explorer visibility (explorer mode only)
        focus_explorer = "<leader>e",   -- Focus explorer panel (explorer mode only)
        next_hunk = "]c",   -- Jump to next change
        prev_hunk = "[c",   -- Jump to previous change
        next_file = "]f",   -- Next file in explorer/history mode
        prev_file = "[f",   -- Previous file in explorer/history mode
        diff_get = "do",    -- Get change from other buffer (like vimdiff)
        diff_put = "dp",    -- Put change to other buffer (like vimdiff)
        open_in_prev_tab = "gf", -- Open file in the previous tab
        close_on_open_in_prev_tab = false, -- Close the native diff tab after gf
        toggle_stage = "-", -- Stage/unstage selected file or folder
        toggle_staged_view = "gS", -- Swap between staged/unstaged view of current file (#352)
        stage_hunk = "<leader>hs",   -- Stage hunk under cursor to git index
        unstage_hunk = "<leader>hu", -- Unstage hunk under cursor from git index
        revert_hunk = "<leader>hr", -- Restore hunk to LEFT baseline; index stays unchanged
        hunk_textobject = "ih",      -- Textobject for hunk (vih to select, yih to yank, etc.)
        show_help = "g?",   -- Show floating window with available keymaps
        align_move = "gm", -- Temporarily align moved code blocks across panes
        toggle_layout = "t", -- Toggle between side-by-side and inline layout
        toggle_compact = "gc", -- Toggle compact mode (fold unchanged regions)
      },
      explorer = {
        select = "<CR>",    -- Open diff for selected file
        hover = "K",        -- Show full path
        refresh = "R",      -- Refresh git status
        toggle_view_mode = "i",  -- Toggle between 'list' and 'tree' views
        stage_all = "S",    -- Stage all files
        unstage_all = "U",  -- Unstage all files
        restore = "X",      -- Discard changes (restore file)
        toggle_changes = "gu",  -- Toggle Changes (unstaged) group visibility
        toggle_staged = "gs",   -- Toggle Staged Changes group visibility
        -- Fold keymaps (Vim-style)
        fold_open = "zo",           -- Open fold (expand current node)
        fold_open_recursive = "zO", -- Open fold recursively (expand all descendants)
        fold_close = "zc",          -- Close fold (collapse current node)
        fold_close_recursive = "zC", -- Close fold recursively (collapse all descendants)
        fold_toggle = "za",         -- Toggle fold (expand/collapse current node)
        fold_toggle_recursive = "zA", -- Toggle fold recursively
        fold_open_all = "zR",       -- Open all folds in tree
        fold_close_all = "zM",      -- Close all folds in tree
      },
      history = {
        select = "<CR>",    -- Select commit/file or toggle expand
        toggle_view_mode = "i",  -- Toggle between 'list' and 'tree' views
        refresh = "R",      -- Refresh history (re-fetch commits)
        -- Fold keymaps (Vim-style, apply to directory nodes only)
        fold_open = "zo",           -- Open fold (expand current node)
        fold_open_recursive = "zO", -- Open fold recursively (expand all descendants)
        fold_close = "zc",          -- Close fold (collapse current node)
        fold_close_recursive = "zC", -- Close fold recursively (collapse all descendants)
        fold_toggle = "za",         -- Toggle fold (expand/collapse current node)
        fold_toggle_recursive = "zA", -- Toggle fold recursively
        fold_open_all = "zR",       -- Open all folds in tree
        fold_close_all = "zM",      -- Close all folds in tree
      },
      conflict = {
        accept_incoming = "<leader>ct",  -- Accept incoming (theirs/left) change
        accept_current = "<leader>co",   -- Accept current (ours/right) change
        accept_both = "<leader>cb",      -- Accept both changes
        discard = "<leader>cx",          -- Discard both, keep base
        -- Accept all (whole file) - uppercase versions
        accept_all_incoming = "<leader>cT",  -- Accept ALL incoming changes
        accept_all_current = "<leader>cO",   -- Accept ALL current changes
        accept_all_both = "<leader>cB",      -- Accept ALL both changes
        discard_all = "<leader>cX",          -- Discard ALL, reset to base
        next_conflict = "]x",            -- Jump to next conflict
        prev_conflict = "[x",            -- Jump to previous conflict
        diffget_incoming = "2do",        -- Get hunk from incoming (left/theirs) buffer
        diffget_current = "3do",         -- Get hunk from current (right/ours) buffer
      },
    },
  },
}
```

</details>

### Native keymap configuration

These configurable actions apply to native revision/history/inline views, not the fixed popup key layer. Press `g?` in a native view, or use `:CodeDiff help`, to see its active bindings. `o` is also available on native diff buffers for the optional OMP handoff.

Each configurable action accepts a single key or a list of keys:

```lua
keymaps = { view = { quit = { "q", "<Esc>" } } }
```

Set an action to `false` or `{}` to disable it. An explicitly configured mapping takes precedence over another action's default. If two explicitly configured actions use the same key, CodeDiff warns that only one can work.

### Explorer line statistics

Line statistics are disabled by default because they run additional Git queries. Set `explorer.line_stats.enabled = true` to show per-file counts and group totals in Explorer views for repository status and revision comparisons. Untracked files are counted only when `count_untracked = true`; untracked files larger than `max_untracked_bytes` are skipped.

Files display `+12 -4`, or `bin` for binary files. Group headings display totals such as `Changes (3 · +42 -8)`. Folder and group `stats` values contain `files_changed`, `insertions`, `deletions`, `binary_files`, and `unavailable_files`.

### Explorer line formatters

`explorer.formatters.file`, `folder`, and `group` replace the complete corresponding Explorer row. Each callback receives row metadata and returns a layout:

```lua
{
  left = {
    {
      segments = { { text = "name.lua", hl = "Normal" } },
      truncate_priority = 2,
    },
  },
  right = {
    {
      segments = { { text = "M", hl = "CodeDiffStatusModified" } },
    },
  },
  min_gap = 2,
}
```

A layout contains `left` and `right` lists of regions and an optional `min_gap` (default `2`). Each region contains styled `segments`. A numeric `truncate_priority` makes the region truncatable; lower values truncate first, while regions without a priority remain fixed until necessary. The `right` side is right-aligned, and truncated text uses `explorer.ellipsis`.

Each segment is `{ text = string, hl? = highlight }`. `hl` accepts a Neovim highlight group, a `#RGB`/`#RRGGBB` foreground color, or a highlight definition such as `{ fg = "#3fb950", bold = true }`. Omitted highlights use `Normal`; selected file rows retain their selection background.

File contexts contain `path`, `filename`, `directory`, `old_path`, `group`, `stats`, `status`, `status_hl`, `status_right_margin`, `indent`, `indent_hl`, `icon`, and `icon_hl`. Folder contexts contain `name`, `path`, `group`, `file_count`, `stats`, `files`, `indent`, `indent_hl`, `icon`, `icon_hl`, and `expanded`. Group contexts contain `name`, `label`, `file_count`, `stats`, `files`, and `expanded`. `stats` is `nil` when line statistics are disabled.

Folder and group `files` contain `{ path, old_path, group, status, stats }` entries for every represented file. The built-in callbacks are exported by `codediff.ui.explorer.formatters` and return fresh layouts that can be assigned directly or wrapped.

```lua
require("codediff").setup({
  explorer = {
    formatters = {
      group = function(ctx)
        return {
          left = {{
            segments = {{ text = " " .. ctx.label, hl = "CodeDiffExplorerTreeGroup" }},
            truncate_priority = 1,
          }},
          right = {{
            segments = {{ text = ctx.file_count .. " files", hl = "Number" }},
          }},
        }
      end,
    },
  },
})
```

### Gutter signs

The optional `+`/`-` gutter renderer is disabled by default. It is separate from the popup's always-available `>` active-hunk markers and numbered diff panes. Enable additional gutter signs under `diff`:

```lua
gutter_signs = {
  insert_text = "＋",
  delete_text = "－",
  highlight_numbers = true,
  changed_priority = 100,
  unchanged_priority = nil,
}
```

`insert_text` and `delete_text` must each occupy one or two display cells. To place a blank sign at priority `7` on unchanged lines, set:

```lua
gutter_signs = {
  unchanged_priority = 7,
}
```

Changed signs use priority `100` by default, so they remain visible. This renderer does not configure `signcolumn` or `statuscolumn`; the popup has its own window presentation. For native views, this example reserves one sign column and places signs after line numbers:

```lua
vim.opt.signcolumn = "yes"
vim.opt.statuscolumn = "%C%=%l %s"
```

With one sign column, the blank priority-`7` sign hides signs with lower priorities. Set `signcolumn` to `"yes:2"` to allow a second sign column.

## Usage

Use `:CodeDiff` to review repository changes, pull requests, files, directories, and history.

### Review workspace

With the default side-by-side layout, `:CodeDiff` opens a popup in the **current tab**, including in a clean repository. **Unstaged** is top-left and **Staged** bottom-left; **Before** is in the middle and **After** on the right. A file may appear in both trees when it has both staged and unstaged changes.

The left trees have no line numbers; the diff panes have absolute line numbers. The normal statusline/mode area is hidden while review is active, with compact hints in the borders. Leaving or closing the popup restores editor chrome. This is a local review keymap layer, not a new Vim editing mode.

Enter previews a file; it does not open that file for ordinary editing. Use Tab/Shift-Tab to move between panes. In a diff, the cursor chooses the hunk: `>` gutter markers, emphasized numbers, and `Hunk N/M` identify it in both panes. The selection remains visible while an action dialog is open. Moving into a tree leaves no active diff hunk; `r` and `o` belong to diff panes, not file rows.

Added/deleted files can be one-sided comparisons. A conflict adds a Result pane and uses conflict-resolution actions; ordinary Revert does not resolve merge conflicts.

#### Review controls

| Focus | Key | Action |
| --- | --- | --- |
| Workspace | `q` / `Ctrl-q` | Close review and restore ordinary editor controls |
| Workspace | `h` / `:CodeDiff help` | Show shortcuts; `h` closes the help popup |
| Workspace | `Ctrl-s` / `Ctrl-Shift-s` | Show help, **not** write a file |
| Workspace | `Tab` / `Shift-Tab` | Next / previous pane |
| Workspace | `i` / `k` | Move up / down |
| Workspace | `[` / `]` | Previous / next hunk |
| Trees | Up / Down | Move up / down |
| Trees | `j` / `l` | Collapse / expand folder; `l` also previews a file |
| Trees | Enter / double-click | Preview file or toggle folder/group |
| Trees | `s` | Stage/unstage the selected file or directory |
| Trees | `S` / `U` | Stage / unstage all changes in the repository |
| Diffs | `j` / `l` | Move left / right |
| Diffs | `s` | Stage an unstaged hunk or unstage a staged hunk |
| Diffs | `r` | Confirm Revert of the working-file hunk to its comparison baseline |
| Diffs | `o` | Compose an optional message for the selected hunk's OMP handoff |
| Workspace | `c` | Commit message popup |
| Workspace | `z` | Confirm tracked-change stash |
| Workspace | `b` / `w` | Separate read-only local branch / worktree lists |

Child dialogs have their own controls: `q`/Escape/Ctrl-q close read-only lists; `y` confirms a destructive action and `n` cancels it. Commit and OMP composers start in Insert mode. **Ctrl-q cancels a composer**; Escape first leaves Insert mode rather than necessarily closing it. Normal-mode `q` or Escape then closes it. Closing a draft discards that draft text.

#### Stage, unstage, and revert

The default status popup uses these comparisons:

| Selected group/view | Before (original) | After (modified) | What Revert restores in the working file |
| --- | --- | --- | --- |
| Unstaged | Git index | Working file | The index version of the hunk |
| Staged | HEAD | Git index | The HEAD version of the hunk |
| Native revision vs working tree | Requested Git revision | Working file | That requested revision's hunk |
| Added file with no original version | Empty file | Added content | Removes the selected addition |

- **Stage** changes the index, preparing content for the next commit. In a tree, `s` operates on the whole file/directory; in a diff, it operates on the cursor's hunk.
- **Unstage** in the Staged tree/diff changes the index back toward HEAD and keeps working-file edits. It does not undo the edit in the file.
- **Revert** changes the working file back to Before and **never changes the index**. Confirm the named baseline with `y`; cancel with `n`, `q`, Escape, or Ctrl-q.

Consequently, reverting a staged hunk can leave the file in **both** trees: the staged version is still ready to commit, while the working file now differs from it. If you also want that staged change removed, unstage it separately and inspect both trees before committing.

Use the default status view, or native inline status, for staging decisions. A comparison against an arbitrary revision is not the same as the normal index-versus-working-file comparison. Revert is available for working-tree/staged comparisons with a Git baseline, not two immutable commits, non-Git file comparisons, or merge views.

File/folder staging reads on-disk paths; hunk staging can stage the displayed buffer content without saving it. Save first if you want the disk and index to represent the same edit. A directory action targets the whole path, and `S`/`U` target the repository—not just visible rows under a filter.

Revert preserves unrelated hunks and the file's line endings. It refuses unsaved target buffers, changed comparisons, stale file/index state, renamed comparisons, or overlapping working edits it cannot safely match. Do not force it through a refusal: save or inspect the file, refresh/reopen review, and select the hunk again. Unstaged edits discarded by Revert may not be recoverable by Git.

#### Commit staged changes

1. Inspect the **Staged** tree; the commit includes the index, not just the selected file.
2. Press `c`. The title shows the current branch and short HEAD, or detached/unborn HEAD; it is not a branch picker and is not part of the message.
3. Type a message, including multiple lines if needed.
4. Ctrl-s submits from Insert or Normal mode. Normal-mode `s` is also a submit shortcut inside this dialog.

CodeDiff never auto-stages. An empty message, empty index, changed HEAD, or Git/hook failure blocks the commit; errors retain the draft while the dialog remains open. If HEAD changed, cancel and reopen to review the new target. Cancel before submitting to avoid a commit; closing a dialog is not an undo for a Git operation already started.

#### Stash tracked changes

Press `z` and inspect the confirmation's HEAD. `y` runs a normal `git stash push`: it saves **both staged and unstaged tracked changes**, then resets the index and tracked working files to HEAD. Untracked files stay in place.

Stash refuses unsaved tracked buffers, including buffers for staged-deleted files, changed HEAD, or an unborn HEAD. Clean affected buffers reload; edits made while Git runs are not overwritten. There is no stash-message composer or stash list/apply/pop/drop interface here; use Git or your normal Git client to restore a stash.

#### Inspect branches and worktrees

`b` lists **local** branches, marking the current branch and showing short commit IDs and subjects. `w` separately lists worktree paths, branches/HEADs, and applicable detached/bare/locked/prunable details. Use `i`/`k` to move through these read-only lists and `q`, Escape, or Ctrl-q to close.

Neither list switches checkout, creates/deletes branches or worktrees, or changes the commit dialog's HEAD. The actions remain available when the repository has no changes.

#### Send a hunk to OMP

Install/configure [EdwardAstill/omp.nvim](https://github.com/EdwardAstill/omp.nvim) separately; normal review does not start or require it.

1. Focus either diff pane and select the hunk with the cursor or `[`/`]`.
2. Press `o`. The composer captures that hunk before taking focus.
3. Type an optional message, or leave it blank to send only the hunk.
4. Ctrl-s adds the message, repository/file paths, comparison revisions, line ranges, and before/after hunk text to the **selected OMP session's existing draft**.
5. OMP opens above review. Inspect/edit the draft and press Enter **in OMP** only when you want to submit it. Ctrl-q hides OMP and returns to the originating diff pane.

The handoff sends neither the whole file nor unrelated hunks. It preserves existing draft text and uses the captured snapshot, even if the review later changes. Ctrl-q in the composer cancels without sending. Missing OMP or an immediate failed send keeps the composer for retry; later bridge errors are reported by OMP. Queueing a draft is not a model response or a guarantee that an asynchronous delivery succeeded.

`o` also works in native diff views. An OMP proposal's **Reject** action belongs to OMP proposal review; it is not CodeDiff's Git Unstage or working-file Revert.

#### Safety and troubleshooting

| Symptom | What to do |
| --- | --- |
| A save key opens help | Expected in review. Close with `q`, save the actual file in the editor, then reopen. Trees/help/dialogs are scratch buffers. |
| No hunk selected | Preview a file, Tab into a numbered diff, and move onto a change. A highlighted tree row is not a hunk selection. |
| Revert/stash refuses unsaved changes | Save or otherwise resolve those edits outside review first; the action will not silently write or discard them. |
| A hunk changed while confirmation was open | Reopen/refresh the comparison and select it again; do not apply an old patch to new content. |
| A reverted staged change is still listed | Revert left the index intact. Unstage separately if it must not be committed. |
| An added/deleted side is blank | This is a one-sided comparison, not a missing preview. |
| Commit failed | Keep the dialog open to retain the message, fix the reported Git error, and retry; reopen if HEAD changed. |
| No changes are listed | The popup still supports commit/stash checks and branch/worktree inspection. Check repository/path filters and the selected group. |
| OMP did not answer | Handoff adds a draft only. Inspect it in OMP and submit manually; check any bridge error before retrying. |
| Old keys or names remain after updating | Restart Neovim so cached plugin modules and personal mappings reload. |

The popup preserves unsaved buffers when closing or changing files; it is not a save operation. Explicit `:write` and custom edit commands are not a read-only sandbox. Live refresh is enabled by default; if disabled, reopen the popup to reread repository state (native Explorer also has `R`).

### Revisions and repository commands

Explicit revisions, `--staged`, history, file/directory comparisons, and inline status use native tab layouts with configurable keymaps. `:CodeDiff --inline`, or `diff.layout = "inline"`, opts out of the four-pane popup. Native views use `g?`/`:CodeDiff help`, not the popup's `h`/`c`/`z`/`b`/`w` layer. Their default revert mapping is `<leader>hr`; the personal dotfiles map it to `r`. `o` remains a diff-buffer handoff.

In the popup, Before is physically left of After. In native views, `diff.original_position` can move the original pane; the Revert baseline still means the **original** comparison version.

```vim
" Open the four-pane status popup
:CodeDiff

" Compare a revision with the working tree
:CodeDiff HEAD~5

" Compare a branch with the working tree
:CodeDiff main

" Compare a commit with the working tree
:CodeDiff abc123

" Compare two revisions (e.g. main vs HEAD)
:CodeDiff main HEAD

" Override layout for this invocation
:CodeDiff --inline
:CodeDiff main --side-by-side

" Operate on another repository without leaving the current one.
" Accepts the repository root or any path inside it; -C is an alias.
" Works with repository review, pull requests, and history.
:CodeDiff --repo ~/code/other-repo
:CodeDiff --repo ~/code/other-repo main
:CodeDiff -C ~/code/other-repo history
```

#### Staged Changes

Review only changes in the Git index:

```vim
" Index vs HEAD
:CodeDiff --staged

" Index vs another revision
:CodeDiff --staged HEAD~3
```

`--cached` is an alias for `--staged`. In the popup, choose the file in the separate Staged or Unstaged tree. Native status Explorer views instead support configurable `gS` to switch the current file between its staged and unstaged versions.

#### Pull Requests

Fetch and review a pull request without checking out its branch or changing the working tree:

```vim
:CodeDiff pr 512

" Fetch from another remote
:CodeDiff pr 512 --remote upstream

" Override the target branch
:CodeDiff pr 512 --base release/3.x

" Review only part of the pull request
:CodeDiff pr 512 -- lua/codediff

" Review a pull request in another local repository
:CodeDiff --repo ~/code/codediff.nvim pr 512
```

CodeDiff supports GitHub, GitLab, and Azure DevOps using the authentication already configured for the selected Git remote. No provider CLI is required.

CodeDiff stores fetched commits in private Git refs without creating a local branch. Remove cached refs when they are no longer needed:

```vim
:CodeDiff pr clean 512
:CodeDiff pr clean 512 --remote upstream
:CodeDiff pr clean --all
:CodeDiff pr clean --all --remote upstream
```

The cleanup commands also support `--repo` and `-C`.

#### Merge-base Comparisons

Review changes introduced since a branch diverged from its base:

```vim
" Merge base of main and HEAD vs working tree
:CodeDiff main...

" Merge base of main and HEAD vs HEAD
:CodeDiff main...HEAD

" Merge base of two branches vs the target branch
:CodeDiff develop...feature/new-ui
```

`<base>...` compares the merge base of `<base>` and `HEAD` with the working tree. `<base>...<target>` compares the merge base with `<target>`.

#### Scope by Path

Append `--` followed by one or more Git pathspecs relative to the repository root:

```vim
" Working-tree changes under a path
:CodeDiff -- src/api

" Changes between two revisions under a path
:CodeDiff v1.0.1 v1.0.2 -- modules/network

" Merge-base comparison under a path
:CodeDiff main... -- packages/ui
```

Multiple pathspecs and Git glob syntax are supported.

### Compare Files and Directories

#### Current File and Revisions

Compare the current file with a Git revision, or compare that file between two revisions:

```vim
" Revision vs working buffer
:CodeDiff file HEAD

" Two revisions
:CodeDiff file main HEAD

" Merge base of main and HEAD vs working buffer
:CodeDiff file main...
```

The current buffer must represent a file in a Git repository. With one revision, the working buffer remains editable and the revision content is read-only. With two revisions, both sides are read-only.

#### Two Files

Compare two files without Git:

```vim
:CodeDiff file file_a.txt file_b.txt
```

#### Two Directories

Compare two directories without Git:

```vim
" Explicit subcommand
:CodeDiff dir /path/to/dir1 /path/to/dir2

" Directories are also detected automatically
:CodeDiff ~/project-v1 ~/project-v2
```

The Explorer lists files as Added (A), Deleted (D), or Modified (M). Select a file to review its diff.

### Review History

By default, history shows the latest 100 non-merge commits. Expand a commit to see its changed files, then select a file to compare the commit with its parent.

```vim
" Open recent history
:CodeDiff history

" Review a commit range
:CodeDiff history HEAD~10..HEAD
:CodeDiff history origin/main..HEAD

" Limit history to the current file or another file
:CodeDiff history %
:CodeDiff history HEAD~10..HEAD path/to/file.lua

" Show the selected range from oldest to newest
:CodeDiff history origin/main..HEAD --reverse

" Compare each selected commit with the working tree
:CodeDiff history origin/main..HEAD --base WORKING

" Show commits that changed the selected lines
:'<,'>CodeDiff history
:'<,'>CodeDiff history HEAD~10..HEAD
```

`--reverse` (or `-r`) shows commits from oldest to newest. `--base <revision>` (or `-b`) compares each commit with a fixed Git revision; use `WORKING` for the current working tree. When invoked with a visual range, history is limited to commits that changed the selected lines in the current file.

### Git Tool Integration

`--exit-on-close` exits Neovim when the CodeDiff session closes, which is useful for processes started by Git.

#### Merge Tool

Configure CodeDiff as a Git merge tool, then run `git mergetool` to resolve conflicts:

```bash
git config --global merge.tool codediff
git config --global mergetool.codediff.cmd 'nvim "$MERGED" -c "CodeDiff --exit-on-close merge \"$MERGED\""'
git mergetool
```

#### Diff Tool

Configure CodeDiff as a Git diff tool:

```bash
git config --global diff.tool codediff
git config --global difftool.codediff.cmd 'nvim "$LOCAL" "$REMOTE" +"CodeDiff --exit-on-close file $LOCAL $REMOTE"'
```

Then review uncommitted changes or compare revisions:

```bash
git difftool
git difftool main feature-branch
```

### Extend CodeDiff

#### Lua API

`require("codediff")` exposes the supported Lua API:

| Function | Description |
|----------|-------------|
| `setup(opts)` | Apply CodeDiff configuration |
| `next_hunk()` | Move to the next hunk |
| `prev_hunk()` | Move to the previous hunk |
| `next_file()` | Move to the next file, or the next commit in single-file history |
| `prev_file()` | Move to the previous file, or the previous commit in single-file history |

The navigation functions return `true` when navigation succeeds and `false` otherwise. Modules under `codediff.core` and `codediff.ui` are internal and are not part of the supported API.

#### User Autocmd Events

CodeDiff emits `User` autocmd events for view lifecycle changes:

| Event | When | Data |
|-------|------|------|
| `CodeDiffOpen` | When a CodeDiff view opens | `tabpage`, `mode` |
| `CodeDiffClose` | Before cleanup starts | `tabpage`, `mode` |
| `CodeDiffFileSelect` | When a file is selected in the Explorer | `tabpage`, `path`, `status` |

`mode` is one of `"explorer"`, `"standalone"`, or `"history"`.

<details>
<summary>Example: Disable cursorline in the CodeDiff tab</summary>

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffOpen",
  callback = function(event)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(event.data.tabpage)) do
      vim.wo[win].cursorline = false
    end
  end,
})
```

</details>

## Upgrading this fork

- The default `:CodeDiff` status workflow is now a same-tab popup. Revision/history/file/directory views remain native tabs; opt into native status with `--inline`.
- The popup uses the [fixed review controls](#review-controls). Old native keys such as `gS`, `g?`, `t`, and configured `<leader>h…` actions are not its control scheme. `gf` is a native-view action, not a popup shortcut.
- The old **Reject** label is now **Revert**. It restores the working-file hunk to its comparison baseline and does not unstage it.
- Rename custom `keymaps.view.discard_hunk` settings to `keymaps.view.revert_hunk`; the old key has no compatibility alias. This config controls the native mapping; popup `r` is fixed.
- `s` is stage/unstage inside review. Ctrl-s is help in the workspace, commit submission in the commit composer, and draft handoff in the OMP composer—not a universal save action.
- OMP is an optional, explicit draft handoff. Existing OMP proposal accept/reject commands have not been renamed.

After updating this fork or its personal configuration, restart Neovim. See the [current Git recipes](docs/git-integration.md) and [documentation index](docs/README.md); the development-history collection is not the current command reference.

## Development

Development requires CMake 3.15 or newer, a C11 compiler, Neovim, and Git. `CMakeLists.txt` is the source of truth for native builds.

### Build and Test

Build the native library and run its tests:

```bash
cmake -S . -B build
cmake --build build --config Release
ctest --test-dir build --output-on-failure -C Release
```

Run the Lua test suite or select a test layer:

```bash
./tests/run_tests.sh          # all tests
./tests/run_tests.sh e2e      # or: unit, integration
```

On Windows, use `tests\run_tests.cmd` with the same arguments. See [tests/README.md](tests/README.md) for test organization and fixtures.

Check Lua formatting:

```bash
stylua --check lua
```

Run one Lua spec:

```bash
./tests/run_tests.sh tests/unit/core/path_spec.lua
```

## Contributing

Contributions are welcome. Please include tests for behavioral changes and update user documentation when behavior changes.

## License

MIT
