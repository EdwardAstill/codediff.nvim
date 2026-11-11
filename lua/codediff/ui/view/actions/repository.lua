local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local dialog = require("codediff.ui.dialog")

local function run(root, args, callback, stdin)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  vim.system(argv, { stdin = stdin }, vim.schedule_wrap(callback))
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

local function head(root, callback)
  run(root, { "symbolic-ref", "--quiet", "HEAD" }, function(symbolic)
    if symbolic.code ~= 0 and symbolic.code ~= 1 then callback(error_text(symbolic)); return end
    local ref = symbolic.code == 0 and vim.trim(symbolic.stdout) or nil
    run(root, { "rev-parse", "--verify", "--quiet", "HEAD" }, function(revision)
      if revision.code ~= 0 and not (revision.code == 1 and ref) then callback(error_text(revision)); return end
      local oid = revision.code == 0 and vim.trim(revision.stdout) or nil
      callback(nil, {
        ref = ref, oid = oid,
        label = (ref and ref:gsub("^refs/heads/", "") or "detached HEAD") .. " @ " .. (oid and oid:sub(1, 8) or "unborn"),
      })
    end)
  end)
end

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
        if staged.code == 0 then failed("No staged changes; nothing committed"); return end
        if staged.code ~= 1 then failed(error_text(staged)); return end
        if not alive(session, handle) then session.popup.repository_busy = nil; return end
        -- Feed only the draft to Git; HEAD and help are window chrome, never message text.
        run(session.git_root, { "commit", "--cleanup=verbatim", "--file=-" }, function(result)
          if result.code ~= 0 then failed(error_text(result)); return end
          session.popup.repository_busy = nil
          if alive(session, handle) then handle.close() end
          refresh(session)
          vim.notify("Committed staged changes on " .. displayed_head.label, vim.log.levels.INFO)
        end, message .. "\n")
      end)
    end)
  end
  vim.keymap.set("n", "s", submit, { buffer = handle.bufnr, silent = true, desc = "Commit staged changes" })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = handle.bufnr, silent = true, desc = "Commit staged changes" })
  return handle
end

local function path_key(path)
  return (vim.uv or vim.loop).fs_realpath(path) or vim.fs.normalize(path)
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
              for _, buf in ipairs(buffers) do
                if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
                  if vim.bo[buf].modified then
                    vim.notify("Buffer changed while stashing; kept unsaved edits: " .. vim.fn.strtrans(vim.api.nvim_buf_get_name(buf)), vim.log.levels.WARN)
                  else
                    local autoread = vim.bo[buf].autoread
                    vim.bo[buf].autoread = true
                    local ok, reload_error = pcall(vim.api.nvim_buf_call, buf, function()
                      local _, _, code = (vim.uv or vim.loop).fs_stat(vim.api.nvim_buf_get_name(buf))
                      if code == "ENOENT" then
                        -- Stashed additions disappear from disk; do not leave their old text ready to resurrect.
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
                    if not ok then report("Stashed, but could not reload buffer: " .. reload_error) end
                  end
                end
              end
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

local function list(ctx, title, args, render)
  local session = context(ctx)
  if not session then return end
  local handle = dialog.open(ctx, { title = title, lines = { "Loading..." }, footer = "i/k move   q close" })
  run(session.git_root, args, function(result)
    if not alive(session, handle) then return end
    local lines = result.code == 0 and render(result.stdout or "") or vim.split(error_text(result), "\n", { plain = true })
    if #lines == 0 then lines = { "No " .. title:lower() .. "." } end
    vim.bo[handle.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, lines)
    vim.bo[handle.bufnr].modifiable = false
    local config = vim.api.nvim_win_get_config(handle.winid)
    config.height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))
    config.row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - config.height - 2) / 2))
    vim.api.nvim_win_set_config(handle.winid, config)
  end)
  return handle
end

function M.branches(ctx)
  return list(ctx, "Local branches", { "for-each-ref", "--sort=refname", "--format=%(HEAD)%00%(refname:short)%00%(objectname:short)%00%(subject)", "refs/heads/" }, function(output)
    local lines = {}
    for _, row in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
      local fields = vim.split(row, "\0", { plain = true })
      lines[#lines + 1] = fields[1] .. " " .. fields[2] .. "  " .. fields[3] .. "  " .. vim.fn.strtrans(fields[4])
    end
    return lines
  end)
end

function M.worktrees(ctx)
  return list(ctx, "Worktrees", { "worktree", "list", "--porcelain", "-z" }, function(output)
    local lines, entry = {}, {}
    local function append()
      if not entry.worktree then return end
      local details = { vim.fn.strtrans(entry.worktree) }
      if entry.branch then details[#details + 1] = entry.branch:gsub("^refs/heads/", "") end
      if entry.HEAD then details[#details + 1] = entry.HEAD:sub(1, 8) end
      for _, flag in ipairs({ "detached", "bare", "locked", "prunable" }) do
        if entry[flag] then details[#details + 1] = flag .. (entry[flag] ~= "" and (": " .. vim.fn.strtrans(entry[flag])) or "") end
      end
      lines[#lines + 1] = table.concat(details, "  |  ")
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
    return lines
  end)
end

return M
