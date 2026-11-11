local M = {}

function M.is_status(session_config)
  return session_config.panel
    and session_config.panel.name == "explorer"
    and session_config.git_root ~= nil
    and session_config.original_revision == nil
    and session_config.modified_revision == nil
    and (session_config.layout or require("codediff.config").options.diff.layout) ~= "inline"
end

function M.capture()
  return { return_win = vim.api.nvim_get_current_win(), return_view = vim.fn.winsaveview() }
end

-- :edit! must never abandon unsaved work while retargeting a popup pane.
function M.prepare_switch(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local hidden = vim.bo[buf].bufhidden
  if vim.bo[buf].buftype ~= "" or (not vim.bo[buf].modified and hidden ~= "wipe" and hidden ~= "delete" and hidden ~= "unload") then
    return
  end
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_win_set_buf(win, scratch)
  vim.bo[buf].bufhidden = hidden
end

function M.geometry()
  local columns = vim.o.columns
  local rows = math.max(6, vim.o.lines - vim.o.cmdheight - 1)
  local width = math.max(9, math.min(columns, math.floor(columns * 0.96)))
  local height = math.max(6, math.min(rows, math.floor(rows * 0.94)))
  local col = math.max(0, math.floor((columns - width) / 2))
  local row = math.max(0, math.floor((rows - height) / 2))
  local left = math.max(3, math.min(math.floor(width * 0.24), width - 6))
  local before = math.floor((width - left) / 2)
  local top = math.floor(height / 2)
  local function pane(title, x, y, w, h)
    return {
      relative = "editor",
      row = y,
      col = x,
      width = math.max(1, w - 2),
      height = math.max(1, h - 2),
      border = "rounded",
      title = " " .. title .. " ",
      title_pos = "center",
      style = "minimal",
      zindex = 60,
      focusable = true,
    }
  end
  return {
    unstaged = pane("Unstaged", col, row, left, top),
    staged = pane("Staged", col, row + top, left, height - top),
    original = pane("Before", col + left, row, before, height),
    modified = pane("After", col + left + before, row, width - left - before, height),
  }
end

local function with_result(configs)
  local result = vim.tbl_extend("force", configs.original, {
    row = configs.staged.row,
    height = configs.staged.height,
    width = configs.original.width + configs.modified.width + 2,
    title = " Result ",
  })
  configs.original.height = configs.unstaged.height
  configs.modified.height = configs.unstaged.height
  configs.result = result
  return configs
end

function M.open_result(session)
  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, with_result(M.geometry()).result)
  require("codediff.ui.lifecycle").set_result(session.tabpage, buf, win)
end

function M.arrange(session)
  local configs = M.geometry()
  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    with_result(configs)
  end
  for _, side in ipairs({ "original", "modified", "result" }) do
    local win = session[side .. "_win"]
    if win and vim.api.nvim_win_is_valid(win) and configs[side] then
      vim.api.nvim_win_set_config(win, configs[side])
    end
  end
  local root = session.panel and session.panel.view
  if root and not root.is_hidden then
    for _, pane in ipairs(root.panes or { root }) do
      local cfg = configs[pane.group or "unstaged"]
      if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
        vim.api.nvim_win_set_config(pane.winid, cfg)
      elseif pane.bufnr and vim.api.nvim_buf_is_valid(pane.bufnr) then
        pane.winid = vim.api.nvim_open_win(pane.bufnr, false, cfg)
        vim.wo[pane.winid].cursorline = true
        vim.wo[pane.winid].scrollbind = false
        vim.wo[pane.winid].cursorbind = false
        vim.wo[pane.winid].signcolumn = "no"
        vim.wo[pane.winid].statuscolumn = ""
        vim.wo[pane.winid].winbar = ""
      end
      if pane.tree and pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
        pane.tree:render()
      end
    end
  end
end

function M.close(session)
  local popup = session.popup
  popup.closing = true
  local root = session.panel and session.panel.view
  local windows = { session.original_win, session.modified_win, session.result_win }
  if root then
    root.is_hidden = true
    for _, pane in ipairs(root.panes or { root }) do
      if pane.winid then
        windows[#windows + 1] = pane.winid
      end
    end
  end
  for _, win in pairs(windows) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local bufhidden = vim.bo[buf].bufhidden
      -- A user's buffer must survive even with 'hidden' off or bufhidden=wipe.
      if vim.bo[buf].buftype == "" then
        vim.bo[buf].bufhidden = "hide"
      end
      pcall(vim.api.nvim_win_close, win, true)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].bufhidden = bufhidden
      end
    end
  end
  if root then
    for _, pane in ipairs(root.panes or { root }) do
      if pane.bufnr and vim.api.nvim_buf_is_valid(pane.bufnr) then
        pcall(vim.api.nvim_buf_delete, pane.bufnr, { force = true })
      end
    end
  end
  if vim.api.nvim_get_current_tabpage() == session.tabpage and vim.api.nvim_win_is_valid(popup.return_win) then
    vim.api.nvim_set_current_win(popup.return_win)
    vim.fn.winrestview(popup.return_view)
  end
end

return M
