-- Computes input-pane fillers and conflict regions.
local M = {}

local alignment = require("codediff.ui.conflict.merge.alignment")
local compute_mapping_alignments = alignment.compute_mapping_alignments
local get_alignments = alignment.get_alignments

function M.compute_merge_fillers(base_to_input1_diff, base_to_input2_diff, base_lines, input1_lines, input2_lines)
  -- Use VSCode's MappingAlignment.compute approach
  local mapping_alignments = compute_mapping_alignments(base_to_input1_diff.changes, base_to_input2_diff.changes)

  local all_left_fillers = {}
  local all_right_fillers = {}
  local left_total = 0
  local right_total = 0

  for _, ma in ipairs(mapping_alignments) do
    -- Get line alignments using VSCode's getAlignments
    local alignments = get_alignments(
      ma.base_range.start_line,
      ma.base_range.end_line,
      ma.output1_range.start_line,
      ma.output1_range.end_line,
      ma.output2_range.start_line,
      ma.output2_range.end_line,
      ma.inner1,
      ma.inner2
    )

    -- Convert alignments to fillers
    for _, a in ipairs(alignments) do
      if a.input1_line and a.input2_line then
        local left_adj = a.input1_line + left_total
        local right_adj = a.input2_line + right_total
        local mx = math.max(left_adj, right_adj)

        if mx - left_adj > 0 then
          table.insert(all_left_fillers, { after_line = a.input1_line - 1, count = mx - left_adj })
          left_total = left_total + (mx - left_adj)
        end
        if mx - right_adj > 0 then
          table.insert(all_right_fillers, { after_line = a.input2_line - 1, count = mx - right_adj })
          right_total = right_total + (mx - right_adj)
        end
      end
    end
  end

  return all_left_fillers, all_right_fillers
end

-- Compute fillers AND identify which changes are in conflict regions
-- A conflict region is where BOTH input1 and input2 have changes to the same base region
-- This matches VSCode's behavior of only highlighting conflicting changes
function M.compute_merge_fillers_and_conflicts(base_to_input1_diff, base_to_input2_diff, base_lines, input1_lines, input2_lines)
  -- Use VSCode's MappingAlignment.compute approach
  local mapping_alignments = compute_mapping_alignments(base_to_input1_diff.changes, base_to_input2_diff.changes)

  local all_left_fillers = {}
  local all_right_fillers = {}
  local left_total = 0
  local right_total = 0

  -- Track which changes are in conflict regions
  local conflict_left_changes = {}
  local conflict_right_changes = {}

  -- Track conflict blocks (for accept/reject actions)
  local conflict_blocks = {}

  for _, ma in ipairs(mapping_alignments) do
    -- A region is conflicting if BOTH sides have changes (inner1 and inner2 both non-empty)
    -- OR if both sides have changes (checked by looking at if the ranges differ from base)
    local has_left_changes = #ma.inner1 > 0 or (ma.output1_range.end_line - ma.output1_range.start_line) ~= (ma.base_range.end_line - ma.base_range.start_line)
    local has_right_changes = #ma.inner2 > 0 or (ma.output2_range.end_line - ma.output2_range.start_line) ~= (ma.base_range.end_line - ma.base_range.start_line)
    local is_conflict = has_left_changes and has_right_changes

    if is_conflict then
      -- Add to conflict blocks for action handling
      table.insert(conflict_blocks, ma)

      -- Collect the actual diff changes that fall within this alignment's base range
      for _, change in ipairs(base_to_input1_diff.changes or {}) do
        if change.original.start_line >= ma.base_range.start_line and change.original.end_line <= ma.base_range.end_line then
          table.insert(conflict_left_changes, change)
        end
      end
      for _, change in ipairs(base_to_input2_diff.changes or {}) do
        if change.original.start_line >= ma.base_range.start_line and change.original.end_line <= ma.base_range.end_line then
          table.insert(conflict_right_changes, change)
        end
      end
    end

    -- Get line alignments using VSCode's getAlignments
    local alignments = get_alignments(
      ma.base_range.start_line,
      ma.base_range.end_line,
      ma.output1_range.start_line,
      ma.output1_range.end_line,
      ma.output2_range.start_line,
      ma.output2_range.end_line,
      ma.inner1,
      ma.inner2
    )

    -- Convert alignments to fillers
    for _, a in ipairs(alignments) do
      if a.input1_line and a.input2_line then
        local left_adj = a.input1_line + left_total
        local right_adj = a.input2_line + right_total
        local mx = math.max(left_adj, right_adj)

        if mx - left_adj > 0 then
          table.insert(all_left_fillers, { after_line = a.input1_line - 1, count = mx - left_adj })
          left_total = left_total + (mx - left_adj)
        end
        if mx - right_adj > 0 then
          table.insert(all_right_fillers, { after_line = a.input2_line - 1, count = mx - right_adj })
          right_total = right_total + (mx - right_adj)
        end
      end
    end
  end

  return {
    left_fillers = all_left_fillers,
    right_fillers = all_right_fillers,
    conflict_blocks = conflict_blocks,
  }, conflict_left_changes, conflict_right_changes
end

-- Reuse the merge groups for all three base-relative diffs, including live Result.
function M.compute_grid_fillers(incoming_diff, current_diff, result_diff)
  local fillers = { {}, {}, {}, {} } -- Incoming, Current, Base, Result
  local totals = { 0, 0, 0, 0 }
  local function align(lines)
    local row = 0
    for side, line in ipairs(lines) do
      row = math.max(row, line + totals[side])
    end
    for side, line in ipairs(lines) do
      local count = row - line - totals[side]
      if count > 0 then
        fillers[side][#fillers[side] + 1] = { after_line = line - 1, count = count }
        totals[side] = totals[side] + count
      end
    end
  end
  for _, group in ipairs(compute_mapping_alignments(incoming_diff.changes, current_diff.changes, result_diff.changes)) do
    local base = group.base_range
    local ranges = { group.output1_range, group.output2_range, base, group.output3_range }
    align({ ranges[1].start_line, ranges[2].start_line, base.start_line, ranges[4].start_line })
    local anchors = {}
    for source = 1, 3 do
      local range = group["output" .. source .. "_range"]
      anchors[source] = {}
      for _, point in ipairs(get_alignments(base.start_line, base.end_line, range.start_line, range.end_line, base.start_line, base.end_line, group["inner" .. source], {})) do
        if point.base_line and point.input1_line and point.base_line > base.start_line and point.base_line < base.end_line then
          anchors[source][point.base_line] = point.input1_line
        end
      end
    end
    local common = {}
    for line in pairs(anchors[1]) do
      if anchors[2][line] and anchors[3][line] then
        common[#common + 1] = line
      end
    end
    table.sort(common)
    for _, line in ipairs(common) do
      align({ anchors[1][line], anchors[2][line], line, anchors[3][line] })
    end
    align({ ranges[1].end_line, ranges[2].end_line, base.end_line, ranges[4].end_line })
  end
  return fillers
end

return M
