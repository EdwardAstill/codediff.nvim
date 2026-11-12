-- Whole-file actions use the same transaction and explicit state as one block.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")
local block_actions = require("codediff.ui.conflict.resolution.block")

local function resolve_all(tabpage, action)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.result_bufnr then
    vim.notify("[codediff] No active merge session", vim.log.levels.WARN)
    return false
  end
  local edits = {}
  for i = #(session.conflict_blocks or {}), 1, -1 do
    local block = session.conflict_blocks[i]
    if action == "reset" or tracking.is_block_active(session, block) then
      local edit, err = block_actions.edit_for(session, block, action)
      if not edit then
        vim.notify("[codediff] " .. err, vim.log.levels.ERROR)
        return false
      end
      edits[#edits + 1] = edit
    end
  end
  if #edits == 0 then
    vim.notify("[codediff] No active conflicts", vim.log.levels.INFO)
    return false
  end
  return block_actions.apply(session, edits)
end

function M.accept_all_incoming(tabpage)
  return resolve_all(tabpage, "incoming")
end

function M.accept_all_current(tabpage)
  return resolve_all(tabpage, "current")
end

function M.accept_all_both(tabpage)
  return resolve_all(tabpage, "both")
end

function M.discard_all(tabpage)
  return resolve_all(tabpage, "reset")
end

return M
