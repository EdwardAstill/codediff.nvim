local M = {}

function M.open(ctx, opts)
  local session = require("codediff.ui.lifecycle").get_session(ctx.tabpage)
  local popup = session and session.popup
  if popup and popup.dialog then
    popup.dialog.close()
  end
  local return_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or { "" })
  vim.bo[buf].filetype = opts.filetype or "codediff-dialog"
  vim.bo[buf].modifiable = opts.editable == true
  local function geometry()
    local width = math.max(1, math.min(88, vim.o.columns - 4))
    local height = math.max(1, math.min(math.max(opts.editable and 10 or 4, vim.api.nvim_buf_line_count(buf)), vim.o.lines - vim.o.cmdheight - 4))
    return {
      relative = "editor", style = "minimal", border = "rounded", zindex = 90,
      width = width, height = height,
      row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
      title = " " .. opts.title .. " ", title_pos = "center",
      footer = " " .. (opts.footer or "q close") .. " ", footer_pos = "center",
    }
  end
  local win = vim.api.nvim_open_win(buf, false, geometry())
  vim.wo[win].wrap = true
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false
  vim.wo[win].winbar = ""
  local group = vim.api.nvim_create_augroup("CodeDiffDialog" .. buf, { clear = true })
  local closed = false
  local handle = { bufnr = buf, winid = win }
  function handle.close()
    if closed then return end
    closed = true
    vim.api.nvim_del_augroup_by_id(group)
    if popup and popup.dialog == handle then popup.dialog = nil end
    local focused = vim.api.nvim_get_current_win() == win
    if focused then vim.cmd("stopinsert") end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    if focused and not (popup and popup.closing) and vim.api.nvim_win_is_valid(return_win) then
      vim.api.nvim_set_current_win(return_win)
    end
  end
  if popup then popup.dialog = handle end
  vim.api.nvim_set_current_win(win)
  local function map(mode, key, callback, desc)
    vim.keymap.set(mode, key, callback, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  for _, key in ipairs({ "q", "<Esc>", "<C-q>" }) do map("n", key, handle.close, "Close dialog") end
  map("i", "<C-q>", handle.close, "Close dialog")
  map({ "n", "x" }, "s", "<Nop>", "Scratch buffer: no file save")
  map({ "n", "i", "x" }, "<C-s>", "<Nop>", "Scratch buffer: no file save")
  if not opts.editable then
    map("n", "i", "k", "Previous line")
    map("n", "k", "j", "Next line")
  end
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, geometry()) end
  end })
  vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), callback = function()
    vim.schedule(handle.close)
  end })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
    vim.schedule(handle.close)
  end })
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    if not vim.api.nvim_tabpage_is_valid(ctx.tabpage) then handle.close() end
  end })
  if opts.editable then vim.cmd("startinsert") end
  return handle
end

function M.confirm(ctx, title, lines, on_confirm)
  local handle = M.open(ctx, { title = title, lines = lines, footer = "y confirm   n/q/Esc cancel" })
  local accepted = false
  vim.keymap.set("n", "y", function()
    if accepted then return end
    accepted = true
    handle.close()
    on_confirm()
  end, { buffer = handle.bufnr, nowait = true, silent = true, desc = "Confirm action" })
  vim.keymap.set("n", "n", handle.close, { buffer = handle.bufnr, nowait = true, silent = true, desc = "Cancel action" })
  return handle
end

return M
