# Documentation

## Current user guides

- **[Quick start](../README.md#quick-start)** — Open review, stage a hunk, inspect the index, and commit.
- **[Review workspace and controls](../README.md#review-workspace)** — Four-pane popup, selection, scoped keys, repository dialogs, and normal editing restoration.
- **[Stage, unstage, and revert](../README.md#stage-unstage-and-revert)** — What changes in the index versus the working file.
- **[OMP handoff](../README.md#send-a-hunk-to-omp)** — Selected hunk plus optional message; draft-only, never auto-submit.
- **[git-integration.md](git-integration.md)** — Choose the correct comparison, handle mixed staged/unstaged changes, and use revision/history commands.
- **[Neovim help](../doc/codediff.txt)** — Installed manual: `:help codediff`; popup shortcut lookup: `:CodeDiff help`.
- **[Upgrade notes](../README.md#upgrading-this-fork)** — Popup/native differences and the `discard_hunk` → `revert_hunk` migration.
- **[performance.md](performance.md)** — Timeout control for large files and two-phase diff computation.

## Building & Contributing

- **[BUILD.md](BUILD.md)** — Build system guide: CMake, Makefile targets, standalone scripts for users without CMake
- **[VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md)** — Semantic versioning workflow and automated version bumping
- **[dependency-distribution.md](dependency-distribution.md)** — How OpenMP/libgomp is bundled so users don't need system packages

## Algorithm Internals

- **[filler-line-algorithm.md](filler-line-algorithm.md)** — How filler lines align side-by-side views, matching VSCode's `computeRangeAlignment()`
- **[DIFF_NOTATION.md](DIFF_NOTATION.md)** — Line-level (`seq1[start,end)`) and character-level (`L:C`) notation reference
- **[rendering-quick-reference.md](rendering-quick-reference.md)** — The 3-step rendering process: line highlights → char highlights → filler lines

## Development History

These are archived implementation notes, not the current UI, keybinding, module, or command contract. They may describe old names, layouts, and features that have since shipped. Use the guides above for this fork's current behavior.

- **[development/](development/)** — Algorithm development, parity evaluations, and earlier architecture decisions.
