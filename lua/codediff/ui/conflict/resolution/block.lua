-- Resolution commands share one validated, undoable Result transaction.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")

function M.edit_for(session, block, action)
  local lines
  if action == "incoming" then
    lines = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
  elseif action == "current" then
    lines = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)
  elseif action == "both" or action == "both_reverse" then
    local incoming = tracking.get_lines_for_range(session.original_bufnr, block.output1_range.start_line, block.output1_range.end_line)
    local current = tracking.get_lines_for_range(session.modified_bufnr, block.output2_range.start_line, block.output2_range.end_line)
    lines = action == "both" and vim.list_extend(current, incoming) or vim.list_extend(incoming, current)
  elseif action ~= "manual" then
    local base = session.merge_base_lines or session.result_base_lines
    if not base then
      return nil, "No merge base is available."
    end
    lines = {}
    for i = block.base_range.start_line, block.base_range.end_line - 1 do
      lines[#lines + 1] = base[i]
    end
  end
  return { block = block, lines = lines, resolved = action ~= "reset", accepted = action == "both_reverse" and "both" or action }
end

function M.apply(session, edits)
  local ok, err = tracking.apply(session, edits)
  if not ok then
    vim.notify("[codediff] " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  require("codediff.ui.conflict.gutter").refresh(session)
  require("codediff.ui.refresh").refresh_result_now(session.result_bufnr)
  return true
end

local function resolve(tabpage, action)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.result_bufnr then
    vim.notify("[codediff] No active merge session", vim.log.levels.WARN)
    return false
  end
  local bufnr, line = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
  local block
  if bufnr == session.result_bufnr then
    block = tracking.find_conflict_at_cursor_in_result(session, line, true)
  else
    local side = bufnr == session.original_bufnr and "left" or bufnr == session.modified_bufnr and "right" or bufnr == session.base_bufnr and "base"
    if side then
      block = tracking.find_conflict_at_cursor(session, line, side, true)
    end
  end
  if not block then
    vim.notify("[codediff] No conflict at cursor position", vim.log.levels.INFO)
    return false
  end
  local edit, err = M.edit_for(session, block, action)
  if not edit then
    vim.notify("[codediff] " .. err, vim.log.levels.ERROR)
    return false
  end
  return M.apply(session, { edit })
end

function M.accept_incoming(tabpage)
  return resolve(tabpage, "incoming")
end

function M.accept_current(tabpage)
  return resolve(tabpage, "current")
end

function M.accept_both(tabpage)
  return resolve(tabpage, "both")
end

function M.accept_both_reverse(tabpage)
  return resolve(tabpage, "both_reverse")
end

function M.accept_base(tabpage)
  return resolve(tabpage, "base")
end

function M.mark_resolved(tabpage)
  return resolve(tabpage, "manual")
end

function M.discard(tabpage)
  return resolve(tabpage, "reset")
end

return M
