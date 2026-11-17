-- Welcome page for empty diff panes
-- Pure buffer factory — no window, session, or lifecycle knowledge
local M = {}

local hint_line = "Working tree is clean — no changes to display."
local keys_line = "[R] Refresh  [q] Close"

local ns = vim.api.nvim_create_namespace("codediff-welcome")

vim.api.nvim_set_hl(0, "CodeDiffWelcomeKey", { link = "Special", default = true })

-- Compute display width of a string (handles multi-byte characters)
local function display_width(str)
  return vim.fn.strdisplaywidth(str)
end

-- Center a string within given width, return padded string
local function center(str, width)
  local str_width = display_width(str)
  if str_width >= width then
    return str
  end
  local pad = math.floor((width - str_width) / 2)
  return string.rep(" ", pad) .. str
end

--- Create a welcome buffer with centered hints
--- @param width number Available width in columns
--- @param height number Available height in rows
--- @return number bufnr
function M.create_buffer(width, height)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  if not pcall(vim.api.nvim_buf_set_name, bufnr, "codediff") then
    pcall(vim.api.nvim_buf_set_name, bufnr, "codediff (" .. bufnr .. ")")
  end

  local content_lines = {
    center(hint_line, width),
    center(keys_line, width),
  }

  -- Vertical centering: add blank lines above
  local total_content = #content_lines
  local top_pad = math.max(0, math.floor((height - total_content) / 2))

  local lines = {}
  for _ = 1, top_pad do
    table.insert(lines, "")
  end
  for _, line in ipairs(content_lines) do
    table.insert(lines, line)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights using extmarks in the welcome namespace
  for i, line in ipairs(lines) do
    local row = i - 1

    -- Keys line: highlight bracket pairs [R] and [q]
    if line:find("%[R%]") or line:find("%[q%]") then
      for bracket_start, bracket_end in line:gmatch("()%[.-%]()") do
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, bracket_start - 1, {
          end_col = bracket_end - 1,
          hl_group = "CodeDiffWelcomeKey",
        })
      end
    end
  end

  return bufnr
end

--- Check if a buffer is a welcome buffer (has codediff-welcome extmarks)
--- @param bufnr number|nil
--- @return boolean
function M.is_welcome_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { limit = 1 })
  return #marks > 0
end

return M
