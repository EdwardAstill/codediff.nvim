-- Buffer-local mapping inspection for lifecycle checks.

local M = {}

--- Collect buffer-local mappings for an arbitrary buffer outside a session.
--- Used to assert that pre-existing user mappings survive a session, and that
--- codediff mappings do not outlive it.
--- @param bufnr number
--- @param mode string
--- @return table<string, string> lhs -> desc ("-" when absent)
function M.map_index(bufnr, mode)
  local index = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return index
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    index[map.lhs] = map.desc or "-"
  end
  return index
end

return M
