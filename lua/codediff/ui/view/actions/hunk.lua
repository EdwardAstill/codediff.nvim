-- Hunk-level actions: locate the hunk under the cursor, and stage, unstage or
-- revert it in the working tree without changing the index.
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
  local footer = string.format(" Hunk %s/%d   s %s   r revert   o OMP   h help ",
    index or "-", #changes, staged and "unstage" or "stage")
  vim.api.nvim_set_hl(0, "CodeDiffActiveHunk", { bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, "CodeDiffActiveHunkSign", { link = "DiagnosticWarn", default = true })
  for _, side in ipairs({ "original", "modified" }) do
    local win, buf = session[side .. "_win"], session[side .. "_bufnr"]
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      local label = vim.api.nvim_win_get_width(win) >= #footer and footer or footer:gsub("   o OMP", "")
      vim.api.nvim_win_set_config(win, { footer = label, footer_pos = "center" })
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
local function review_patch(session, path, worktree)
  local args = {
    "git", "--no-optional-locks", "--literal-pathspecs", "diff",
    "--no-ext-diff", "--no-textconv", "--no-renames", "--binary",
    "--no-color", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/",
  }
  local staged = session.modified_revision == ":0"
  local untracked = session.original.relative == "" and (not staged or worktree)
  if untracked then
    vim.list_extend(args, { "--no-index", "--", "/dev/null", path })
  else
    if staged and not worktree then
      table.insert(args, "--cached")
    end
    if session.original_revision and session.original_revision ~= ":0" then
      table.insert(args, session.original_revision)
    end
    vim.list_extend(args, { "--", path })
  end
  local result = vim.system(args, { cwd = session.git_root, text = false }):wait()
  if result.code ~= 0 and not (untracked and result.code == 1) then
    return nil, result.stderr
  end
  return result.stdout
end

local function selected_patch(patch, hunk, original_only, session)
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
  local signatures = {}
  for _, chunk in ipairs(hunks) do
    local contained, overlaps = true, false
    for _, side in ipairs(original_only and { "original" } or { "original", "modified" }) do
      local start, size = unpack(chunk[side])
      local range = hunk[side]
      contained = contained and start >= range.start_line and start + size <= range.end_line
      overlaps = overlaps or (size == 0 and start >= range.start_line and start <= range.end_line)
        or (size > 0 and start <= range.end_line and start + size >= range.start_line)
    end
    if overlaps and not contained then
      return nil
    end
    if contained then
      if session then
        local rows = { original = chunk.original[1], modified = chunk.modified[1] }
        for _, line in ipairs(chunk.lines) do
          local side = line:sub(1, 1) == "-" and "original" or line:sub(1, 1) == "+" and "modified" or nil
          if side then
            local buf = session[side .. "_bufnr"]
            local expected = vim.api.nvim_buf_get_lines(buf, rows[side] - 1, rows[side], false)[1]
            local value = line:sub(2, -2)
            if vim.bo[buf].buftype ~= "" or vim.bo[buf].fileformat == "dos" then
              value = value:gsub("\r$", "")
            end
            local encoding = vim.bo[buf].fileencoding
            if vim.bo[buf].buftype == "" and encoding ~= "" and encoding ~= "utf-8" then
              value = vim.iconv(value, encoding, "utf-8")
            end
            if not expected or expected ~= value then
              return nil
            end
            rows[side] = rows[side] + 1
          end
        end
      end
      vim.list_extend(header, chunk.lines)
      signatures[#signatures + 1] = string.format("%d,%d,%d\n", chunk.original[1], chunk.original[2], chunk.modified[2])
        .. table.concat(chunk.lines, "", 2)
    end
  end
  return #signatures > 0 and table.concat(header) or nil, table.concat(signatures)
end

local function revert_selected_hunk(ctx, session, hunk, index)
  local path = session.modified.relative ~= "" and session.modified.relative or session.original.relative
  if not path or path == "" then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end
  local full_path = session.git_root .. "/" .. path
  if session.original.relative ~= "" and session.modified.relative ~= ""
    and session.original.relative ~= session.modified.relative then
    vim.notify("Revert cannot safely match a renamed comparison", vim.log.levels.WARN)
    return
  end
  local function worktree_bytes()
    local stat = (vim.uv or vim.loop).fs_lstat(full_path)
    if not stat then
      return false
    end
    if stat.type ~= "file" then
      return nil
    end
    local file = io.open(full_path, "rb")
    if not file then
      return nil
    end
    local content = file:read("*a")
    file:close()
    return content
  end
  local working = worktree_bytes()
  if working == nil or (session.modified.relative == "" and working ~= false) then
    vim.notify("Working file conflicts with the selected hunk or is already restored", vim.log.levels.WARN)
    return
  end
  local function index_state()
    local result = vim.system({ "git", "--no-optional-locks", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", path }, {
      cwd = session.git_root, text = false,
    }):wait()
    return result.code == 0 and result.stdout or nil
  end
  local indexed = index_state()
  if not indexed then
    vim.notify("Cannot read index; revert cancelled", vim.log.levels.ERROR)
    return
  end
  local buffers, ticks = {}, {}
  local function clean_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == full_path then
        if vim.bo[buf].modified then
          vim.notify("Unsaved file: save in the editor and refresh before reverting", vim.log.levels.WARN)
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
  local selected, signature = selected_patch(patch, hunk, false, session)
  if session.modified_revision == ":0" and selected then
    local work_patch = review_patch(session, path, true)
    local work_selected, work_signature
    if work_patch then
      work_selected, work_signature = selected_patch(work_patch, hunk, true)
    end
    selected = work_signature == signature and work_selected or nil
  end
  if not selected then
    vim.notify("Hunk is stale, already reverted, or conflicts with the working file; refresh first", vim.log.levels.WARN)
    refresh.request(ctx.tabpage, { full = true })
    return
  end
  local diff = session.stored_diff_result
  local original, modified = session.original_bufnr, session.modified_bufnr
  local generation = session.refresh and session.refresh.generation
  local original_revision, modified_revision = session.original_revision, session.modified_revision
  local baseline = session.original.relative == "" and "empty file"
    or original_revision == ":0" and "index"
    or (session.source_revisions and session.source_revisions.original) or original_revision
  local lines = {
    path,
    string.format("Revert hunk %d of %d in the working file to LEFT (%s)?", index, #diff.changes, baseline),
    "The index stays unchanged. Unstaged working edits may not be recoverable by Git.",
  }
  local function apply()
    if lifecycle.get_session(ctx.tabpage) ~= session or session.closing
      or session.original_bufnr ~= original or session.modified_bufnr ~= modified
      or session.stored_diff_result ~= diff or session.modified_revision ~= modified_revision
      or session.original_revision ~= original_revision
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
    if current ~= patch or worktree_bytes() ~= working or index_state() ~= indexed then
      vim.notify("File or index changed; revert cancelled" .. (read_err and ": " .. read_err or ""), vim.log.levels.WARN)
      refresh.request(ctx.tabpage, { full = true })
      return
    end
    -- Git validates the reverse patch before writing; never touch the index.
    local result = vim.system({ "git", "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-" }, {
      cwd = session.git_root, stdin = selected, text = false,
    }):wait()
    if result.code ~= 0 then
      vim.notify("Failed to revert hunk: " .. (result.stderr or ""), vim.log.levels.ERROR)
      return
    end
    for buf in pairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
        -- Native reload decodes the file and retains its encoding/EOL options.
        local ok, reload_err = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent noautocmd edit!")
        end)
        if not ok then
          vim.notify("Hunk reverted, but buffer reload failed: " .. tostring(reload_err), vim.log.levels.ERROR)
        end
      end
    end
    refresh.request(ctx.tabpage, { full = true })
    vim.notify(string.format("Reverted hunk %d; index unchanged", index), vim.log.levels.INFO)
  end
  if session.popup then
    require("codediff.ui.dialog").confirm(ctx, "Revert hunk", lines, apply)
  elseif vim.fn.confirm(table.concat(lines, "\n"), "&Revert\n&Cancel", 2, "Warning") == 1 then
    apply()
  end
end

function M.revert_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  if (session.modified_revision ~= nil and session.modified_revision ~= "WORKING" and session.modified_revision ~= ":0")
    or (session.original.relative ~= "" and (not session.original_revision or session.original_revision == "WORKING"))
    or session.merge then
    vim.notify("Revert needs a working-tree or staged comparison with a Git LEFT baseline", vim.log.levels.WARN)
    return
  end
  if ctx.original_bufnr ~= session.original_bufnr or ctx.modified_bufnr ~= session.modified_bufnr then
    vim.notify("Comparison changed; select the hunk again", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  revert_selected_hunk(ctx, session, hunk, hunk_idx)
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
