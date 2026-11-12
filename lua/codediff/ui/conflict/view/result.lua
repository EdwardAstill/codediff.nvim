-- Fixed Incoming / Current / Base / Result merge grid.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local sides = { "original", "modified", "base", "result" }

function M.restore_maximize(session)
  local maximized = session.merge_maximized
  if not maximized then
    return
  end
  session.merge_maximized = nil
  if vim.api.nvim_win_is_valid(maximized.win) then
    local view = vim.api.nvim_win_call(maximized.win, vim.fn.winsaveview)
    if vim.api.nvim_win_is_valid(maximized.source) then
      vim.api.nvim_win_call(maximized.source, function() vim.fn.winrestview(view) end)
    end
    vim.api.nvim_win_close(maximized.win, true)
    if vim.api.nvim_win_is_valid(maximized.source) then
      vim.api.nvim_set_current_win(maximized.source)
    end
  end
end

function M.toggle_maximize(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.base_win then
    return
  end
  if session.merge_maximized then
    M.restore_maximize(session)
    return
  end
  local source = vim.api.nvim_get_current_win()
  local selected
  for _, side in ipairs(sides) do
    if session[side .. "_win"] == source then selected = side end
  end
  if not selected then return end
  local view = vim.fn.winsaveview()
  local win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(source), true, {
    relative = "editor", row = 0, col = 0,
    width = math.max(1, vim.o.columns), height = math.max(1, vim.o.lines - vim.o.cmdheight - 1),
    style = "minimal", zindex = 80,
  })
  session.merge_maximized = { win = win, source = source }
  for _, option in ipairs({ "number", "relativenumber", "cursorline", "winbar", "statuscolumn", "signcolumn" }) do
    vim.wo[win][option] = vim.wo[source][option]
  end
  vim.wo[win].wrap, vim.wo[win].scrollbind = false, false
  vim.fn.winrestview(view)
  M.update_labels(session)
end

function M.update_labels(session)
  local count = require("codediff.ui.conflict.tracking").unresolved_count(session)
  local labels = { original = "Incoming (:3)", modified = "Current (:2)", base = "Base (:1)", result = "Result — " .. count .. " unresolved" }
  for _, side in ipairs(sides) do
    local win = session[side .. "_win"]
    if win and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" and cfg.border and #cfg.border > 0 then
        vim.wo[win].winbar = ""
        vim.api.nvim_win_set_config(win, { title = " " .. labels[side] .. " ", title_pos = "center" })
      else
        vim.wo[win].winbar = " " .. labels[side]
      end
    end
  end
  if session.merge_maximized and vim.api.nvim_win_is_valid(session.merge_maximized.win) then
    for _, side in ipairs(sides) do
      if session[side .. "_win"] == session.merge_maximized.source then
        vim.wo[session.merge_maximized.win].winbar = " " .. labels[side]
      end
    end
  end
end

-- A shared visual row includes fillers, but never a pane's horizontal offset.
local function visual_row(view, fillers)
  local row = view.topline - 1
  for _, filler in ipairs(fillers) do
    if filler.after_line < view.topline then row = row + filler.count end
  end
  return row - (view.topfill or 0)
end

local function view_at_row(row, fillers, count)
  local total = 0
  for _, filler in ipairs(fillers) do
    local start = filler.after_line + total
    if row < start then break end
    total = total + filler.count
    if row < filler.after_line + total then
      return math.min(count, filler.after_line + 1), filler.after_line + total - row
    end
  end
  return math.max(1, math.min(count, row - total + 1)), 0
end

function M.sync_scroll(session, source)
  if session.merge_scroll_sync == false or session.merge_scrolling or not session.merge_fillers then return end
  local source_index
  local source_buf = vim.api.nvim_win_is_valid(source) and vim.api.nvim_win_get_buf(source)
  for index, side in ipairs(sides) do
    if source_buf == session[side .. "_bufnr"] then source_index = index end
  end
  if not source_index then return end
  session.merge_scrolling = true
  local view = vim.api.nvim_win_call(source, vim.fn.winsaveview)
  local row = visual_row(view, session.merge_fillers[source_index])
  for index, side in ipairs(sides) do
    local win = session[side .. "_win"]
    if win and win ~= source and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        local target = vim.fn.winsaveview()
        target.topline, target.topfill = view_at_row(row, session.merge_fillers[index], vim.api.nvim_buf_line_count(session[side .. "_bufnr"]))
        vim.fn.winrestview(target)
      end)
    end
  end
  session.merge_scrolling = false
end

function M.toggle_scroll_sync(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.base_win then return end
  session.merge_scroll_sync = session.merge_scroll_sync == false
  if session.merge_scroll_sync then M.sync_scroll(session, vim.api.nvim_get_current_win()) end
  vim.notify("Merge scroll linking " .. (session.merge_scroll_sync and "on" or "off"), vim.log.levels.INFO)
end

function M.set_inputs(session, base_lines, diffs)
  local ok, err = require("codediff.ui.conflict.tracking").bind_result(session, base_lines, diffs)
  if not ok then return false, err end
  session.merge_diffs = diffs
  if session.base_bufnr and vim.api.nvim_buf_is_valid(session.base_bufnr) then
    require("codediff.core.virtual_file").set_content(session.base_bufnr, base_lines, session.original and session.original.relative)
  end
  return true
end

function M.render(session)
  if not session.result_bufnr or not vim.api.nvim_buf_is_valid(session.result_bufnr) or not session.result_base_lines then return end
  local lines = vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)
  local options = require("codediff.ui.view.render").diff_options()
  local diff = require("codediff.core.diff")
  local result = diff.compute_diff(session.result_base_lines, lines, options)
  if result then require("codediff.ui.core").render_single_buffer(session.result_bufnr, result, "modified") end
  if session.merge_diffs and session.base_bufnr then
    local base_to_result = diff.compute_diff(session.merge_base_lines, lines, options)
    if base_to_result then
      local fillers = require("codediff.ui.conflict.merge.fillers").compute_grid_fillers(session.merge_diffs.base_to_original_diff, session.merge_diffs.base_to_modified_diff, base_to_result)
      session.merge_fillers = fillers
      for index, side in ipairs(sides) do
        local buf = session[side .. "_bufnr"]
        vim.api.nvim_buf_clear_namespace(buf, require("codediff.ui.highlights").ns_filler, 0, -1)
        for _, filler in ipairs(fillers[index]) do
          require("codediff.ui.filler").place(buf, filler.after_line - 1, filler.count)
        end
      end
    end
  end
  require("codediff.ui.conflict").refresh(session)
  M.sync_scroll(session, vim.api.nvim_get_current_win())
end

function M.close_grid(session)
  M.restore_maximize(session)
  local base_win, base_buf, result_win = session.base_win, session.base_bufnr, session.result_win
  session.base_win, session.base_bufnr, session.merge_fillers, session.merge_diffs = nil, nil, nil, nil
  lifecycle.set_result(session.tabpage, nil, nil)
  for _, win in pairs({ base_win, result_win }) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" then vim.bo[buf].bufhidden = "hide" end
      vim.api.nvim_win_close(win, true)
    end
  end
  if base_buf and vim.api.nvim_buf_is_valid(base_buf) then vim.api.nvim_buf_delete(base_buf, { force = true }) end
  if session.merge_scroll_autocmd then
    vim.api.nvim_del_autocmd(session.merge_scroll_autocmd)
    session.merge_scroll_autocmd = nil
  end
end

function M.setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs)
  local session = lifecycle.get_session(tabpage)
  if not session then return false end
  M.restore_maximize(session)
  session.merge_inputs = session_config.merge_inputs
  session.merge_input_identity = session.merge_inputs and session.merge_inputs.identity
  local saved_win = vim.api.nvim_get_current_win()
  if not session.base_bufnr or not vim.api.nvim_buf_is_valid(session.base_bufnr) then
    session.base_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[session.base_bufnr].bufhidden = "hide"
  end
  local grid_scratch
  local grid_ok, grid_error = pcall(function()
    if session.popup then
      require("codediff.ui.popup").open_result(session)
    else
      if not session.base_win or not vim.api.nvim_win_is_valid(session.base_win) then
        -- Fix semantic roles even when ordinary diffs prefer Original on the right.
        vim.fn.win_splitmove(original_win, modified_win, { vertical = true, rightbelow = false })
        session.base_win = vim.api.nvim_open_win(session.base_bufnr, false, { split = "below", win = original_win })
      end
      if not session.result_win or not vim.api.nvim_win_is_valid(session.result_win) then
        grid_scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[grid_scratch].bufhidden = "wipe"
        session.result_win = vim.api.nvim_open_win(grid_scratch, false, { split = "below", win = modified_win })
      end
    end
  end)
  if not grid_ok then
    M.close_grid(session)
    if grid_scratch and vim.api.nvim_buf_is_valid(grid_scratch) then vim.api.nvim_buf_delete(grid_scratch, { force = true }) end
    vim.notify("Cannot open merge grid; enlarge the editor: " .. tostring(grid_error), vim.log.levels.ERROR)
    return false
  end
  local path = session_config.original.absolute
  local ok, buf = pcall(vim.fn.bufadd, path)
  if ok then ok, buf = pcall(function() vim.fn.bufload(buf); return buf end) end
  if not ok then
    vim.notify("Failed to open Result: " .. tostring(buf), vim.log.levels.ERROR)
    return false
  end
  -- Keep unsaved Result buffers alive when switching files, even with 'hidden' off.
  local previous = vim.api.nvim_win_get_buf(session.result_win)
  if vim.bo[previous].buftype == "" then vim.bo[previous].bufhidden = "hide" end
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_win_set_buf(session.result_win, buf)
  lifecycle.set_result(tabpage, buf, session.result_win)
  local bound, err = M.set_inputs(session, base_lines, conflict_diffs)
  if not bound then
    vim.notify("Cannot initialize merge Result: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  for _, side in ipairs(sides) do
    local win, source = session[side .. "_win"], session[side .. "_bufnr"]
    vim.wo[win].wrap, vim.wo[win].scrollbind, vim.wo[win].cursorbind = false, false, false
    vim.wo[win].cursorline = true
    if side ~= "result" then vim.bo[source].modifiable, vim.bo[source].readonly = false, true end
  end
  lifecycle.track_conflict_file(tabpage, path)
  require("codediff.ui.layout").arrange(tabpage)
  if not session.merge_scroll_autocmd then
    session.merge_scroll_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
      callback = function(args)
        if lifecycle.get_session(tabpage) ~= session or not session.base_win then return end
        local change = vim.v.event[args.match]
        if change and (change.topline or 0) == 0 and (change.topfill or 0) == 0 then return end
        M.sync_scroll(session, tonumber(args.match) or vim.api.nvim_get_current_win())
      end,
    })
  end
  local conflict = require("codediff.ui.conflict")
  conflict.attach_gutter(original_win, modified_win, session.base_win, session.result_win)
  conflict.setup_refresh_autocmd(tabpage, buf)
  M.render(session)
  if vim.api.nvim_win_is_valid(saved_win) then vim.api.nvim_set_current_win(saved_win) end
  return true
end

return M
