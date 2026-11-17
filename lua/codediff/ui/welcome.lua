-- Welcome page for empty diff panes
-- Pure buffer factory — no window, session, or lifecycle knowledge
local M = {}

--- Create an empty welcome buffer (blank when working tree is clean)
--- @return number bufnr
function M.create_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  if not pcall(vim.api.nvim_buf_set_name, bufnr, "codediff") then
    pcall(vim.api.nvim_buf_set_name, bufnr, "codediff (" .. bufnr .. ")")
  end
  vim.b[bufnr].codediff_welcome = true
  vim.bo[bufnr].modifiable = false
  return bufnr
end

--- Check if a buffer is a welcome buffer
--- @param bufnr number|nil
--- @return boolean
function M.is_welcome_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.b[bufnr].codediff_welcome == true
end

return M
