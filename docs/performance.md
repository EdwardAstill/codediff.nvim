# Performance and timeout control

`diff.max_computation_time_ms` controls native diff-algorithm timeouts. The default is `5000` milliseconds.

```lua
require("codediff").setup({
  diff = {
    max_computation_time_ms = 5000,
  },
})
```

## What the timeout covers

The engine computes line-level differences, then refines changed regions at character level. Individual algorithm calls receive the configured timeout; they do not share a single end-to-end wall-clock budget. Timeout checks are periodic and use the native process clock.

A timed-out algorithm returns a coarser changed range and reports `hit_timeout`; it does not establish that the files are identical. Lower timeouts can therefore reduce alignment and character-level detail, not just speed up the same result.

Git queries, file reads, Lua rendering, and multiple comparisons in a merge grid add work outside an individual algorithm call. A `1000` setting is **not** a guarantee that opening or refreshing a view completes within one second.

## Choosing a value

Keep the default unless large comparisons are noticeably slow. To favor responsiveness, try a smaller value and inspect whether the resulting detail remains useful:

```lua
require("codediff").setup({
  diff = {
    max_computation_time_ms = 1000,
  },
})
```

Increase the value again if important distinctions are rendered too coarsely. The tradeoff depends on file contents, edit size, hardware, and build options; there is no fixed quality percentage or universal speedup for a given timeout.

## Implementation references

- [`lua/codediff/core/diff.lua`](../lua/codediff/core/diff.lua) supplies the option to the native library.
- [`libvscode-diff/default_lines_diff_computer.c`](../libvscode-diff/default_lines_diff_computer.c) coordinates line comparisons and character refinement.
- [`libvscode-diff/src/myers.c`](../libvscode-diff/src/myers.c) implements algorithm timeout checks and coarse fallback ranges.
- [Configuration reference](../README.md#configuration) lists the remaining rendering options.
