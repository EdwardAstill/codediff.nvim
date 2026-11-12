-- Merge alignment module for 3-way merge view
-- Exact port of VSCode's lineAlignment.ts
local M = {}

-- Position helper
local function pos_compare(a, b)
  if a.line < b.line then
    return -1
  end
  if a.line > b.line then
    return 1
  end
  if a.column < b.column then
    return -1
  end
  if a.column > b.column then
    return 1
  end
  return 0
end

-- TextLength helper
local function text_length(lines, columns)
  return { lines = lines, columns = columns }
end

local function text_length_is_zero(tl)
  return tl.lines == 0 and tl.columns == 0
end

local function text_length_is_greater_than(a, b)
  if a.lines > b.lines then
    return true
  end
  if a.lines < b.lines then
    return false
  end
  return a.columns > b.columns
end

local function length_between_positions(from, to)
  if from.line == to.line then
    return text_length(0, to.column - from.column)
  end
  return text_length(to.line - from.line, to.column - 1)
end

local function add_length(pos, length)
  if length.lines == 0 then
    return { line = pos.line, column = pos.column + length.columns }
  end
  return { line = pos.line + length.lines, column = length.columns + 1 }
end

-- Convert inner diffs to equal range mappings (the gaps between diffs)
-- This is VSCode's toEqualRangeMappings function
local function to_equal_range_mappings(inner_diffs, input_start, input_end, output_start, output_end)
  local result = {}

  local equal_input_start = { line = input_start, column = 1 }
  local equal_output_start = { line = output_start, column = 1 }

  for _, d in ipairs(inner_diffs or {}) do
    -- The equal range is from current position to start of this diff
    local equal_input_end = { line = d.original.start_line, column = d.original.start_col }
    local equal_output_end = { line = d.modified.start_line, column = d.modified.start_col }

    if pos_compare(equal_input_start, equal_input_end) < 0 then
      table.insert(result, {
        input_start = equal_input_start,
        input_end = equal_input_end,
        output_start = equal_output_start,
        output_end = equal_output_end,
      })
    end

    -- Move past this diff
    equal_input_start = { line = d.original.end_line, column = d.original.end_col }
    equal_output_start = { line = d.modified.end_line, column = d.modified.end_col }
  end

  -- Final equal range to end
  local equal_input_end = { line = input_end, column = 1 }
  local equal_output_end = { line = output_end, column = 1 }

  if pos_compare(equal_input_start, equal_input_end) < 0 then
    table.insert(result, {
      input_start = equal_input_start,
      input_end = equal_input_end,
      output_start = equal_output_start,
      output_end = equal_output_end,
    })
  end

  return result
end

-- Find common equal ranges between input1 and input2 relative to base
-- This is VSCode's splitUpCommonEqualRangeMappings function
local function split_up_common_equal_range_mappings(equal_ranges_1, equal_ranges_2)
  local result = {}
  local events = {}

  for _, rm in ipairs(equal_ranges_1) do
    table.insert(events, { input = 1, start = true, input_pos = rm.input_start, output_pos = rm.output_start })
    table.insert(events, { input = 1, start = false, input_pos = rm.input_end, output_pos = rm.output_end })
  end
  for _, rm in ipairs(equal_ranges_2) do
    table.insert(events, { input = 2, start = true, input_pos = rm.input_start, output_pos = rm.output_start })
    table.insert(events, { input = 2, start = false, input_pos = rm.input_end, output_pos = rm.output_end })
  end

  -- Sort by position, with end events before start events at the same position
  -- This ensures continuous coverage when an equal range ends and another starts at the same point
  table.sort(events, function(a, b)
    local cmp = pos_compare(a.input_pos, b.input_pos)
    if cmp ~= 0 then
      return cmp < 0
    end
    -- At same position, end events (start=false) come before start events (start=true)
    if a.start ~= b.start then
      return not a.start
    end
    return false
  end)

  local starts = { nil, nil }
  local last_input_pos = nil

  for _, event in ipairs(events) do
    if last_input_pos and (starts[1] or starts[2]) then
      local length = length_between_positions(last_input_pos, event.input_pos)
      if not text_length_is_zero(length) then
        table.insert(result, {
          input_pos = last_input_pos,
          length = length,
          output1_pos = starts[1],
          output2_pos = starts[2],
        })
        if starts[1] then
          starts[1] = add_length(starts[1], length)
        end
        if starts[2] then
          starts[2] = add_length(starts[2], length)
        end
      end
    end
    starts[event.input] = event.start and event.output_pos or nil
    last_input_pos = event.input_pos
  end

  return result
end

-- Get alignments - exact port of VSCode's getAlignments
function M.get_alignments(base_start, base_end, input1_start, input1_end, input2_start, input2_end, input1_inner_diffs, input2_inner_diffs)
  -- Get equal range mappings for both inputs
  local equal_ranges_1 = to_equal_range_mappings(input1_inner_diffs, base_start, base_end, input1_start, input1_end)
  local equal_ranges_2 = to_equal_range_mappings(input2_inner_diffs, base_start, base_end, input2_start, input2_end)

  -- Find common equal ranges
  local common_ranges = split_up_common_equal_range_mappings(equal_ranges_1, equal_ranges_2)

  local result = {}
  table.insert(result, { input1_line = input1_start - 1, base_line = base_start - 1, input2_line = input2_start - 1 })

  local function is_full_sync(a)
    return a.input1_line ~= nil and a.base_line ~= nil and a.input2_line ~= nil
  end

  for _, m in ipairs(common_ranges) do
    local la = {
      input1_line = m.output1_pos and m.output1_pos.line,
      base_line = m.input_pos.line,
      input2_line = m.output2_pos and m.output2_pos.line,
    }

    local is_fs = is_full_sync(la)
    local should_add = true

    if is_fs then
      local is_new = true
      for _, r in ipairs(result) do
        if is_full_sync(r) and (r.input1_line == la.input1_line or r.base_line == la.base_line or r.input2_line == la.input2_line) then
          is_new = false
          break
        end
      end
      if is_new then
        -- Remove half syncs
        local new_result = {}
        for _, r in ipairs(result) do
          if not (r.input1_line == la.input1_line or r.base_line == la.base_line or r.input2_line == la.input2_line) then
            table.insert(new_result, r)
          end
        end
        result = new_result
      end
      should_add = is_new
    else
      for _, r in ipairs(result) do
        if (la.input1_line and r.input1_line == la.input1_line) or (la.base_line and r.base_line == la.base_line) or (la.input2_line and r.input2_line == la.input2_line) then
          should_add = false
          break
        end
      end
    end

    if should_add then
      table.insert(result, la)
    elseif text_length_is_greater_than(m.length, text_length(1, 0)) then
      table.insert(result, {
        input1_line = m.output1_pos and (m.output1_pos.line + 1),
        base_line = m.input_pos.line + 1,
        input2_line = m.output2_pos and (m.output2_pos.line + 1),
      })
    end
  end

  -- Final alignment
  local final = { input1_line = input1_end, base_line = base_end, input2_line = input2_end }
  local filtered = {}
  for _, r in ipairs(result) do
    if not (r.input1_line == final.input1_line and r.base_line == final.base_line and r.input2_line == final.input2_line) then
      table.insert(filtered, r)
    end
  end
  table.insert(filtered, final)

  return filtered
end

-- Group overlapping base changes across the inputs and, optionally, Result.
function M.compute_mapping_alignments(changes1, changes2, changes3)
  local sources = { changes1 or {}, changes2 or {} }
  if changes3 then
    sources[3] = changes3
  end
  local combined, current_diffs, delta_from_base = {}, {}, {}
  for source, changes in ipairs(sources) do
    current_diffs[source], delta_from_base[source] = {}, 0
    for _, change in ipairs(changes) do
      combined[#combined + 1] = { source = source, diff = change }
    end
  end
  table.sort(combined, function(a, b)
    if a.diff.original.start_line == b.diff.original.start_line then
      return a.diff.original.end_line < b.diff.original.end_line
    end
    return a.diff.original.start_line < b.diff.original.start_line
  end)
  local alignments = {}
  local current_base_range
  local function push_and_reset()
    if not current_base_range then
      return
    end
    local group = { base_range = current_base_range }
    for source, changes in ipairs(current_diffs) do
      local first, last = changes[1], changes[#changes]
      local start_line = current_base_range.start_line + delta_from_base[source]
      local end_line = current_base_range.end_line + delta_from_base[source]
      if first then
        start_line = first.modified.start_line + current_base_range.start_line - first.original.start_line
        end_line = last.modified.end_line + current_base_range.end_line - last.original.end_line
      end
      group["output" .. source .. "_range"] = { start_line = start_line, end_line = end_line }
      local inner = {}
      for _, change in ipairs(changes) do
        for _, mapping in ipairs(change.inner_changes or {}) do
          inner[#inner + 1] = mapping
        end
      end
      group["inner" .. source] = inner
      group["has_input" .. source] = first ~= nil
      current_diffs[source] = {}
    end
    alignments[#alignments + 1] = group
  end

  for _, item in ipairs(combined) do
    local c = item.diff
    local base_range = { start_line = c.original.start_line, end_line = c.original.end_line }

    -- Check if this change touches/overlaps with current range
    if current_base_range and base_range.start_line <= current_base_range.end_line then
      -- Extend current range
      current_base_range.end_line = math.max(current_base_range.end_line, base_range.end_line)
    else
      -- Push previous group and start new one
      push_and_reset()
      current_base_range = { start_line = base_range.start_line, end_line = base_range.end_line }
    end

    -- Update delta and add to current diffs
    -- delta = outputRange.end - inputRange.end (cumulative offset at end of change)
    delta_from_base[item.source] = c.modified.end_line - c.original.end_line
    table.insert(current_diffs[item.source], c)
  end

  -- Push final group
  push_and_reset()

  return alignments
end

return M
