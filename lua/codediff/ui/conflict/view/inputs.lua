-- Renders the two conflict input panes against their merge base.
local M = {}

local core = require("codediff.ui.core")
local diff_module = require("codediff.core.diff")

-- Validated stage snapshots must not trigger another mutable index read.
function M.prepare_snapshot(session_config, side)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nowrite", "hide"
  vim.bo[buf].swapfile = false
  local inputs = session_config.merge_inputs
  local lines = side == "original" and inputs.incoming_lines or inputs.current_lines
  require("codediff.core.virtual_file").set_content(buf, lines, session_config[side].relative)
  return { bufnr = buf, needs_edit = false, snapshot = true }
end

-- Conflict mode rendering: Both buffers show diff against base with alignment
-- Left buffer (:3: theirs/incoming) and Right buffer (:2: ours/current)
-- Both show green highlights indicating changes from base (:1:)
-- Filler lines are inserted to align corresponding changes
-- @param original_buf number: Left buffer (incoming :3:)
-- @param modified_buf number: Right buffer (current :2:)
-- @param base_lines table: Base content (:1:)
-- @param original_lines table: Incoming content (:3:)
-- @param modified_lines table: Current content (:2:)
-- @param original_win number: Left window
-- @param modified_win number: Right window
-- @param auto_scroll_to_first_hunk boolean: Whether to scroll to first change
-- @return table: { base_to_original_diff, base_to_modified_diff }
function M.compute_and_render_conflict(original_buf, modified_buf, base_lines, original_lines, modified_lines, original_win, modified_win, auto_scroll_to_first_hunk)
  local diff_options = require("codediff.ui.view.render").diff_options()

  -- Compute base -> original (incoming) diff
  local base_to_original_diff = diff_module.compute_diff(base_lines, original_lines, diff_options)
  if not base_to_original_diff then
    vim.notify("Failed to compute base->incoming diff", vim.log.levels.ERROR)
    return nil
  end

  -- Compute base -> modified (current) diff
  local base_to_modified_diff = diff_module.compute_diff(base_lines, modified_lines, diff_options)
  if not base_to_modified_diff then
    vim.notify("Failed to compute base->current diff", vim.log.levels.ERROR)
    return nil
  end

  -- Render merge view with alignment and filler lines
  local render_result = core.render_merge_view(original_buf, modified_buf, base_to_original_diff, base_to_modified_diff, base_lines, original_lines, modified_lines)

  -- Four-way vertical linking is installed after Base and Result are available.
  if original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
    vim.wo[original_win].wrap = false
    vim.wo[modified_win].wrap = false
    vim.wo[original_win].scrollbind = false
    vim.wo[modified_win].scrollbind = false

    -- Scroll to first change in either buffer
    if auto_scroll_to_first_hunk then
      local first_line = nil
      if #base_to_original_diff.changes > 0 then
        first_line = base_to_original_diff.changes[1].modified.start_line
      elseif #base_to_modified_diff.changes > 0 then
        first_line = base_to_modified_diff.changes[1].modified.start_line
      end

      if first_line then
        pcall(vim.api.nvim_win_set_cursor, original_win, { first_line, 0 })
        pcall(vim.api.nvim_win_set_cursor, modified_win, { first_line, 0 })
        if vim.api.nvim_win_is_valid(modified_win) then
          vim.api.nvim_set_current_win(modified_win)
          vim.cmd("normal! zz")
        end
      end
    end
  end

  return {
    base_to_original_diff = base_to_original_diff,
    base_to_modified_diff = base_to_modified_diff,
    conflict_blocks = render_result and render_result.conflict_blocks or {},
    -- Pass through per-side content so Result can be auto-merged without
    -- re-fetching buffers.
    original_lines = original_lines,
    modified_lines = modified_lines,
  }
end

return M
