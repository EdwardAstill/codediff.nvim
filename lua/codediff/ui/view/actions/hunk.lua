-- Hunk-level actions: locate the hunk under the cursor, and stage, unstage or
-- discard it.
--
-- Every action takes the session context built by ui/view/keymaps.lua rather
-- than closing over buffers and layout flags, so a mapping installed for one
-- diff cannot act on a stale buffer after a file switch or layout change.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.refresh")

function M.find_hunk_at_cursor(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.stored_diff_result then
    return nil, nil
  end
  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return nil, nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  if session.popup and current_buf ~= session.original_bufnr and current_buf ~= session.modified_bufnr then
    return nil, nil
  end
  -- In inline mode, always use modified ranges
  local is_original = not ctx.is_inline and current_buf == ctx.original_bufnr
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  for i, mapping in ipairs(diff_result.changes) do
    local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
    local end_line = is_original and mapping.original.end_line or mapping.modified.end_line
    -- Check if cursor is within this hunk (end_line is exclusive)
    if current_line >= start_line and current_line < end_line then
      return mapping, i
    end
    -- Also match if it's a deletion (empty range) and cursor is at start
    if start_line == end_line and current_line == math.min(start_line, vim.api.nvim_buf_line_count(current_buf)) then
      return mapping, i
    end
  end
  return nil, nil
end

function M.clear_selection(tabpage)
  local session = lifecycle.get_session(tabpage)
  local selection = session and session.review_selection
  if not selection then
    return
  end
  for _, buf in ipairs(selection.buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, selection.ns, 0, -1)
    end
  end
  selection.buffers = {}
end

function M.refresh_selection(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.popup then
    return
  end
  local child = session.popup.dialog
  if child and vim.api.nvim_get_current_buf() == child.bufnr and not session.closing then
    return
  end
  M.clear_selection(tabpage)
  if session.closing or vim.api.nvim_get_current_tabpage() ~= tabpage then
    return
  end
  session.review_selection = session.review_selection or {
    ns = vim.api.nvim_create_namespace("codediff-review-selection-" .. tabpage),
  }
  local selection = session.review_selection
  local hunk, index = M.find_hunk_at_cursor({
    tabpage = tabpage, original_bufnr = session.original_bufnr,
    modified_bufnr = session.modified_bufnr, is_inline = session.layout == "inline",
  })
  local changes = session.stored_diff_result and session.stored_diff_result.changes or {}
  local staged = session.modified_revision == ":0"
  local footer = string.format(" Hunk %s/%d   s %s   %sh help ",
    index or "-", #changes, staged and "unstage" or "stage", staged and "" or "r reject   ")
  vim.api.nvim_set_hl(0, "CodeDiffActiveHunk", { bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, "CodeDiffActiveHunkSign", { link = "DiagnosticWarn", default = true })
  for _, side in ipairs({ "original", "modified" }) do
    local win, buf = session[side .. "_win"], session[side .. "_bufnr"]
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "center" })
    end
    if hunk and buf and vim.api.nvim_buf_is_valid(buf) then
      selection.buffers = selection.buffers or {}
      table.insert(selection.buffers, buf)
      local count = vim.api.nvim_buf_line_count(buf)
      local first = math.max(1, math.min(hunk[side].start_line, count))
      local last = math.max(first, math.min(hunk[side].end_line - 1, count))
      for row = first - 1, last - 1 do
        vim.api.nvim_buf_set_extmark(buf, selection.ns, row, 0, {
          number_hl_group = "CodeDiffActiveHunk",
          sign_text = ">", sign_hl_group = "CodeDiffActiveHunkSign", priority = 220,
        })
      end
    end
  end
end

function M.setup_selection(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.popup then
    return
  end
  local group = vim.api.nvim_create_augroup("codediff_review_selection_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter", "BufEnter", "TabEnter" }, {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_tabpage() == tabpage then
        M.refresh_selection(tabpage)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = group, callback = function() M.clear_selection(tabpage) end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "CodeDiffClose", callback = function(event)
      if event.data and event.data.tabpage == tabpage then
        M.clear_selection(tabpage)
        vim.api.nvim_del_augroup_by_id(group)
      end
    end,
  })
  M.refresh_selection(tabpage)
end

local function build_hunk_patch(file_path, orig_lines, mod_lines, orig_start, mod_start, new_file, deleted_file)
  orig_lines = new_file and {} or orig_lines
  mod_lines = deleted_file and {} or mod_lines
  local orig_count = #orig_lines
  local mod_count = #mod_lines

  -- For pure insertions with 0 original lines, git expects start to be
  -- the line AFTER which content is inserted (0 if at very start)
  local hdr_orig_start = orig_count == 0 and (orig_start > 0 and orig_start - 1 or 0) or orig_start
  local hdr_mod_start = mod_count == 0 and (mod_start > 0 and mod_start - 1 or 0) or mod_start

  local function header(prefix)
    return '"' .. (prefix .. file_path):gsub('[%c\\"]', function(char)
      return string.format("\\%03o", string.byte(char))
    end) .. '"'
  end
  local parts = {
    "--- " .. (new_file and "/dev/null" or header("a/")),
    "+++ " .. (deleted_file and "/dev/null" or header("b/")),
    string.format("@@ -%d,%d +%d,%d @@", hdr_orig_start, orig_count, hdr_mod_start, mod_count),
  }

  for _, line in ipairs(orig_lines) do
    table.insert(parts, "-" .. line)
  end
  for _, line in ipairs(mod_lines) do
    table.insert(parts, "+" .. line)
  end

  -- Patch must end with a newline
  return table.concat(parts, "\n") .. "\n"
end

function M.stage_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow staging from unstaged views (working tree changes)
  if session.modified_revision ~= nil or (session.original_revision ~= ":0" and session.original.relative ~= "") then
    vim.notify("Stage only works on unstaged changes", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  -- Get the file path relative to git root
  local file_path = (session.modified.relative ~= "" and session.modified.relative) or session.original.relative
  if not file_path or file_path == "" then
    vim.notify("No file path for staging", vim.log.levels.WARN)
    return
  end

  local stage_orig_buf, stage_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not stage_orig_buf or not stage_mod_buf or not vim.api.nvim_buf_is_valid(stage_orig_buf) or not vim.api.nvim_buf_is_valid(stage_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Read lines from both buffers for this hunk
  local orig_lines = vim.api.nvim_buf_get_lines(stage_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)
  local mod_lines = vim.api.nvim_buf_get_lines(stage_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false)

  local patch = build_hunk_patch(file_path, orig_lines, mod_lines, hunk.original.start_line, hunk.modified.start_line,
    session.original.relative == "", session.modified.relative == "")

  local git = require("codediff.core.git")
  git.apply_patch(session.git_root, patch, false, function(err)
    if err then
      vim.notify("Failed to stage hunk: " .. err, vim.log.levels.ERROR)
      return
    end
    refresh.request(ctx.tabpage, { full = true })
    vim.notify(string.format("Staged hunk %d", hunk_idx), vim.log.levels.INFO)
  end)
end

function M.unstage_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow unstaging from staged views
  if session.modified_revision ~= ":0" then
    vim.notify("Unstage only works on staged changes", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  local file_path = (session.modified.relative ~= "" and session.modified.relative) or session.original.relative
  if not file_path or file_path == "" then
    vim.notify("No file path for unstaging", vim.log.levels.WARN)
    return
  end

  local unstage_orig_buf, unstage_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not unstage_orig_buf or not unstage_mod_buf or not vim.api.nvim_buf_is_valid(unstage_orig_buf) or not vim.api.nvim_buf_is_valid(unstage_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Read lines from both buffers for this hunk
  local orig_lines = vim.api.nvim_buf_get_lines(unstage_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)
  local mod_lines = vim.api.nvim_buf_get_lines(unstage_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false)

  local patch = build_hunk_patch(file_path, orig_lines, mod_lines, hunk.original.start_line, hunk.modified.start_line,
    session.original.relative == "", session.modified.relative == "")

  local git = require("codediff.core.git")
  git.apply_patch(session.git_root, patch, true, function(err)
    if err then
      vim.notify("Failed to unstage hunk: " .. err, vim.log.levels.ERROR)
      return
    end
    refresh.request(ctx.tabpage, { full = true })
    vim.notify(string.format("Unstaged hunk %d", hunk_idx), vim.log.levels.INFO)
  end)
end

-- Keep Git's patch bytes: rebuilding from decoded buffers loses encoding/EOL.
local function review_patch(session, path)
  local args = {
    "git", "--no-optional-locks", "--literal-pathspecs", "diff",
    "--no-ext-diff", "--no-textconv", "--no-renames", "--binary",
    "--no-color", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/",
  }
  local untracked = session.original.relative == ""
  if untracked then
    vim.list_extend(args, { "--no-index", "--", "/dev/null", path })
  else
    vim.list_extend(args, { "--", path })
  end
  local result = vim.system(args, { cwd = session.git_root, text = false }):wait()
  if result.code ~= 0 and not (untracked and result.code == 1) then
    return nil, result.stderr
  end
  return result.stdout
end

local function selected_patch(patch, hunk)
  local header, hunks, current = {}, {}, nil
  for line in patch:gmatch("[^\n]*\n") do
    local os, oc, ms, mc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      os, ms = tonumber(os), tonumber(ms)
      oc, mc = tonumber(oc) or 1, tonumber(mc) or 1
      os, ms = os + (oc == 0 and 1 or 0), ms + (mc == 0 and 1 or 0)
      current = { lines = {}, original = { os, oc }, modified = { ms, mc } }
      table.insert(hunks, current)
    end
    if current then
      table.insert(current.lines, line)
    elseif not line:match("^old mode ") and not line:match("^new mode ") then
      table.insert(header, line)
    end
  end
  local count = 0
  for _, chunk in ipairs(hunks) do
    local contained, overlaps = true, false
    for _, side in ipairs({ "original", "modified" }) do
      local start, size = unpack(chunk[side])
      local range = hunk[side]
      contained = contained and start >= range.start_line and start + size <= range.end_line
      overlaps = overlaps or (size == 0 and start >= range.start_line and start < range.end_line)
        or (size > 0 and start < range.end_line and start + size > range.start_line)
    end
    if overlaps and not contained then
      return nil
    end
    if contained then
      vim.list_extend(header, chunk.lines)
      count = count + 1
    end
  end
  return count > 0 and table.concat(header) or nil
end

local function reject_review_hunk(ctx, session, hunk, index)
  if session.modified_revision ~= nil or (session.original_revision ~= ":0" and session.original.relative ~= "") then
    vim.notify("Unstage this hunk before rejecting it", vim.log.levels.WARN)
    return
  end
  local path = session.modified.relative ~= "" and session.modified.relative or session.original.relative
  if not path or path == "" then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end
  local full_path = session.git_root .. "/" .. path
  local buffers, ticks = {}, {}
  local function clean_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == full_path then
        if vim.bo[buf].modified then
          vim.notify("Unsaved file: press q, save in the editor, then reopen review before rejecting", vim.log.levels.WARN)
          return false
        end
        buffers[buf] = true
      end
    end
    return true
  end
  if not clean_buffers() then
    return
  end
  for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    ticks[buf] = vim.api.nvim_buf_get_changedtick(buf)
  end
  local patch, err = review_patch(session, path)
  if not patch then
    vim.notify("Cannot read hunk: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local selected = selected_patch(patch, hunk)
  if not selected then
    vim.notify("Hunk no longer matches the working tree; refresh review first", vim.log.levels.WARN)
    refresh.request(ctx.tabpage, { full = true })
    return
  end
  local diff = session.stored_diff_result
  local original, modified = session.original_bufnr, session.modified_bufnr
  local generation = session.refresh and session.refresh.generation
  require("codediff.ui.dialog").confirm(ctx, "Reject unstaged hunk", {
    path,
    string.format("Reject hunk %d of %d? This cannot be undone by Git.", index, #diff.changes),
    "Only this unstaged hunk is removed. Staged changes are kept.",
  }, function()
    if lifecycle.get_session(ctx.tabpage) ~= session or session.closing
      or session.original_bufnr ~= original or session.modified_bufnr ~= modified
      or session.stored_diff_result ~= diff or session.modified_revision ~= nil
      or (session.refresh and session.refresh.generation ~= generation) then
      vim.notify("Review changed; select the hunk again", vim.log.levels.WARN)
      return
    end
    if not clean_buffers() then
      return
    end
    for buf, tick in pairs(ticks) do
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        vim.notify("Buffer changed; select the hunk again", vim.log.levels.WARN)
        return
      end
    end
    local current, read_err = review_patch(session, path)
    if current ~= patch then
      vim.notify("File or index changed; reject cancelled" .. (read_err and ": " .. read_err or ""), vim.log.levels.WARN)
      refresh.request(ctx.tabpage, { full = true })
      return
    end
    -- Git validates the reverse patch before writing; never touch the index.
    local result = vim.system({ "git", "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-" }, {
      cwd = session.git_root, stdin = selected, text = false,
    }):wait()
    if result.code ~= 0 then
      vim.notify("Failed to reject hunk: " .. (result.stderr or ""), vim.log.levels.ERROR)
      return
    end
    for buf in pairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
        -- Native reload decodes the file and retains its encoding/EOL options.
        local ok, reload_err = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent noautocmd edit!")
        end)
        if not ok then
          vim.notify("Hunk rejected, but buffer reload failed: " .. tostring(reload_err), vim.log.levels.ERROR)
        end
      end
    end
    refresh.request(ctx.tabpage, { full = true })
    vim.notify(string.format("Rejected hunk %d", index), vim.log.levels.INFO)
  end)
end

function M.discard_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow discarding in unstaged views (working tree changes)
  if session.modified_revision ~= nil then
    vim.notify(session.popup and "Unstage this hunk before rejecting it" or "Discard only works on unstaged changes (working tree)", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  if session.popup then
    reject_review_hunk(ctx, session, hunk, hunk_idx)
    return
  end

  -- Prompt for confirmation before discarding (destructive operation)
  local prompt = string.format("Discard hunk %d?", hunk_idx)
  local choice = vim.fn.confirm(prompt, "&Discard\n&Cancel", 2, "Warning")
  if choice ~= 1 then
    return
  end

  local discard_orig_buf, discard_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not discard_orig_buf or not discard_mod_buf or not vim.api.nvim_buf_is_valid(discard_orig_buf) or not vim.api.nvim_buf_is_valid(discard_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Replace the modified hunk range with the original lines. Every other line
  -- (including unrelated unsaved edits) stays as-is in the live buffer, so the
  -- discarded region falls back to original content and nothing else changes.
  local orig_lines = vim.api.nvim_buf_get_lines(discard_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)

  local was_modifiable = vim.bo[discard_mod_buf].modifiable
  local was_readonly = vim.bo[discard_mod_buf].readonly

  local ok, edit_err = pcall(function()
    vim.bo[discard_mod_buf].readonly = false
    vim.bo[discard_mod_buf].modifiable = true
    vim.api.nvim_buf_set_lines(discard_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false, orig_lines)
    -- Persist through the native write path so 'fileformat', 'fileencoding'
    -- and 'endofline' are honored. 'noautocmd' keeps format-on-save (and
    -- similar BufWritePre hooks) from rewriting lines outside the hunk.
    vim.api.nvim_buf_call(discard_mod_buf, function()
      vim.cmd("silent noautocmd write!")
    end)
  end)

  if vim.api.nvim_buf_is_valid(discard_mod_buf) then
    vim.bo[discard_mod_buf].modifiable = was_modifiable
    vim.bo[discard_mod_buf].readonly = was_readonly
  end

  if not ok then
    vim.notify("Failed to discard hunk: " .. tostring(edit_err), vim.log.levels.ERROR)
    return
  end

  refresh.buffer_changed(discard_mod_buf)
  vim.notify(string.format("Discarded hunk %d", hunk_idx), vim.log.levels.INFO)
end

--- Visually select the hunk under the cursor, for the `ih` textobject.
--- @param ctx CodeDiffActionContext
function M.select_hunk(ctx)
  local mapping = M.find_hunk_at_cursor(ctx)
  if not mapping then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local is_original = current_buf == ctx.original_bufnr
  local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
  local end_line = is_original and mapping.original.end_line or mapping.modified.end_line

  -- end_line is exclusive, and empty ranges (deletions) can't be selected
  if start_line >= end_line then
    return
  end

  vim.cmd("normal! " .. start_line .. "GV" .. (end_line - 1) .. "G")
end

return M
