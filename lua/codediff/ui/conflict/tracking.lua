-- Explicit approvals belong to the working buffer, not to a view or its text.
local M = {}
local tracking_ns = vim.api.nvim_create_namespace("codediff-conflict-tracking")
M.tracking_ns = tracking_ns
M.result_signs_ns = vim.api.nvim_create_namespace("codediff-result-signs")
local states, paths = {}, {}
local pending_action

function M.run_repeatable_action()
  if pending_action then
    pending_action()
  end
end

function M.make_repeatable(fn)
  return function()
    pending_action = fn
    vim.go.operatorfunc = "v:lua.require'codediff.ui.conflict'.run_repeatable_action"
    return "g@l"
  end
end

local function undo_sequence(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
end

function M.get_range(bufnr, block)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not block.extmark_id then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, tracking_ns, block.extmark_id, { details = true })
  if #mark < 3 or mark[3].end_row == nil or mark[3].invalid then
    return nil
  end
  return mark[1], mark[3].end_row
end

local function set_range(bufnr, block, first, last)
  block.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, tracking_ns, first, 0, {
    id = block.extmark_id,
    end_row = last,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = false,
  })
  block.first, block.last = first, last
end

local function snapshot(state)
  local saved = {}
  for i, block in ipairs(state.conflict_blocks) do
    local first, last = M.get_range(state.result_bufnr, block)
    block.first, block.last = first, last
    saved[i] = { resolved = block.resolved, accepted = block.accepted, first = first, last = last, ambiguous = block.ambiguous }
  end
  state.sequence = undo_sequence(state.result_bufnr)
  state.history[state.sequence] = saved
  state.tick = vim.api.nvim_buf_get_changedtick(state.result_bufnr)
  state.dirty = {}
end

local function notify(state)
  if state.notification_pending then
    return
  end
  state.notification_pending = true
  vim.schedule(function()
    state.notification_pending = nil
    if states[state.result_bufnr] ~= state then
      return
    end
    M.sync(state)
    if state.needs_render then
      state.needs_render = nil
      require("codediff.ui.refresh").refresh_result_now(state.result_bufnr)
    end
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeDiffConflictChanged",
      modeline = false,
      data = { path = state.path, bufnr = state.result_bufnr },
    })
  end)
end

function M.sync(session)
  local state = states[session.result_bufnr]
  if not state or state.applying or not vim.api.nvim_buf_is_valid(state.result_bufnr) then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(state.result_bufnr)
  if state.tick == tick then
    return
  end
  local sequence = undo_sequence(state.result_bufnr)
  local saved = sequence ~= state.sequence and state.history[sequence] or nil
  if saved then
    for i, block in ipairs(state.conflict_blocks) do
      local item = saved[i]
      block.resolved, block.accepted = item.resolved, item.accepted
      block.ambiguous = item.ambiguous
      if item.first then
        set_range(state.result_bufnr, block, item.first, item.last)
      end
    end
  else
    for i, block in ipairs(state.conflict_blocks) do
      if state.dirty[i] then
        block.resolved, block.accepted = false, nil
      end
    end
  end
  snapshot(state)
end

local function register(bufnr, blocks)
  local state = { result_bufnr = bufnr, conflict_blocks = blocks, history = {}, dirty = {} }
  states[bufnr] = state
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    state.path = vim.fn.fnamemodify(name, ":p")
    paths[state.path] = state
  end
  snapshot(state)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first, last, new_last)
      if states[bufnr] ~= state then
        return true
      end
      if state.applying then
        return
      end
      state.touched = true
      state.needs_render = true
      for i, block in ipairs(blocks) do
        local start, finish = block.first, block.last
        if start then
          local overlaps = first == last and first >= start and (first < finish or start == finish and first == start)
            or first < finish and last > start
            or start == finish and first <= start and last > start
          if overlaps then
            state.dirty[i] = true
            if first < start or last > finish then
              block.ambiguous = true
            end
          end
          local delta = new_last - last
          local new_start = start
          if start >= last and (first < last or start > first) then
            new_start = start + delta
          elseif start > first then
            new_start = first
          end
          local new_end = finish
          if finish > last or finish == last and (first < last or finish == start) then
            new_end = finish + delta
          elseif finish > first then
            new_end = new_last
          end
          set_range(bufnr, block, new_start, math.max(new_start, new_end))
        end
      end
      notify(state)
    end,
    on_reload = function()
      state.history, state.touched = {}, true
      state.needs_render = true
      for i, block in ipairs(blocks) do
        state.dirty[i] = true
        block.resolved, block.accepted, block.ambiguous = false, nil, true
      end
      notify(state)
    end,
  })
  local group = vim.api.nvim_create_augroup("CodeDiffConflictState_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    buffer = bufnr,
    callback = function(args)
      M.sync(state)
      if args.event == "BufWritePost" and state.path then
        local file = io.open(state.path, "rb")
        if file then
          local bytes = file:read("*a")
          file:close()
          state.saved_hash = bytes and vim.fn.sha256(bytes) or nil
        end
      end
      notify(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      states[bufnr] = nil
      if state.path and paths[state.path] == state then
        paths[state.path] = nil
      end
    end,
  })
  return state
end

function M.initialize_tracking(bufnr, blocks)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if states[bufnr] then
    return
  end
  for _, block in ipairs(blocks) do
    local range = block.result_range or block.base_range
    block.resolved = false
    set_range(bufnr, block, range.start_line - 1, range.end_line - 1)
  end
  register(bufnr, blocks)
end

local function normalized_markers(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:gsub("^(<<<<<<<) .*$", "%1"):gsub("^(|||||||) .*$", "%1"):gsub("^(>>>>>>>) .*$", "%1")
  end
  return out
end

-- Only an exact freshly generated Git conflict may be replaced automatically.
local function fresh_git_result(bufnr, base, incoming, current, existing)
  if vim.bo[bufnr].modified or vim.api.nvim_buf_call(bufnr, function() return vim.fn.undotree().seq_last end) ~= 0 then
    return false
  end
  local files = { vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname() }
  local ok, matched = pcall(function()
    for i, lines in ipairs({ current, base, incoming }) do
      if vim.fn.writefile(lines, files[i]) ~= 0 then
        return false
      end
    end
    local expected = normalized_markers(existing)
    for _, style in ipairs({ "", "--diff3", "--zdiff3" }) do
      local command = { "git", "merge-file", "-p" }
      if style ~= "" then
        command[#command + 1] = style
      end
      vim.list_extend(command, files)
      local result = vim.system(command, { text = true }):wait()
      if result.code >= 0 and result.code <= 127 and result.stdout and result.stdout ~= "" then
        local lines = vim.split(result.stdout:gsub("\n$", ""), "\n", { plain = true })
        if vim.deep_equal(expected, normalized_markers(lines)) then
          return true
        end
      end
    end
    return false
  end)
  for _, file in ipairs(files) do
    vim.fn.delete(file)
  end
  return ok and matched
end

local function project_ranges(seed, existing, blocks)
  local changes = vim.diff(table.concat(seed, "\n") .. "\n", table.concat(existing, "\n") .. "\n", { result_type = "indices", algorithm = "histogram" })
  local function boundary(row, ending)
    local offset = 0
    for _, change in ipairs(changes) do
      local a, count, b, size = unpack(change)
      a, b = a - (count > 0 and 1 or 0), b - (size > 0 and 1 or 0)
      if row < a or row == a and not ending then
        break
      end
      if row < a + count or count == 0 and row == a then
        return ending and b + size or b
      end
      offset = b + size - a - count
    end
    return row + offset
  end
  for _, block in ipairs(blocks) do
    local range = block.result_range
    block.projected = { boundary(range.start_line - 1, false), boundary(range.end_line - 1, true) }
    for _, change in ipairs(changes) do
      local start, size = change[1] - (change[2] > 0 and 1 or 0), change[2]
      local first, last = range.start_line - 1, range.end_line - 1
      if start < last and start + size > first and (start < first or start + size > last) then
        block.ambiguous = true
      end
    end
  end
  for i, block in ipairs(blocks) do
    for j = i + 1, #blocks do
      local other = blocks[j]
      if block.projected[2] > other.projected[1] then
        block.ambiguous, other.ambiguous = true, true
      end
    end
  end
end

local function forget(state)
  states[state.result_bufnr] = nil
  if state.path then
    paths[state.path] = nil
  end
  if vim.api.nvim_buf_is_valid(state.result_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.result_bufnr, tracking_ns, 0, -1)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffConflictState_" .. state.result_bufnr)
end

function M.bind_result(session, base_lines, diffs)
  local bufnr = session.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "No valid Result buffer"
  end
  local identity = session.merge_inputs and session.merge_inputs.identity or session.merge_input_identity
  local state = states[bufnr]
  local reseed = false
  if state then
    M.sync(state)
    if state.merge_base_lines and (not vim.deep_equal(base_lines, state.merge_base_lines)
      or not vim.deep_equal(diffs.original_lines, state.incoming_lines)
      or not vim.deep_equal(diffs.modified_lines, state.current_lines)
      or identity and state.merge_input_identity and identity ~= state.merge_input_identity) then
      if M.has_work(state) then
        return false, "Merge inputs changed; preserving Result. Finish or explicitly discard this working buffer before loading different inputs."
      end
      forget(state)
      state, reseed = nil, true
    end
  end
  if not state then
    local seed, blocks = require("codediff.ui.conflict.merge").compute_auto_merged_result(
      diffs.base_to_original_diff, diffs.base_to_modified_diff, base_lines, diffs.original_lines, diffs.modified_lines
    )
    local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local fresh = reseed or fresh_git_result(bufnr, base_lines, diffs.original_lines, diffs.modified_lines, existing)
    if fresh then
      if not vim.deep_equal(existing, #seed > 0 and seed or { "" }) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, seed)
      end
      existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    project_ranges(seed, existing, blocks)
    for _, block in ipairs(blocks) do
      block.resolved = false
      set_range(bufnr, block, block.projected[1], block.projected[2])
      block.projected = nil
    end
    state = register(bufnr, blocks)
    state.touched = not fresh
    state.result_base_lines, state.merge_base_lines = seed, vim.deepcopy(base_lines)
    state.incoming_lines, state.current_lines = vim.deepcopy(diffs.original_lines), vim.deepcopy(diffs.modified_lines)
    state.merge_input_identity = identity
  end
  session.result_base_lines = state.result_base_lines or session.result_base_lines
  session.merge_base_lines = state.merge_base_lines or base_lines
  session.conflict_blocks = state.conflict_blocks
  return true
end

function M.forget_result(path)
  local state = paths[vim.fn.fnamemodify(path, ":p")]
  if not state then
    return
  end
  forget(state)
end

function M.has_work(session)
  M.sync(session)
  local state = states[session.result_bufnr]
  if not state then
    return false
  end
  if state.touched then
    return true
  end
  for _, block in ipairs(state.conflict_blocks) do
    if block.resolved then
      return true
    end
  end
  return false
end

function M.get_state(path)
  local state = paths[vim.fn.fnamemodify(path, ":p")]
  if state then
    M.sync(state)
  end
  return state
end

function M.unresolved_count(session)
  M.sync(session)
  local count = 0
  for _, block in ipairs(session.conflict_blocks or {}) do
    if not block.resolved or not M.get_range(session.result_bufnr, block) then
      count = count + 1
    end
  end
  return count
end

function M.stage_error(path)
  local state = M.get_state(path)
  if not state then
    return "Open this conflict in CodeDiff and explicitly resolve every block before staging."
  end
  if M.unresolved_count(state) > 0 then
    return "Resolve every conflict explicitly (or Mark Resolved after manual editing) before staging."
  end
  if vim.bo[state.result_bufnr].modified then
    return "Save the Result buffer before staging."
  end
  local options = vim.bo[state.result_bufnr]
  local separator = options.fileformat == "dos" and "\r\n" or options.fileformat == "mac" and "\r" or "\n"
  local expected = table.concat(vim.api.nvim_buf_get_lines(state.result_bufnr, 0, -1, false), separator)
  if options.endofline then
    expected = expected .. separator
  end
  local encoding = options.fileencoding ~= "" and options.fileencoding or "utf-8"
  if encoding ~= "utf-8" then
    local ok, converted = pcall(vim.iconv, expected, "utf-8", encoding)
    if not ok or not converted then
      return "Cannot verify the saved Result encoding; save as UTF-8 before staging."
    end
    expected = converted
  end
  if options.bomb then
    local boms = {
      ["utf-8"] = "\239\187\191", ["utf-16le"] = "\255\254", ["utf-16"] = "\254\255",
      ["ucs-2le"] = "\255\254", ["ucs-2"] = "\254\255",
      ["ucs-4le"] = "\255\254\0\0", ["ucs-4"] = "\0\0\254\255",
    }
    if not boms[encoding] then
      return "Cannot verify the saved Result byte-order mark; save as UTF-8 before staging."
    end
    expected = boms[encoding] .. expected
  end
  local file = io.open(state.path, "rb")
  if not file then
    return "The Result file cannot be read from disk; save it before staging."
  end
  local actual = file:read("*a")
  file:close()
  if state.saved_hash then
    if actual and vim.fn.sha256(actual) == state.saved_hash then
      return nil
    end
    return "Result changed on disk after saving; review the external change before staging."
  end
  if actual ~= expected then
    return "Result differs from the file on disk; review the external change and save before staging."
  end
end

function M.is_block_active(session, block)
  M.sync(session)
  return not block.resolved or not M.get_range(session.result_bufnr, block)
end

function M.get_accepted_side(session, block)
  M.sync(session)
  return not M.is_block_active(session, block) and block.accepted or nil
end

function M.get_lines_for_range(bufnr, first, last)
  if first >= last then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, first - 1, last - 1, true)
end

local function contains(bufnr, first, last, line)
  if first == last then
    return line == math.max(1, math.min(first, vim.api.nvim_buf_line_count(bufnr)))
  end
  return line >= first and line < last
end

function M.find_conflict_at_cursor(session, line, side, allow_resolved)
  local key = side == "left" and "output1_range" or side == "base" and "base_range" or "output2_range"
  local bufnr = side == "left" and session.original_bufnr or side == "base" and session.base_bufnr or session.modified_bufnr
  for _, block in ipairs(session.conflict_blocks or {}) do
    local range = block[key]
    if range and (allow_resolved or M.is_block_active(session, block)) and contains(bufnr, range.start_line, range.end_line, line) then
      return block
    end
  end
end

function M.find_conflict_at_cursor_in_result(session, line, allow_resolved)
  M.sync(session)
  for _, block in ipairs(session.conflict_blocks or {}) do
    local first, last = M.get_range(session.result_bufnr, block)
    if first and (allow_resolved or M.is_block_active(session, block)) and contains(session.result_bufnr, first + 1, last + 1, line) then
      return block
    end
  end
end

function M.get_block_start_line(session, block, bufnr)
  M.sync(session)
  if bufnr == session.result_bufnr then
    local first = M.get_range(bufnr, block)
    return first and math.min(first + 1, vim.api.nvim_buf_line_count(bufnr))
  end
  local range = bufnr == session.original_bufnr and block.output1_range
    or bufnr == session.modified_bufnr and block.output2_range
    or bufnr == session.base_bufnr and block.base_range
  return range and math.min(range.start_line, vim.api.nvim_buf_line_count(bufnr))
end

-- One native undo entry carries both text and approval, including unchanged text.
function M.apply(session, edits)
  M.sync(session)
  local bufnr = session.result_bufnr
  local state = states[bufnr]
  local levels = vim.bo[bufnr].undolevels
  if levels == -123456 then
    levels = vim.go.undolevels
  end
  if not state or not vim.bo[bufnr].modifiable or levels < 0 then
    return false, "Result must be modifiable with undo enabled."
  end
  for _, edit in ipairs(edits) do
    local first, last = M.get_range(bufnr, edit.block)
    if not first or last > vim.api.nvim_buf_line_count(bufnr) or edit.block.ambiguous and edit.lines then
      return false, "Conflict range is unavailable or ambiguous; edit Result manually and Mark Resolved."
    end
  end
  snapshot(state)
  state.applying = true
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("let &undolevels = &undolevels")
    for i, edit in ipairs(edits) do
      if i > 1 then
        vim.cmd("undojoin")
      end
      local first, last = M.get_range(bufnr, edit.block)
      local lines = edit.lines or vim.api.nvim_buf_get_lines(bufnr, first, last, true)
      -- set_lines deliberately records an undo entry even for Use Base/Mark Resolved.
      if first == last and #lines == 0 then
        local row = math.min(first, vim.api.nvim_buf_line_count(bufnr) - 1)
        vim.api.nvim_buf_set_lines(bufnr, row, row + 1, true, vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true))
      else
        vim.api.nvim_buf_set_lines(bufnr, first, last, true, lines)
      end
      set_range(bufnr, edit.block, first, first + #lines)
      edit.block.resolved, edit.block.accepted = edit.resolved, edit.accepted
    end
    vim.cmd("let &undolevels = &undolevels")
  end)
  state.applying = false
  snapshot(state)
  notify(state)
  return ok, err
end

return M
