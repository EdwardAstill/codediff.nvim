-- Centralized layout manager for codediff windows
-- Single source of truth for all window sizing decisions
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

--- Arrange all windows in a codediff tabpage
--- Call this after any structural window change (create, toggle, conflict setup)
--- @param tabpage number
function M.arrange(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  require("codediff.ui.conflict.view.result").restore_maximize(session)
  if session.popup then
    require("codediff.ui.popup").arrange(session)
    return
  end

  local original_win = session.original_win
  local modified_win = session.modified_win
  local result_win = session.result_win
  local panel = session.panel and session.panel.view

  -- Panel state
  local panel_win = panel and panel.winid
  local panel_visible = panel_win and vim.api.nvim_win_is_valid(panel_win) and not panel.is_hidden

  -- Panel config lives under the panel's own name in the user config
  local panel_name = session.panel and session.panel.name or "explorer"
  local panel_config = config.options[panel_name] or {}
  local panel_position = panel_config.position or "left"
  local merging = session.base_win and vim.api.nvim_win_is_valid(session.base_win)
  if panel_visible and merging then
    if panel_position ~= "left" then
      vim.api.nvim_win_call(panel_win, function() vim.cmd("wincmd H") end)
      session.merge_panel_moved = true
    end
    panel_position = "left"
  elseif panel_visible and session.merge_panel_moved then
    session.merge_panel_moved = nil
    if panel_position == "bottom" then
      vim.api.nvim_win_call(panel_win, function() vim.cmd("wincmd J") end)
    end
  end
  local panel_width = math.max(1, math.min(panel_config.width or 30, vim.o.columns - 5))

  -- Step 1: Pin panel size (fixed element)
  if panel_visible then
    if panel_position == "left" then
      vim.api.nvim_win_set_width(panel_win, panel_width)
    else
      vim.api.nvim_win_set_height(panel_win, panel_config.height)
    end
  end

  local orig_valid = original_win and vim.api.nvim_win_is_valid(original_win)
  local mod_valid = modified_win and vim.api.nvim_win_is_valid(modified_win)
  local is_single_diff_window = session.layout == "inline" or original_win == modified_win

  -- Single-pane mode: one diff window takes all available space
  if session.single_pane or is_single_diff_window or (orig_valid ~= mod_valid) then
    local sole_win = orig_valid and original_win or (mod_valid and modified_win or nil)
    if sole_win then
      if panel_visible then
        if panel_position == "left" then
          vim.api.nvim_win_set_width(panel_win, panel_config.width)
          -- Explicitly set diff window to fill remainder
          local remainder = vim.o.columns - panel_config.width - 1
          vim.api.nvim_win_set_width(sole_win, remainder)
        else
          vim.api.nvim_win_set_height(panel_win, panel_config.height)
          -- Diff window takes full width
          vim.api.nvim_win_set_width(sole_win, vim.o.columns)
        end
      end
    end
    return
  end

  -- Both windows must be valid for two-pane layout
  if not orig_valid or not mod_valid then
    return
  end

  local base_win = session.base_win
  local has_grid = base_win and vim.api.nvim_win_is_valid(base_win) and result_win and vim.api.nvim_win_is_valid(result_win)
  local available = vim.api.nvim_win_get_width(original_win) + vim.api.nvim_win_get_width(modified_win)
  local half = math.max(1, math.floor(available / 2))
  vim.api.nvim_win_set_width(original_win, half)
  vim.api.nvim_win_set_width(modified_win, math.max(1, available - half))
  if has_grid then
    vim.api.nvim_win_set_width(base_win, half)
    vim.api.nvim_win_set_width(result_win, math.max(1, available - half))
    for _, pair in ipairs({ { original_win, base_win }, { modified_win, result_win } }) do
      local height = vim.api.nvim_win_get_height(pair[1]) + vim.api.nvim_win_get_height(pair[2])
      vim.api.nvim_win_set_height(pair[1], math.max(1, math.floor(height / 2)))
      vim.api.nvim_win_set_height(pair[2], math.max(1, height - math.floor(height / 2)))
    end
  end

  -- Step 5: Re-pin panel size (undo disturbance from step 4)
  if panel_visible then
    if panel_position == "left" then
      vim.api.nvim_win_set_width(panel_win, panel_width)
    else
      vim.api.nvim_win_set_height(panel_win, panel_config.height)
    end
  end
end

return M
