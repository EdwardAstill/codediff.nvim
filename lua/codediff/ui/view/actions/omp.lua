local M = {}
local return_group = vim.api.nvim_create_augroup("CodeDiffOmpReturn", { clear = true })

local function warn(message)
  vim.notify(message, vim.log.levels.WARN, { title = "CodeDiff → OMP" })
end

local function capture(ctx)
  local session = require("codediff.ui.lifecycle").get_session(ctx.tabpage)
  if not session then return end
  local current = vim.api.nvim_get_current_buf()
  if current ~= session.original_bufnr and current ~= session.modified_bufnr then
    warn("Select a hunk in a diff pane first")
    return
  end
  local hunk = require("codediff.ui.view.actions.hunk").find_hunk_at_cursor(ctx)
  if not hunk then
    warn("No hunk at cursor position")
    return
  end

  local parts = { "Repository: " .. vim.json.encode(session.git_root or "(none)") }
  local sides = {}
  for _, side in ipairs({ "original", "modified" }) do
    local buf, path = session[side .. "_bufnr"], session[side]
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      warn("Diff buffers are no longer available")
      return
    end
    if session.changedtick and session.changedtick[side] ~= vim.api.nvim_buf_get_changedtick(buf) then
      warn("Diff is updating; select the hunk again when it settles")
      return
    end
    local missing = not path or path.absolute == ""
    local range = hunk[side]
    local lines = missing and {} or vim.api.nvim_buf_get_lines(buf, range.start_line - 1, range.end_line - 1, true)
    local revision = session[side .. "_revision"] or "WORKTREE"
    local label = side == "original" and "Before (left)" or "After (right)"
    local source = session.source_revisions and session.source_revisions[side]
    parts[#parts + 1] = label .. ": " .. vim.json.encode(revision)
      .. (source and source ~= revision and " (requested " .. vim.json.encode(source) .. ")" or "")
    parts[#parts + 1] = label .. " file: " .. vim.json.encode(missing and "/dev/null" or path.absolute)
    sides[side] = {
      lines = lines,
      start = #lines == 0 and math.max(0, range.start_line - 1) or range.start_line,
      path = missing and "/dev/null" or vim.json.encode((side == "original" and "a/" or "b/") .. (path.relative ~= "" and path.relative or path.absolute)),
    }
  end
  local before, after = sides.original, sides.modified
  parts[#parts + 1] = ""
  parts[#parts + 1] = "--- " .. before.path
  parts[#parts + 1] = "+++ " .. after.path
  parts[#parts + 1] = string.format("@@ -%d,%d +%d,%d @@", before.start, #before.lines, after.start, #after.lines)
  for _, line in ipairs(before.lines) do parts[#parts + 1] = "-" .. line end
  for _, line in ipairs(after.lines) do parts[#parts + 1] = "+" .. line end
  return table.concat(parts, "\n") .. "\n", session
end

function M.send_hunk(ctx)
  -- Capture both sides before the composer changes the current buffer or file.
  local payload, session = capture(ctx)
  if not payload then return end
  local return_win = vim.api.nvim_get_current_win()
  local dialog = require("codediff.ui.dialog").open(ctx, {
    title = "Send hunk to OMP — optional message",
    lines = { "" }, editable = true, filetype = "markdown",
    footer = "Ctrl-s add hunk + message to OMP draft   Ctrl-q cancel",
  })
  local sent = false
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    if sent or not vim.api.nvim_buf_is_valid(dialog.bufnr) then return end
    local ok, omp = pcall(require, "omp")
    if not ok or type(omp.send) ~= "function" then
      warn("OMP integration is unavailable; message and hunk kept here for retry")
      return
    end
    local message = table.concat(vim.api.nvim_buf_get_lines(dialog.bufnr, 0, -1, false), "\n")
    local text = (message:find("%S") and message .. "\n\n" or "") .. payload
    local accepted
    ok, accepted = pcall(omp.send, text)
    if not ok or not accepted then
      if type(omp.hide) == "function" then pcall(omp.hide) end
      if vim.api.nvim_win_is_valid(dialog.winid) then
        vim.api.nvim_set_current_win(dialog.winid)
        vim.cmd("startinsert")
      end
      warn("Could not stage OMP draft" .. (not ok and ": " .. tostring(accepted) or "") .. "; message and hunk kept here for retry")
      return
    end
    sent = true
    local omp_win = vim.api.nvim_get_current_win()
    dialog.close()
    -- Keep the review open underneath OMP; closing it could discard unsaved work.
    if omp_win ~= dialog.winid and vim.api.nvim_win_is_valid(omp_win) then
      local config = vim.api.nvim_win_get_config(omp_win)
      if config.relative ~= "" then
        vim.api.nvim_win_set_config(omp_win, { zindex = math.max(config.zindex or 50, 100) })
      end
      vim.api.nvim_set_current_win(omp_win)
      vim.api.nvim_clear_autocmds({ group = return_group, event = "WinClosed", pattern = tostring(omp_win) })
      vim.api.nvim_create_autocmd("WinClosed", {
        group = return_group, pattern = tostring(omp_win), once = true,
        callback = function()
          vim.schedule(function()
            if require("codediff.ui.lifecycle").get_session(ctx.tabpage) == session
              and vim.api.nvim_get_current_tabpage() == ctx.tabpage
              and vim.api.nvim_win_is_valid(return_win) then
              vim.api.nvim_set_current_win(return_win)
            end
          end)
        end,
      })
    end
    -- send() acknowledges queueing only; OMP reports asynchronous bridge failures.
  end, { buffer = dialog.bufnr, silent = true, nowait = true, desc = "Add selected hunk to OMP draft" })
  return dialog
end

return M
