local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local dialog = require("codediff.ui.dialog")

local function run(root, args, callback, stdin, env)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  vim.system(argv, { stdin = stdin, env = env }, vim.schedule_wrap(callback))
end

local function error_text(result)
  local text = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
  return text ~= "" and text or ("Git exited with status " .. result.code)
end

local function report(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function context(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root or not session.popup then
    vim.notify("Repository actions require a Git review popup", vim.log.levels.WARN)
    return
  end
  if session.popup.repository_busy then
    vim.notify("A repository action is still running", vim.log.levels.WARN)
    return
  end
  return session
end

local function alive(session, handle)
  return lifecycle.get_session(session.tabpage) == session
    and session.popup.dialog == handle and vim.api.nvim_buf_is_valid(handle.bufnr)
end

local head = require("codediff.core.git.revision").get_head

local function same_head(a, b)
  return a.ref == b.ref and a.oid == b.oid
end

local function refresh(session)
  if lifecycle.get_session(session.tabpage) == session then
    require("codediff.ui.refresh").request(session.tabpage, { full = true })
  end
end

function M.commit(ctx)
  local session = context(ctx)
  if not session then return end
  local handle = dialog.open(ctx, { title = "Commit: reading HEAD", lines = { "" }, editable = true,
    filetype = "gitcommit", footer = "Ctrl-s commit staged changes   Ctrl-q cancel" })
  local displayed_head, submitting
  head(session.git_root, function(err, value)
    if not alive(session, handle) then return end
    if err then report(err); return end
    displayed_head = value
    vim.api.nvim_win_set_config(handle.winid, { title = " Commit: " .. value.label .. " " })
  end)
  local function submit()
    if submitting or not displayed_head or not alive(session, handle) then return end
    local message = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    if vim.trim(message) == "" then report("Commit message is empty; draft kept"); return end
    submitting = true
    session.popup.repository_busy = true
    vim.cmd("stopinsert")
    vim.bo[handle.bufnr].modifiable = false
    local function failed(message_text)
      submitting = false
      session.popup.repository_busy = nil
      if alive(session, handle) then vim.bo[handle.bufnr].modifiable = true end
      report(message_text .. "\nCommit draft kept until you close the dialog.")
      if alive(session, handle) and vim.api.nvim_get_current_win() == handle.winid then vim.cmd("startinsert") end
    end
    head(session.git_root, function(err, current)
      if err then failed(err); return end
      if not same_head(displayed_head, current) then failed("HEAD changed; cancel and reopen Commit before submitting"); return end
      if not alive(session, handle) then session.popup.repository_busy = nil; return end
      run(session.git_root, { "diff", "--cached", "--quiet", "--exit-code" }, function(staged)
        if staged.code ~= 0 and staged.code ~= 1 then failed(error_text(staged)); return end
        local function execute()
          if not alive(session, handle) then session.popup.repository_busy = nil; return end
          -- Feed only the draft to Git; HEAD and help are window chrome, never message text.
          run(session.git_root, { "commit", "--cleanup=verbatim", "--file=-" }, function(result)
            if result.code ~= 0 then failed(error_text(result)); return end
            session.popup.repository_busy = nil
            if alive(session, handle) then handle.close() end
            refresh(session)
            vim.notify("Committed staged changes on " .. displayed_head.label, vim.log.levels.INFO)
          end, message .. "\n")
        end
        if staged.code == 1 then execute(); return end
        run(session.git_root, { "rev-parse", "--verify", "--quiet", "MERGE_HEAD^{commit}" }, function(pending)
          if not alive(session, handle) then session.popup.repository_busy = nil; return end
          if pending.code == 1 then failed("No staged changes; nothing committed"); return end
          if pending.code ~= 0 then failed(error_text(pending)); return end
          execute()
        end)
      end)
    end)
  end
  vim.keymap.set("n", "s", submit, { buffer = handle.bufnr, silent = true, desc = "Commit staged changes" })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = handle.bufnr, silent = true, desc = "Commit staged changes" })
  return handle
end

local function path_key(path)
  return vim.fs.normalize((vim.uv or vim.loop).fs_realpath(path) or path, { expand_env = false })
end

local function tracked_buffers(root, paths)
  local tracked, buffers = {}, {}
  for _, path in ipairs(vim.split(paths, "\0", { plain = true, trimempty = true })) do
    tracked[path_key(root .. "/" .. path)] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and tracked[path_key(vim.api.nvim_buf_get_name(buf))] then
      buffers[#buffers + 1] = buf
    end
  end
  return buffers
end

local function unsaved(buffers)
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      return vim.api.nvim_buf_get_name(buf)
    end
  end
end

local function reload_buffers(buffers, action)
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      if vim.bo[buf].modified then
        vim.notify("Buffer changed while " .. action .. "; kept unsaved edits: " .. vim.fn.strtrans(vim.api.nvim_buf_get_name(buf)), vim.log.levels.WARN)
      else
        local autoread = vim.bo[buf].autoread
        vim.bo[buf].autoread = true
        local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
          local _, _, code = (vim.uv or vim.loop).fs_stat(vim.api.nvim_buf_get_name(buf))
          if code == "ENOENT" then
            local modifiable = vim.bo[buf].modifiable
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
            vim.bo[buf].modified = false
            vim.bo[buf].modifiable = modifiable
          else
            vim.cmd("checktime " .. buf)
          end
        end)
        vim.bo[buf].autoread = autoread
        if not ok then report("Could not reload buffer after " .. action .. ": " .. err) end
      end
    end
  end
end

function M.stash(ctx)
  local session = context(ctx)
  if not session then return end
  local loading = dialog.open(ctx, { title = "Stash", lines = { "Reading HEAD..." } })
  head(session.git_root, function(err, displayed_head)
    if not alive(session, loading) then return end
    if err then report(err); return end
    if not displayed_head.oid then report("Cannot stash an unborn HEAD"); return end
    dialog.confirm(ctx, "Stash: " .. displayed_head.label, {
      "Stash staged and unstaged tracked changes on:", displayed_head.label, "",
      "The index and tracked worktree changes will be saved, then reset to HEAD.",
      "Untracked files stay in place. Unsaved tracked buffers cancel this action.",
    }, function()
      if lifecycle.get_session(ctx.tabpage) ~= session or session.popup.repository_busy then return end
      session.popup.repository_busy = true
      local function failed(message)
        session.popup.repository_busy = nil
        report(message)
      end
      head(session.git_root, function(head_err, current)
        if head_err then failed(head_err); return end
        if not same_head(displayed_head, current) then failed("HEAD changed; stash cancelled"); return end
        -- Include HEAD paths as well as index paths: staged deletions still affect loaded buffers.
        run(session.git_root, { "ls-tree", "-rz", "--name-only", "HEAD" }, function(before)
          if before.code ~= 0 then failed(error_text(before)); return end
          run(session.git_root, { "ls-files", "--cached", "-z" }, function(index)
            if index.code ~= 0 then failed(error_text(index)); return end
            local buffers = tracked_buffers(session.git_root, before.stdout .. index.stdout)
            local dirty = unsaved(buffers)
            if dirty then failed("Stash cancelled: unsaved tracked buffer " .. vim.fn.strtrans(dirty)); return end
            if lifecycle.get_session(ctx.tabpage) ~= session then session.popup.repository_busy = nil; return end
            run(session.git_root, { "stash", "push" }, function(result)
              session.popup.repository_busy = nil
              if result.code ~= 0 then report(error_text(result)); return end
              reload_buffers(buffers, "stashing")
              refresh(session)
              vim.notify(vim.trim(result.stdout or ""), vim.log.levels.INFO)
            end)
          end)
        end)
      end)
    end)
  end)
  return loading
end

local function root_buffers(root)
  local buffers, prefix = {}, path_key(root):gsub("/+$", "") .. "/"
  local lexical = vim.fs.normalize(root, { expand_env = false }):gsub("/+$", "") .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and (path_key(name):sub(1, #prefix) == prefix or vim.fs.normalize(name, { expand_env = false }):sub(1, #lexical) == lexical) then
        buffers[#buffers + 1] = buf
      end
    end
  end
  return buffers
end

local function worktree_destination(root, destination, callback)
  local uv = vim.uv or vim.loop
  local stat, err, code = uv.fs_lstat(destination)
  if stat then
    local scan = stat.type == "directory" and uv.fs_scandir(destination)
    if not scan or uv.fs_scandir_next(scan) then callback("Worktree destination already exists and is not an empty directory"); return end
  elseif code ~= "ENOENT" then callback(err); return end
  local parent = stat and destination or vim.fs.dirname(destination)
  while parent do
    local parent_stat, parent_err, parent_code = uv.fs_stat(parent)
    if parent_stat then
      if parent_stat.type ~= "directory" then callback("Worktree parent is not a directory"); return end
      local writable, access_error = uv.fs_access(parent, "W")
      if not writable then callback(access_error); return end
      break
    end
    if parent_code ~= "ENOENT" then callback(parent_err); return end
    local next_parent = vim.fs.dirname(parent)
    if next_parent == parent then callback("Worktree parent does not exist"); return end
    parent = next_parent
  end
  -- Git creates -b before checking the destination; preflight without changing refs.
  run(root, { "worktree", "list", "--porcelain", "-z" }, function(result)
    if result.code ~= 0 then callback(error_text(result)); return end
    for _, field in ipairs(vim.split(result.stdout or "", "\0", { plain = true })) do
      local path = field:match("^worktree (.*)$")
      if path and path_key(path) == path_key(destination) then
        callback("Worktree destination is already registered: " .. vim.fn.strtrans(destination)); return
      end
    end
    callback()
  end)
end

-- One gate owns navigation mutations, draft lifetime, and checkout protection.
local function mutate(session, handle, displayed_head, args, new_branch, checkout, done, destination)
  if not alive(session, handle) or session.popup.repository_busy then return end
  session.popup.repository_busy = true
  local editable = vim.bo[handle.bufnr].modifiable
  vim.bo[handle.bufnr].modifiable = false
  vim.cmd("stopinsert")
  local function current()
    if alive(session, handle) then return true end
    session.popup.repository_busy = nil
    return false
  end
  local function failed(message)
    session.popup.repository_busy = nil
    if alive(session, handle) then vim.bo[handle.bufnr].modifiable = editable end
    report(message)
  end
  local function execute()
    if not current() then return end
    local buffers = checkout and root_buffers(session.git_root) or {}
    local dirty = unsaved(buffers)
    if dirty then failed("Switch cancelled: unsaved buffer " .. vim.fn.strtrans(dirty)); return end
    if require("codediff.ui.conflict.tracking").has_work(session) then
      failed("Finish or discard the current conflict result before switching"); return
    end
    run(session.git_root, args, function(result)
      session.popup.repository_busy = nil
      if checkout then reload_buffers(buffers, "switching branches") end
      if result.code ~= 0 then
        -- A post-checkout hook can fail after Git has already switched HEAD.
        if checkout then refresh(session) end
        failed(error_text(result)); return
      end
      if not current() then return end
      handle.close()
      done()
    end)
  end
  head(session.git_root, function(err, value)
    if not current() then return end
    if err then failed(err); return end
    if not same_head(displayed_head, value) then failed("HEAD changed; cancel and reopen the list before switching"); return end
    if not new_branch then execute(); return end
    run(session.git_root, { "check-ref-format", "--branch", new_branch }, function(result)
      if not current() then return end
      if result.code ~= 0 then failed(error_text(result)); return end
      if vim.trim(result.stdout or "") ~= new_branch then failed("Use a literal new branch name, not a checkout shorthand"); return end
      if destination then
        worktree_destination(session.git_root, destination, function(path_error)
          if not current() then return end
          if path_error then failed(path_error); return end
          execute()
        end)
      else
        execute()
      end
    end)
  end)
end

local function follow_worktree(session, root)
  local refresh_ui = require("codediff.ui.refresh")
  local panel, old_root = session.panel, session.git_root
  local selected = panel.data.current_selection and panel.data.current_selection.path
  local return_win = session.popup.return_win
  refresh_ui.dispose(session.tabpage)
  session.git_root = root
  panel.data.git_root = root
  panel.data.status_result = { unstaged = {}, staged = {}, conflicts = {} }
  require("codediff.ui.refresh.panel").set_selection(panel, nil)
  panel.view.on_data(panel.data, { list = true, selection = true })
  -- Return to a file in the new tree; old buffers retain their names and edits.
  if vim.api.nvim_win_is_valid(return_win) then
    local old_buf = vim.api.nvim_win_get_buf(return_win)
    local old_name = vim.api.nvim_buf_get_name(old_buf)
    local relative = require("codediff.core.path").make_ref(old_name, old_root).relative
    local target = relative ~= "" and root .. "/" .. relative or nil
    local buf = target and vim.fn.filereadable(target) == 1 and vim.fn.bufadd(target) or vim.api.nvim_create_buf(true, false)
    local hidden = vim.bo[old_buf].bufhidden
    vim.bo[old_buf].bufhidden = "hide"
    local ok, err = pcall(vim.api.nvim_win_set_buf, return_win, buf)
    if vim.api.nvim_buf_is_valid(old_buf) then vim.bo[old_buf].bufhidden = hidden end
    if not ok then report("Worktree selected, but return buffer could not change: " .. err) end
    vim.api.nvim_win_call(return_win, function()
      vim.api.nvim_cmd({ cmd = "tcd", args = { root }, magic = { file = false, bar = false } }, {})
      session.popup.return_view = vim.fn.winsaveview()
    end)
  else
    vim.api.nvim_win_call(session.modified_win, function()
      vim.api.nvim_cmd({ cmd = "tcd", args = { root }, magic = { file = false, bar = false } }, {})
    end)
  end
  refresh_ui.select(session.tabpage, nil)
  refresh_ui.request(session.tabpage, { full = true }, function()
    if lifecycle.get_session(session.tabpage) ~= session or session.git_root ~= root then return end
    local first, preferred
    for _, group in ipairs({ "conflicts", "unstaged", "staged" }) do
      for _, file in ipairs(panel.data.status_result[group] or {}) do
        local entry = vim.tbl_extend("force", file, { group = group, git_root = root })
        first = first or entry
        if file.path == selected then preferred = entry end
      end
    end
    refresh_ui.select(session.tabpage, preferred or first, { no_jump = true })
  end)
end

local function create(ctx, session, displayed_head, worktree, destination)
  local entering_destination = worktree and not destination
  local handle = dialog.open(ctx, {
    title = worktree and (entering_destination and "New worktree: destination" or "New worktree: branch name") or "New branch: name",
    lines = { entering_destination and ".worktrees/" or "" },
    editable = true,
    footer = worktree and (entering_destination and "Enter/Ctrl-s next   Ctrl-q cancel" or "Enter/Ctrl-s create + switch   Ctrl-q cancel") or "Ctrl-s create + switch   Ctrl-q cancel",
  })
  if worktree then
    vim.schedule(function()
      if alive(session, handle) then vim.cmd("startinsert!") end
    end)
  end
  local function submit()
    if not alive(session, handle) or session.popup.repository_busy then return end
    local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
    local value = lines[1] or ""
    if #lines > 1 or vim.trim(value) == "" then
      report(entering_destination and "Enter one worktree destination" or "Enter one branch name"); return
    end
    if entering_destination then
      -- Resolve relative input against this review, not a possibly changed editor cwd.
      local path = vim.fs.normalize(require("codediff.core.path").make_ref(value, session.git_root).absolute, { expand_env = false })
      create(ctx, session, displayed_head, true, path)
      return
    end
    local branch = value
    if not worktree then
      mutate(session, handle, displayed_head, { "switch", "-c", branch }, branch, true, function() refresh(session) end)
      return
    end
    mutate(session, handle, displayed_head, { "worktree", "add", "-b", branch, "--", destination }, branch, false, function()
      follow_worktree(session, path_key(destination))
    end, destination)
  end
  local desc = entering_destination and "Enter branch name" or "Create and switch"
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = handle.bufnr, silent = true, desc = desc })
  if worktree then vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = handle.bufnr, silent = true, desc = desc }) end
  return handle
end

local function list(ctx, title, args, render, worktree)
  local session = context(ctx)
  if not session then return end
  local handle = dialog.open(ctx, { title = title, lines = { "Loading..." }, footer = "i/k move   Enter switch   n create   q close" })
  local entries, displayed_head
  head(session.git_root, function(err, value)
    if not alive(session, handle) then return end
    if err then report(err) end
    displayed_head = value
    run(session.git_root, args, function(result)
      if not alive(session, handle) then return end
      local lines
      if result.code == 0 then lines, entries = render(result.stdout or "", session.git_root)
      else lines = vim.split(error_text(result), "\n", { plain = true }) end
      if #lines == 0 then lines = { "No " .. title:lower() .. "." } end
      vim.bo[handle.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, lines)
      vim.bo[handle.bufnr].modifiable = false
      local config = vim.api.nvim_win_get_config(handle.winid)
      config.height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))
      config.row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - config.height - 2) / 2))
      vim.api.nvim_win_set_config(handle.winid, config)
    end)
  end)
  vim.keymap.set("n", "n", function()
    if alive(session, handle) and not session.popup.repository_busy and entries and displayed_head then
      create(ctx, session, displayed_head, worktree)
    end
  end, { buffer = handle.bufnr, silent = true, desc = "Create " .. (worktree and "worktree" or "branch") })
  vim.keymap.set("n", "<CR>", function()
    if not alive(session, handle) or session.popup.repository_busy or not entries or not displayed_head then return end
    local entry = entries[vim.api.nvim_win_get_cursor(handle.winid)[1]]
    if not entry then return end
    if worktree then
      if entry.bare ~= nil or entry.prunable ~= nil then report("Cannot switch to a bare or prunable worktree"); return end
      if path_key(entry.worktree) == path_key(session.git_root) then handle.close(); return end
      -- Validate the directory with Git before moving the review or editor cwd.
      mutate(session, handle, displayed_head, { "-C", entry.worktree, "rev-parse", "--show-toplevel" }, nil, false, function()
        follow_worktree(session, entry.worktree)
      end)
    else
      if entry.current then handle.close(); return end
      mutate(session, handle, displayed_head, { "switch", "--", entry.name }, nil, true, function() refresh(session) end)
    end
  end, { buffer = handle.bufnr, silent = true, desc = "Switch " .. (worktree and "worktree" or "branch") })
  return handle
end

function M.branches(ctx)
  return list(ctx, "Local branches", { "for-each-ref", "--sort=refname", "--format=%(HEAD)%00%(refname:lstrip=2)%00%(objectname:short)%00%(subject)", "refs/heads/" }, function(output)
    local lines, entries = {}, {}
    for _, row in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
      local fields = vim.split(row, "\0", { plain = true })
      entries[#entries + 1] = { name = fields[2], current = fields[1] == "*" }
      lines[#lines + 1] = fields[1] .. " " .. vim.fn.strtrans(fields[2]) .. "  " .. fields[3] .. "  " .. vim.fn.strtrans(fields[4])
    end
    return lines, entries
  end)
end

-- Operation markers belong to this worktree, not necessarily the common .git directory.
function M.operation_state(root, callback)
  run(root, { "rev-parse", "--absolute-git-dir" }, function(result)
    if result.code ~= 0 then callback(error_text(result)); return end
    local git_dir = (result.stdout or ""):gsub("\n$", "")
    local uv = vim.uv or vim.loop
    local function exists(path)
      local stat, err, code = uv.fs_stat(git_dir .. "/" .. path)
      if not stat and code ~= "ENOENT" then error(err) end
      return stat ~= nil
    end
    local function read(path)
      if not exists(path) then return "" end
      return table.concat(vim.fn.readfile(git_dir .. "/" .. path, "b"), "\n")
    end
    local ok, state = pcall(function()
      for _, directory in ipairs({ "rebase-merge", "rebase-apply" }) do
        if exists(directory) then
          local kind = directory == "rebase-apply" and exists(directory .. "/applying") and "am" or "rebase"
          local parts = { kind, directory }
          for _, file in ipairs({ "head-name", "orig-head", "onto", "msgnum", "next", "stopped-sha", "original-commit" }) do
            parts[#parts + 1] = read(directory .. "/" .. file)
          end
          return { kind = kind, token = table.concat(parts, "\0"),
            branch = read(directory .. "/head-name"):gsub("\n$", ""):gsub("^refs/heads/", "") }
        end
      end
      for _, marker in ipairs({ { "MERGE_HEAD", "merge" }, { "CHERRY_PICK_HEAD", "cherry-pick" }, { "REVERT_HEAD", "revert" } }) do
        if exists(marker[1]) then return { kind = marker[2], token = read(marker[1]) } end
      end
      if exists("sequencer") then return { kind = "sequencer", token = read("sequencer/todo") } end
    end)
    if not ok then callback(tostring(state)); return end
    callback(nil, state)
  end)
end

local function operation_result(session, handle, result, operation, success)
  run(session.git_root, { "ls-files", "--unmerged", "-z" }, function(unmerged)
    reload_buffers(root_buffers(session.git_root), operation)
    if alive(session, handle) then handle.close() end
    if lifecycle.get_session(session.tabpage) == session then
      local refresh_ui = require("codediff.ui.refresh")
      refresh_ui.request(session.tabpage, { full = true }, function()
        if lifecycle.get_session(session.tabpage) ~= session then return end
        local panel = session.panel
        local conflict = panel and panel.data.status_result and panel.data.status_result.conflicts[1]
        if conflict then
          refresh_ui.select(session.tabpage, vim.tbl_extend("force", conflict, {
            group = "conflicts", git_root = session.git_root,
          }))
        end
      end)
    end
    session.popup.repository_busy = nil
    -- Selection changes can cancel refresh callbacks; Git's outcome must still be reported.
    if unmerged.code ~= 0 then
      report(error_text(result.code ~= 0 and result or unmerged))
    elseif unmerged.stdout ~= "" then
      vim.notify(operation .. " paused with conflicts: resolve and save Result, stage, then g → c to continue.", vim.log.levels.INFO)
    elseif result.code ~= 0 then
      report(error_text(result))
    else
      vim.notify(vim.fn.strtrans(success), vim.log.levels.INFO)
    end
  end)
end

function M.integrate(ctx, displayed_head, entry, operation)
  local session = context(ctx)
  if not session then return end
  if not displayed_head or not displayed_head.oid or not displayed_head.ref
    or displayed_head.ref:sub(1, 11) ~= "refs/heads/" then
    report("Merge/rebase requires a checked-out, born local branch"); return
  end
  local branch = displayed_head.ref:sub(12)
  local merging = operation == "merge"
  local direction = merging and ("Merge " .. entry.name .. " into checked-out branch " .. branch)
    or ("Rebase checked-out branch " .. branch .. " onto " .. entry.name)
  local handle = dialog.open(ctx, { title = "Confirm " .. operation, lines = {
    vim.fn.strtrans(direction),
    "Selected commit: " .. entry.oid,
    "Checked-out HEAD: " .. vim.fn.strtrans(branch) .. " @ " .. displayed_head.oid,
    "",
    merging and "Success may fast-forward or create a merge commit."
      or "Rebase rewrites this branch's commits; merge commits are not preserved.",
    merging and "This updates the checked-out branch and files."
      or "Other branch refs are not updated. Nothing is pushed.",
  }, footer = "y " .. operation .. "   n/q/Esc/Ctrl-q cancel" })
  vim.keymap.set("n", "n", handle.close, { buffer = handle.bufnr, silent = true, desc = "Cancel " .. operation })
  vim.keymap.set("n", "y", function()
    if not alive(session, handle) or session.popup.repository_busy then return end
    session.popup.repository_busy = true
    local function current()
      if alive(session, handle) then return true end
      session.popup.repository_busy = nil
      return false
    end
    local function failed(message)
      session.popup.repository_busy = nil
      report(message)
    end
    local dirty = unsaved(root_buffers(session.git_root))
    if dirty then failed(operation .. " cancelled: unsaved buffer " .. vim.fn.strtrans(dirty)); return end
    if require("codediff.ui.conflict.tracking").has_work(session) then
      failed("Finish or discard the current conflict result before starting " .. operation); return
    end
    M.operation_state(session.git_root, function(state_error, state)
      if not current() then return end
      if state_error then failed(state_error); return end
      if state then failed("A " .. state.kind .. " is already in progress; use g to continue or abort it"); return end
      run(session.git_root, { "status", "--porcelain=v1", "--untracked-files=no" }, function(status)
        if not current() then return end
        if status.code ~= 0 then failed(error_text(status)); return end
        if status.stdout ~= "" then failed(operation .. " cancelled: tracked worktree or index has changes"); return end
        head(session.git_root, function(err, value)
          if not current() then return end
          if err then failed(err); return end
          if not same_head(displayed_head, value) then
            failed("HEAD changed; cancel and reopen the graph before submitting"); return
          end
          dirty = unsaved(root_buffers(session.git_root))
          if dirty then failed(operation .. " cancelled: unsaved buffer " .. vim.fn.strtrans(dirty)); return end
          -- Execute the confirmed object, not a branch name that can move after selection.
          local args = merging
            and { "merge", "--no-edit", "--no-autostash", "-m", "Merge " .. entry.name, "--", entry.oid }
            or { "rebase", "--no-autostash", "--no-update-refs", "--no-fork-point", "--no-rebase-merges", "--", entry.oid }
          run(session.git_root, args, function(result)
            operation_result(session, handle, result, operation,
              merging and ("Merged " .. entry.name .. " into " .. branch) or ("Rebased " .. branch .. " onto " .. entry.name))
          end)
        end)
      end)
    end)
  end, { buffer = handle.bufnr, silent = true, desc = "Confirm " .. operation })
  return handle
end

function M.resume(ctx, displayed_head, state, action)
  local session = context(ctx)
  if not session or not state then return end
  if state.kind ~= "merge" and state.kind ~= "rebase" then
    report("Continue or abort this " .. state.kind .. " using Git"); return
  end
  local aborting = action == "abort"
  local handle = dialog.open(ctx, { title = "Confirm " .. state.kind .. " " .. action, lines = {
    (aborting and "Abort" or "Continue") .. " the paused " .. state.kind
      .. (state.branch and state.branch ~= "" and (" on " .. vim.fn.strtrans(state.branch)) or "") .. "?",
    aborting and "Git restores the branch and tracked files to their pre-operation state."
      or "Git uses your staged resolutions and the existing commit message.",
    aborting and "Saved tracked edits, including conflict resolutions, will be discarded."
      or "A rebase may pause again at another conflicting commit.",
    "Unsaved repository buffers must be saved or discarded first.",
  }, footer = "y " .. action .. "   n/q/Esc/Ctrl-q cancel" })
  vim.keymap.set("n", "n", handle.close, { buffer = handle.bufnr, silent = true, desc = "Cancel " .. action })
  vim.keymap.set("n", "y", function()
    if not alive(session, handle) or session.popup.repository_busy then return end
    session.popup.repository_busy = true
    local function current()
      if alive(session, handle) then return true end
      session.popup.repository_busy = nil
      return false
    end
    local function failed(message)
      session.popup.repository_busy = nil
      report(message)
    end
    local dirty = unsaved(root_buffers(session.git_root))
    if dirty then failed(action .. " cancelled: unsaved buffer " .. vim.fn.strtrans(dirty)); return end
    head(session.git_root, function(err, value)
      if not current() then return end
      if err then failed(err); return end
      if not same_head(displayed_head, value) then failed("HEAD changed; reopen the graph before " .. action); return end
      M.operation_state(session.git_root, function(state_error, pending)
        if not current() then return end
        if state_error then failed(state_error); return end
        if not pending or pending.kind ~= state.kind or pending.token ~= state.token then
          failed("The Git operation changed; reopen the graph before " .. action); return
        end
        dirty = unsaved(root_buffers(session.git_root))
        if dirty then failed(action .. " cancelled: unsaved buffer " .. vim.fn.strtrans(dirty)); return end
        run(session.git_root, { state.kind, "--" .. action }, function(result)
          operation_result(session, handle, result, state.kind .. " " .. action,
            state.kind .. (aborting and " aborted" or " continued"))
        end, nil, { GIT_EDITOR = "true", GIT_SEQUENCE_EDITOR = "true" })
      end)
    end)
  end, { buffer = handle.bufnr, silent = true, desc = "Confirm " .. action })
  return handle
end

function M.worktrees(ctx)
  return list(ctx, "Worktrees", { "worktree", "list", "--porcelain", "-z" }, function(output, root)
    local lines, entries, entry = {}, {}, {}
    local function append()
      if not entry.worktree then return end
      local marker = path_key(entry.worktree) == path_key(root) and "* " or "  "
      local details = { marker .. vim.fn.strtrans(entry.worktree) }
      if entry.branch then details[#details + 1] = vim.fn.strtrans((entry.branch:gsub("^refs/heads/", ""))) end
      if entry.HEAD then details[#details + 1] = entry.HEAD:sub(1, 8) end
      for _, flag in ipairs({ "detached", "bare", "locked", "prunable" }) do
        if entry[flag] then details[#details + 1] = flag .. (entry[flag] ~= "" and (": " .. vim.fn.strtrans(entry[flag])) or "") end
      end
      lines[#lines + 1] = table.concat(details, "  |  ")
      entries[#entries + 1] = entry
      entry = {}
    end
    for _, field in ipairs(vim.split(output, "\0", { plain = true })) do
      if field == "" then append()
      else
        local key, value = field:match("^(%S+) (.*)$")
        entry[key or field] = value or ""
      end
    end
    append()
    return lines, entries
  end, true)
end

return M
