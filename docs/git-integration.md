# Git workflows and comparison baselines

This is the current Git guide for Edward Astill's CodeDiff fork. Start with the [review walkthrough](../README.md#quick-start); use the [popup controls](../README.md#review-controls) or `:CodeDiff help` for keys. `:help codediff` is the installed manual.

## Choose the right view

| Goal | Command | Scope and layout |
| --- | --- | --- |
| Prepare a commit | `:CodeDiff` | Repository status: four-pane popup with separate Unstaged and Staged trees |
| Use native inline status | `:CodeDiff --inline` | Repository status in a native tab, with configurable native mappings |
| Compare the repository against an older revision | `:CodeDiff HEAD~1` | Native Explorer listing changed files, not just the current file |
| Inspect the index | `:CodeDiff --staged` | Native HEAD-versus-index comparison |
| Compare the current file with HEAD | `:CodeDiff file HEAD` | Native file diff; revision read-only, working buffer editable |
| Compare two revisions across the repository | `:CodeDiff main HEAD` | Native Explorer; both revisions read-only |
| Compare one file between revisions | `:CodeDiff file main HEAD` | Native file diff; both sides read-only |
| Browse recent commits | `:CodeDiff history` | Native history panel; selected commit compared with its parent |

The default popup requires the side-by-side layout. A global `diff.layout = "inline"` also selects native inline status; use `:CodeDiff --side-by-side` to request the popup for that invocation. Repository action dialogs (`c`, `z`, `b`, `w`) belong to the status popup, not arbitrary revision tabs.

**`:CodeDiff HEAD` is repository-wide.** Use `:CodeDiff file HEAD` when you mean the current file. An empty/scratch buffer is not valid for the `file` revision command; repository review can use the working directory or an explicit `--repo`.

Native tabs have configured keys and `g?`/`:CodeDiff help`. The popup has its own fixed review layer. The personal dotfiles bind Space d to the popup and native Revert to `r`; the plugin's generic native Revert default is `<leader>hr`. Do not assume another user's leader or native mappings match yours.

## HEAD, index, and working file

- **HEAD** is the checked-out commit, or an unborn branch before its first commit.
- **Index** is the staged snapshot that a commit records.
- **Working file** is the on-disk edit; an unsaved Neovim buffer can differ from it.

In the popup, selecting an **Unstaged** entry compares index → working file. Selecting a **Staged** entry compares HEAD → index. This is why the same file can occur in both trees.

A file/directory tree action uses its on-disk path. A diff-pane hunk action uses the selected displayed hunk; staging can include unsaved buffer text without writing the file. Save first when you want the disk, preview, and staged result to agree. Revert and stash refuse unsaved affected buffers rather than silently saving them.

### Unstage does not undo the edit

In the Staged tree, `s` unstages a file or directory. In its diff, `s` unstages just the cursor's hunk. The working file is unchanged, so the change normally reappears under Unstaged.

Use the default popup or native inline **status** for staging decisions. An arbitrary revision comparison is not the same as the normal index-versus-working-file view; use it to inspect the chosen baseline, not as a substitute for reviewing the next commit's index.

### Revert does not unstage

In a diff pane, `r` restores the selected hunk in the working file to the **original comparison version** and asks for confirmation. It never writes the index. In the popup that original version is Before, physically to the left of After; native layouts can reposition the original pane.

For example, suppose one hunk is version **A** in HEAD, version **B** in the index, and also **B** in the working file:

1. Open that hunk from **Staged** and Revert it. The working file becomes **A**; the index remains **B**.
2. The staged change is still ready to commit. A new unstaged difference now compares index **B** with working file **A**.
3. To remove the staged change too, select that same hunk in **Staged** and unstage it. Do not unstage the whole file unless you intend to remove its other staged hunks too.

Reverting the new **Unstaged** difference instead would restore the index's **B** to the working file. Revert follows the comparison baseline; it does not always mean HEAD.

For `:CodeDiff HEAD~1` or `:CodeDiff file HEAD~1`, Revert uses that older revision rather than HEAD. It preserves the index and unrelated hunks. It does not edit immutable commit-to-commit comparisons, non-Git comparisons, or merge conflicts.

Revert refuses stale comparisons, changed file/index state, renamed comparisons, overlapping working edits it cannot match safely, and unsaved target buffers. Save or resolve the discrepancy outside review, then reopen/select again. Discarded unstaged edits may not be recoverable by Git.

### File and directory actions are broader than a hunk

Use `s` on a file row for the entire file, or a folder row for its directory path. Folder actions can include changes hidden by presentation filters. `S` and `U` from either tree operate on the whole repository, not just visible rows. Inspect the resulting Staged tree before committing.

## Finish or set aside the work

The full procedures live in the review guide:

- [Commit staged changes](../README.md#commit-staged-changes): `c` shows only the current HEAD and message; Ctrl-s commits the existing index. It never auto-stages. Empty index/message, changed HEAD, and Git failures retain the draft while its dialog stays open.
- [Stash tracked changes](../README.md#stash-tracked-changes): `z` confirms a normal `git stash push`, including staged and unstaged tracked changes. Untracked files remain. Unsaved tracked buffers or an unborn/changed HEAD block it. Restoring a stash is a Git/client operation; there is no pop/apply picker here.
- [Inspect local branches and worktrees](../README.md#inspect-branches-and-worktrees): separate read-only `b` and `w` popups; no checkout/create/delete actions.
- [Send a hunk to OMP](../README.md#send-a-hunk-to-omp): `o` captures only the selected hunk and offers an optional message. Ctrl-s appends to the selected OMP session's draft, without automatic submission or Git changes. Check the selected OMP session, especially when it belongs to another project.

## Work in another repository or limit the listing

```vim
" The path may be the repository root or a path inside it
:CodeDiff --repo ~/code/other-repo
:CodeDiff -C ~/code/other-repo --staged
:CodeDiff -C ~/code/other-repo history

" Git pathspecs after -- are relative to the selected repository root
:CodeDiff -- src/api
:CodeDiff main HEAD -- src/api tests/api
:CodeDiff --repo ~/code/other-repo main... -- packages/ui
```

Filters control the comparison/listing, not a safety boundary for repository-wide staging, committing, or stashing. Check which repository the operation targets and what is already staged.

## Compare revisions and branches

```vim
" Revision versus working tree (repository-wide)
:CodeDiff HEAD~5
:CodeDiff main
:CodeDiff origin/main
:CodeDiff v1.0.0
:CodeDiff abc123

" Two revisions; neither side is the working file
:CodeDiff main HEAD

" Index versus a chosen revision (--cached aliases --staged)
:CodeDiff --staged HEAD~3

" Merge base of main and HEAD, compared with the working tree
:CodeDiff main...

" Merge base of two branches, compared with the target branch
:CodeDiff develop...feature/new-ui
```

A missing file on one side can be a legitimate addition/deletion. Invalid or unavailable refs still need to be fetched/corrected. Do not confuse a one-sided diff with a blank or stale preview.

## Review file history

```vim
" Recent commits, each compared with its parent
:CodeDiff history
:CodeDiff history %

" Limit the commit range or file, and optionally reverse its order
:CodeDiff history origin/main..HEAD
:CodeDiff history HEAD~10..HEAD path/to/file.lua --reverse

" Compare each selected commit with the current working tree or a fixed ref
:CodeDiff history --base WORKING
:CodeDiff history --base HEAD
:CodeDiff history origin/main..HEAD --base WORKING %
```

Expand a commit, then choose its file. `--base WORKING` is different from comparing two immutable revisions. See the [history reference](../README.md#review-history) for visual line-range history and additional flags.

## Pull requests and merge conflicts

Use `:CodeDiff pr <number>` to fetch and compare a pull request without checking out its branch. Remote/base/path filters and private-ref cleanup are documented in the [pull-request reference](../README.md#pull-requests).

Merge conflicts use a Result pane and conflict-resolution mappings, not the normal Revert action. Consult `:CodeDiff help` for the active view and the [Git merge-tool configuration](../README.md#merge-tool).

## Troubleshooting and supported API

- Save/read-only errors in Explorer/help buffers: leave review and edit the real file; do not write the scratch pane.
- A stale or missing hunk: select a file and move onto a diff hunk; reopen/refresh if the comparison changed. Live refresh is enabled by default.
- Unexpected keys: distinguish popup, native view, and child dialog; use context-aware `:CodeDiff help`.
- Old behavior after updating: restart Neovim, and migrate custom `discard_hunk` settings to `revert_hunk` as described in the [upgrade notes](../README.md#upgrading-this-fork).

The supported Lua entry point is `require("codediff")`: setup and navigation functions are listed in the [public API reference](../README.md#lua-api). Internal modules under `codediff.core`/`codediff.ui` are not a stable scripting API. Old `vscode-diff.git`, `codediff.git`, and standalone render snippets in historical notes are not current integration recipes.
