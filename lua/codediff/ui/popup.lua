local M = {}

local chrome
local hidden_chrome = { laststatus = 0, cmdheight = 0, showmode = false, ruler = false }

local function capture_chrome()
  local options = {}
  for name in pairs(hidden_chrome) do
    options[name] = vim.o[name]
  end
  return options
end

function M.restore_chrome(session)
  if not chrome or (session and chrome.session ~= session) then
    return
  end
  local saved = chrome
  chrome = nil
  for name, value in pairs(saved.options) do
    vim.o[name] = value
  end
end

local function sync_chrome()
  local session = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
  if not session or not session.popup or session.closing or session.popup.closing then
    M.restore_chrome()
    return
  end
  if chrome and chrome.session ~= session then
    M.restore_chrome()
  end
  if not chrome then
    chrome = { session = session, options = session.popup.initial_chrome or capture_chrome() }
    session.popup.initial_chrome = nil
  end
  for name, value in pairs(hidden_chrome) do
    vim.o[name] = session.merge and name == "cmdheight" and chrome.options.cmdheight or value
  end
end

local chrome_group = vim.api.nvim_create_augroup("codediff_popup_chrome", { clear = true })
vim.api.nvim_create_autocmd("TabLeave", {
  group = chrome_group,
  callback = function()
    M.restore_chrome()
  end,
})
vim.api.nvim_create_autocmd("TabEnter", { group = chrome_group, callback = sync_chrome })

function M.is_status(session_config)
  return session_config.panel
    and session_config.panel.name == "explorer"
    and session_config.git_root ~= nil
    and session_config.original_revision == nil
    and session_config.modified_revision == nil
    and (session_config.layout or require("codediff.config").options.diff.layout) ~= "inline"
end

function M.capture()
  return { return_win = vim.api.nvim_get_current_win(), return_view = vim.fn.winsaveview(), initial_chrome = capture_chrome() }
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

function M.geometry(hide_tree, merge)
  local columns = math.max(1, vim.o.columns)
  local rows = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
  local width = math.min(columns, math.max(1, math.floor(columns * 0.96)))
  local height = math.min(rows, math.max(1, math.floor(rows * 0.94)))
  local col = math.max(0, math.floor((columns - width) / 2))
  local row = math.max(0, math.floor((rows - height) / 2))
  local left = hide_tree and 0 or math.max(1, math.min(26, math.floor(width / 6)))
  if merge and not hide_tree then
    left = math.max(1, math.min(require("codediff.config").options.explorer.width + 2, math.floor(width / 3)))
  end
  local before = math.max(1, math.floor((width - left) / 2))
  local top = math.max(1, math.floor(height / 2))
  local border_size = columns >= 12 and rows >= 6 and 2 or 0
  local function pane(title, footer, x, y, w, h)
    x, y = math.min(columns - 1, x), math.min(rows - 1, y)
    return {
      relative = "editor",
      row = y,
      col = x,
      width = math.max(1, math.min(w - border_size, columns - x - border_size)),
      height = math.max(1, math.min(h - border_size, rows - y - border_size)),
      border = border_size == 2 and "rounded" or "none",
      title = border_size == 2 and " " .. title .. " " or nil,
      title_pos = border_size == 2 and "center" or nil,
      footer = border_size == 2 and footer or nil,
      footer_pos = border_size == 2 and "center" or nil,
      style = "minimal",
      zindex = 60,
      focusable = true,
    }
  end
  return {
    unstaged = pane("Unstaged", "s stage h help", col, row, left, top),
    staged = pane("Staged", "s unstage h help", col, row + top, left, height - top),
    original = pane("Before", "s stage/unstage  h help", col + left, row, before, height),
    modified = pane("After", "s stage/unstage  h help", col + left + before, row, width - left - before, height),
  }
end

local function with_result(configs)
  configs.original.height = configs.unstaged.height
  configs.modified.height = configs.unstaged.height
  configs.original.title, configs.modified.title = " Incoming (:3) ", " Current (:2) "
  configs.original.footer, configs.modified.footer = " g? help ", " g? help "
  configs.base = vim.tbl_extend("force", configs.original, {
    row = configs.staged.row, height = configs.staged.height, title = " Base (:1) ", footer = " g? help ",
  })
  configs.result = vim.tbl_extend("force", configs.modified, {
    row = configs.staged.row, height = configs.staged.height, title = " Result ", footer = " g? help ",
  })
  for _, cfg in pairs(configs) do
    if cfg.border == "none" then cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil end
  end
  return configs
end

function M.open_result(session)
  local root = session.panel and session.panel.view
  sync_chrome()
  local configs = with_result(M.geometry(root and root.is_hidden, true))
  if not session.base_win or not vim.api.nvim_win_is_valid(session.base_win) then
    session.base_win = vim.api.nvim_open_win(session.base_bufnr, false, configs.base)
  end
  if not session.result_win or not vim.api.nvim_win_is_valid(session.result_win) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, false, configs.result)
    require("codediff.ui.lifecycle").set_result(session.tabpage, buf, win)
  end
end

function M.arrange(session)
  require("codediff.ui.conflict.view.result").restore_maximize(session)
  local root = session.panel and session.panel.view
  if session.merge then sync_chrome() end
  local configs = M.geometry(root and root.is_hidden, session.merge)
  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    with_result(configs)
  end
  for _, side in ipairs({ "original", "modified", "base", "result" }) do
    local win = session[side .. "_win"]
    if win and vim.api.nvim_win_is_valid(win) and configs[side] then
      vim.api.nvim_win_set_config(win, configs[side])
      if side == "result" or side == "base" then
        vim.wo[win].number = true
        vim.wo[win].relativenumber = false
      else
        require("codediff.ui.view.welcome_window").sync(win)
      end
    end
  end
  if session.base_win then require("codediff.ui.conflict.view.result").update_labels(session) end
  if root and not root.is_hidden then
    for _, pane in ipairs(root.panes or { root }) do
      local cfg = configs[pane.group or "unstaged"]
      if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
        vim.api.nvim_win_set_config(pane.winid, cfg)
      elseif pane.bufnr and vim.api.nvim_buf_is_valid(pane.bufnr) then
        pane.winid = vim.api.nvim_open_win(pane.bufnr, false, cfg)
      end
      if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
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
  require("codediff.ui.view.actions.hunk").refresh_selection(session.tabpage)
  sync_chrome()
end

function M.close(session)
  local popup = session.popup
  popup.closing = true
  M.restore_chrome(session)
  if popup.dialog then
    popup.dialog.close()
  end
  local root = session.panel and session.panel.view
  require("codediff.ui.conflict.view.result").restore_maximize(session)
  local windows = { session.original_win, session.modified_win, session.result_win, session.base_win }
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
