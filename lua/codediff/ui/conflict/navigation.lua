-- Conflict navigation follows the same block in all four merge panes.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")

local function navigate(tabpage, direction)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then return end
  local active = {}
  for _, block in ipairs(session.conflict_blocks) do
    if tracking.is_block_active(session, block) then active[#active + 1] = block end
  end
  if #active == 0 then
    vim.notify("No unresolved conflicts", vim.log.levels.INFO)
    return
  end
  local current_buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local target = direction == 1 and 1 or #active
  for offset = 1, #active do
    local index = direction == 1 and offset or #active - offset + 1
    local line = tracking.get_block_start_line(session, active[index], current_buf)
    if line and (line - cursor) * direction > 0 then
      target = index
      break
    end
  end
  local block = active[target]
  local windows = { session.original_win, session.modified_win, session.base_win, session.result_win }
  if session.merge_maximized then windows[#windows + 1] = session.merge_maximized.win end
  session.merge_scrolling = true
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local line = tracking.get_block_start_line(session, block, buf)
      if line then
        vim.api.nvim_win_call(win, function()
          local view = vim.fn.winsaveview()
          vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf))), 0 })
          vim.cmd("normal! zz")
          local centered = vim.fn.winsaveview()
          centered.leftcol = view.leftcol
          vim.fn.winrestview(centered)
        end)
      end
    end
  end
  session.merge_scrolling = false
  vim.api.nvim_echo({ { string.format("Conflict %d of %d", target, #active), "None" } }, false, {})
end

function M.navigate_next_conflict(tabpage)
  navigate(tabpage, 1)
end

function M.navigate_prev_conflict(tabpage)
  navigate(tabpage, -1)
end

return M
