-- Actions that move focus or content between codediff's panes and the rest of
-- the editor: explorer visibility and focus, and opening the real file in the
-- previous tab.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

local function get_explorer_target_file(explorer, session)
  local node = explorer.tree and explorer.tree:get_node()
  local data = node and node.data

  if not data or data.type == "group" or data.type == "directory" or not data.path or data.path == "" then
    return nil
  end

  local git_root = data.git_root or explorer.git_root or session.git_root
  if not git_root or git_root == "" then
    return nil
  end

  return vim.fs.joinpath(git_root, data.path)
end

function M.cycle(ctx, direction)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session then
    return
  end
  local explorer = lifecycle.get_panel_view(ctx.tabpage)
  local windows = {}
  for _, pane in ipairs(explorer and (explorer.panes or { explorer }) or {}) do
    if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
      windows[#windows + 1] = pane.winid
    end
  end
  for _, win in ipairs({ session.original_win, session.modified_win, session.result_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      windows[#windows + 1] = win
    end
  end
  local current = vim.api.nvim_get_current_win()
  for index, win in ipairs(windows) do
    if win == current then
      vim.api.nvim_set_current_win(windows[(index - 1 + direction) % #windows + 1])
      return
    end
  end
end

function M.toggle_explorer(ctx)
  local explorer_obj = lifecycle.get_panel_view(ctx.tabpage)
  if not explorer_obj then
    vim.notify("No explorer found for this tab", vim.log.levels.WARN)
    return
  end
  local explorer = require("codediff.ui.explorer")
  explorer.toggle_visibility(explorer_obj)
end

function M.focus_explorer(ctx)
  local explorer_obj = lifecycle.get_panel_view(ctx.tabpage)
  if not explorer_obj then
    vim.notify("No explorer found for this tab", vim.log.levels.WARN)
    return
  end
  if explorer_obj.is_hidden then
    require("codediff.ui.explorer").toggle_visibility(explorer_obj)
  end
  local target = explorer_obj
  for _, pane in ipairs(explorer_obj.panes or { explorer_obj }) do
    if pane.group == explorer_obj.data.current_file_group then
      target = pane
      break
    end
  end
  if target.winid and vim.api.nvim_win_is_valid(target.winid) then
    vim.api.nvim_set_current_win(target.winid)
  end
end

function M.open_in_prev_tab(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local side = nil
  if current_buf == ctx.original_bufnr then
    side = "original"
  elseif current_buf == ctx.modified_bufnr then
    side = "modified"
  end

  local explorer = lifecycle.get_panel_view(ctx.tabpage)
  local is_explorer_buf = false
  for _, pane in ipairs(explorer and (explorer.panes or { explorer }) or {}) do
    if pane.bufnr == current_buf then
      explorer, is_explorer_buf = pane, true
      break
    end
  end

  -- Only operate on diff and explorer buffers; ignore history/result silently
  if not side and not is_explorer_buf then
    return
  end

  local is_virtual = (side == "original" and lifecycle.is_original_virtual(ctx.tabpage)) or (side == "modified" and lifecycle.is_modified_virtual(ctx.tabpage))

  -- Resolve target file path
  local target_file
  if is_explorer_buf then
    target_file = get_explorer_target_file(explorer, session)
    if not target_file then
      return
    end
  elseif is_virtual then
    local original, modified = lifecycle.get_paths(ctx.tabpage)
    local ref = side == "original" and original or modified
    if not ref or ref.absolute == "" then
      vim.notify("Buffer has no associated file path", vim.log.levels.WARN)
      return
    end
    target_file = ref.absolute
  else
    target_file = vim.api.nvim_buf_get_name(current_buf)
    if target_file == "" then
      vim.notify("Buffer has no name; cannot open in previous tab", vim.log.levels.WARN)
      return
    end
  end

  local cursor = side and vim.api.nvim_win_get_cursor(0) or nil
  local current_tab = vim.api.nvim_get_current_tabpage()
  local tabs = vim.api.nvim_list_tabpages()

  local current_index = nil
  for i, tab in ipairs(tabs) do
    if tab == current_tab then
      current_index = i
      break
    end
  end

  local target_tab
  if session.popup then
    if not lifecycle.close(ctx.tabpage) then
      return
    end
    target_tab = current_tab
  elseif current_index and current_index > 1 then
    target_tab = tabs[current_index - 1]
  else
    vim.cmd("tabnew")
    target_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabmove 0")
  end

  if vim.api.nvim_get_current_tabpage() ~= target_tab then
    vim.api.nvim_set_current_tabpage(target_tab)
  end

  local target_win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(target_win) then
    vim.notify("No valid window in target tab to open buffer", vim.log.levels.ERROR)
    return
  end

  local ok, err
  if is_virtual or is_explorer_buf then
    ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(target_file))
  else
    ok, err = pcall(vim.api.nvim_win_set_buf, target_win, current_buf)
  end
  if not ok then
    vim.notify("Failed to open buffer in previous tab: " .. err, vim.log.levels.ERROR)
    return
  end

  if cursor then
    pcall(vim.api.nvim_win_set_cursor, target_win, cursor)
  end

  -- Optionally close codediff after navigating to file
  if config.options.keymaps.view.close_on_open_in_prev_tab and not session.popup then
    lifecycle.close(current_tab)
  end
end

return M
