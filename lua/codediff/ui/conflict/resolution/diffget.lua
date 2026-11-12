-- Numbered diffget keeps its Result-only meaning and semantic side names.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local block = require("codediff.ui.conflict.resolution.block")

local function diffget(tabpage, action)
  local session = lifecycle.get_session(tabpage)
  if not session or vim.api.nvim_get_current_buf() ~= session.result_bufnr then
    vim.notify("[codediff] Numbered diffget only works from Result", vim.log.levels.INFO)
    return false
  end
  return action(tabpage)
end

function M.diffget_incoming(tabpage)
  return diffget(tabpage, block.accept_incoming)
end

function M.diffget_current(tabpage)
  return diffget(tabpage, block.accept_current)
end

return M
