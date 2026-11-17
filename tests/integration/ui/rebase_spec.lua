local h = require("tests.support")
local repositories = require("tests.support.repository")
local lifecycle = require("codediff.ui.lifecycle")
local actions = require("codediff.ui.view.actions.repository")
local revision = require("codediff.core.git.revision")
local refresh = require("codediff.ui.refresh")
h.ensure_plugin_loaded()

describe("Review branch rebase", function()
  local repo, session, notify, notifications, errors

  local function eventually(predicate)
    assert.is_true(vim.wait(10000, predicate, 20), "rebase review should settle")
  end

  local function await(start)
    local done, err, value
    start(function(failure, result) err, value, done = failure, result, true end)
    eventually(function() return done end)
    assert.is_nil(err)
    return value
  end

  local function oid(ref)
    return vim.trim(repo.command({ "rev-parse", ref or "HEAD" }))
  end

  local function state()
    return await(function(callback) actions.operation_state(repo.dir, callback) end)
  end

  local function text(handle)
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
  end

  local function mapping(handle, key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, "n")) do
      if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == vim.api.nvim_replace_termcodes(key, true, true, true) then
        assert.is_function(map.callback)
        return map.callback
      end
    end
    error("Missing dialog mapping: " .. key)
  end

  local function invoke(handle, key)
    vim.api.nvim_set_current_win(handle.winid)
    mapping(handle, key)()
  end

  local function notified(fragment)
    for _, message in ipairs(notifications) do
      if message:find(fragment, 1, true) then return true end
    end
    return false
  end

  local function settled()
    local controller = session.refresh
    return not session.popup.repository_busy and controller and not controller.loading and not controller.running
      and not next(controller.pending) and #controller.callbacks == 0
  end

  local function settle()
    eventually(function() return not session.popup.repository_busy end)
    refresh.request(session.tabpage, { full = true })
    eventually(settled)
  end

  local function open()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("tracked.txt")))
    require("codediff.commands").vscode_diff({ fargs = {} })
    eventually(function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.popup and session.panel and session.panel.view and session.refresh and not session.refresh.loading
    end)
    settle()
    return { tabpage = session.tabpage }
  end

  local function confirm(ctx, target)
    local head = await(function(callback) revision.get_head(repo.dir, callback) end)
    local handle = actions.integrate(ctx, head, { oid = target, name = "topic" }, "rebase")
    assert.is_table(handle)
    assert.equals(handle, session.popup.dialog)
    return handle
  end

  local function resume(ctx, action)
    local pending = state()
    assert.equals("rebase", pending and pending.kind)
    assert.equals("main", pending.branch)
    assert.is_string(pending.token)
    local head = await(function(callback) revision.get_head(repo.dir, callback) end)
    local handle = actions.resume(ctx, head, pending, action)
    assert.is_table(handle)
    h.assert_contains(text(handle), (action == "abort" and "Abort" or "Continue") .. " the paused rebase on main?")
    return handle
  end

  local function submit(handle)
    invoke(handle, "y")
    settle()
  end

  local function diverge(conflict)
    repo.command({ "checkout", "-b", "topic" })
    repo.write_file("tracked.txt", { "incoming" })
    local target = repo.commit("topic change")
    repo.command({ "checkout", "main" })
    repo.write_file(conflict and "tracked.txt" or "other.txt", { "current" })
    return target, repo.commit("main change")
  end

  local function conflicted()
    local target, current = diverge(true)
    local ctx = open()
    submit(confirm(ctx, target))
    eventually(function()
      if not session.merge or not settled() then return false end
      for _, side in ipairs({ "original", "modified", "base", "result" }) do
        local buf, win = session[side .. "_bufnr"], session[side .. "_win"]
        if not buf or not vim.api.nvim_buf_is_loaded(buf) or not win or not vim.api.nvim_win_is_valid(win) then return false end
      end
      return session.source_revisions and session.source_revisions.original == ":3" and session.source_revisions.modified == ":2"
    end)
    return ctx, target, current
  end

  local function save_resolution(stage)
    vim.api.nvim_buf_set_lines(session.result_bufnr, 0, -1, false, { "resolved together" })
    vim.api.nvim_buf_call(session.result_bufnr, function() vim.cmd("silent write") end)
    assert.is_false(vim.bo[session.result_bufnr].modified)
    assert.same({ "resolved together" }, repo.read_file("tracked.txt"))
    if stage then repo.command({ "add", "--", "tracked.txt" }) end
  end

  before_each(function()
    require("codediff").setup({ explorer = { auto_open_on_cursor = false } })
    lifecycle.cleanup_all()
    notifications, errors, notify = {}, {}, vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = message
      if level == vim.log.levels.ERROR then errors[#errors + 1] = message end
    end
    repo = repositories.new({ key = "branch-rebase", build = function(seed)
      seed.write_file("tracked.txt", { "base" })
      seed.write_file("other.txt", { "other base" })
      return { base = seed.commit("base") }
    end })
  end)

  after_each(function()
    lifecycle.cleanup_all()
    vim.notify = notify
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #repo.root) == repo.root then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    h.close_extra_tabs()
    repo.cleanup()
  end)

  it("replays only the current branch onto the frozen target despite moved refs and updateRefs config", function()
    local target, current = diverge()
    repo.command({ "branch", "keep-current" })
    repo.command({ "config", "rebase.updateRefs", "true" })
    local handle = confirm(open(), target)
    local body = text(handle)
    h.assert_contains(body, "Rebase checked-out branch main onto topic")
    h.assert_contains(body, "Selected commit: " .. target)
    h.assert_contains(body, "Checked-out HEAD: main @ " .. current)
    h.assert_contains(body, "Rebase rewrites this branch's commits")
    local buf = vim.fn.bufnr(repo.path("tracked.txt"))
    repo.command({ "update-ref", "refs/heads/topic", repo.seed.base })
    submit(handle)
    assert.equals("main", vim.trim(repo.command({ "branch", "--show-current" })))
    assert.is_not.equal(current, oid())
    assert.equals(target, oid("HEAD^"))
    assert.equals(repo.seed.base, oid("topic"))
    assert.equals(current, oid("keep-current"))
    assert.equals("main change", vim.trim(repo.command({ "log", "-1", "--format=%s" })))
    assert.same({ "incoming" }, repo.read_file("tracked.txt"))
    assert.same({ "current" }, repo.read_file("other.txt"))
    assert.same({ "incoming" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_nil(state())
    assert.equals("", repo.command({ "status", "--porcelain" }))
    assert.same({}, errors)
  end)

  for _, key in ipairs({ "n", "q" }) do
    it("cancels rebase with " .. key .. " without changing refs, index or files", function()
      local target, current = diverge()
      local handle = confirm(open(), target)
      local refs, index = repo.command({ "show-ref" }), repo.command({ "write-tree" })
      invoke(handle, key)
      settle()
      assert.equals(current, oid())
      assert.equals(refs, repo.command({ "show-ref" }))
      assert.equals(index, repo.command({ "write-tree" }))
      assert.same({ "base" }, repo.read_file("tracked.txt"))
      assert.same({ "current" }, repo.read_file("other.txt"))
      assert.is_nil(state())
      assert.is_nil(session.popup.dialog)
    end)
  end

  for _, staged in ipairs({ false, true }) do
    it("preserves a dirty tracked " .. (staged and "index" or "worktree") .. " even with autostash configured", function()
      local target, current = diverge()
      repo.command({ "config", "rebase.autoStash", "true" })
      local handle = confirm(open(), target)
      repo.write_file("other.txt", { "keep dirty" })
      if staged then repo.command({ "add", "--", "other.txt" }) end
      local index, status = repo.command({ "write-tree" }), repo.command({ "status", "--porcelain" })
      submit(handle)
      assert.is_true(notified("tracked worktree or index has changes"))
      assert.equals(current, oid())
      assert.equals(index, repo.command({ "write-tree" }))
      assert.equals(status, repo.command({ "status", "--porcelain" }))
      assert.same({ "keep dirty" }, repo.read_file("other.txt"))
      assert.equals("", repo.command({ "stash", "list" }))
      assert.is_nil(state())
    end)
  end

  it("preserves unsaved ordinary buffers even when their paths are untracked", function()
    local target, current = diverge()
    local handle = confirm(open(), target)
    local buf = vim.fn.bufadd(repo.path("unsaved.txt"))
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep unsaved" })
    submit(handle)
    assert.is_true(notified("unsaved buffer"))
    assert.equals(current, oid())
    assert.same({ "keep unsaved" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
    assert.equals(0, vim.fn.filereadable(repo.path("unsaved.txt")))
    assert.equals("", repo.command({ "status", "--porcelain" }))
    assert.is_nil(state())
  end)

  for _, change in ipairs({ "ref", "commit" }) do
    it("refuses a changed HEAD " .. change .. " after confirmation opens", function()
      local target = diverge()
      local handle = confirm(open(), target)
      if change == "ref" then repo.command({ "checkout", "-b", "other" })
      else repo.commit("external commit") end
      local current, refs = oid(), repo.command({ "show-ref" })
      submit(handle)
      assert.is_true(notified("HEAD changed"))
      assert.equals(current, oid())
      assert.equals(refs, repo.command({ "show-ref" }))
      assert.equals(change == "ref" and "other" or "main", vim.trim(repo.command({ "branch", "--show-current" })))
      assert.is_nil(state())
    end)
  end

  it("ignores stale abort confirmation callbacks after another dialog replaces them", function()
    local ctx, target, current = conflicted()
    save_resolution(false)
    local pending = state()
    local handle = resume(ctx, "abort")
    local callback = mapping(handle, "y")
    local replacement = actions.branches(ctx)
    callback()
    settle()
    assert.equals(target, oid())
    assert.equals(current, oid("main"))
    assert.equals(pending.token, state().token)
    assert.equals(replacement, session.popup.dialog)
    assert.same({ "resolved together" }, repo.read_file("tracked.txt"))
  end)

  it("opens the actual four-pane conflict resolver and continues a saved staged resolution", function()
    local ctx, target, current = conflicted()
    assert.same({ "current" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))
    assert.same({ "incoming" }, vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false))
    assert.same({ "base" }, vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false))
    assert.equals(target, oid())
    assert.equals(current, oid("main"))
    h.assert_contains(repo.command({ "ls-files", "--unmerged" }), "tracked.txt")
    assert.same({}, errors, "Expected conflicts must not open an error pager")
    save_resolution(true)
    submit(resume(ctx, "continue"))
    assert.equals("main", vim.trim(repo.command({ "branch", "--show-current" })))
    assert.equals(target, oid("HEAD^"))
    assert.same({ "resolved together" }, repo.read_file("tracked.txt"))
    assert.equals("main change", vim.trim(repo.command({ "log", "-1", "--format=%s" })))
    assert.equals("", repo.command({ "status", "--porcelain" }))
    assert.is_nil(state())
    assert.is_false(session.merge == true)
    assert.same({}, errors)
  end)

  it("warns before abort discards saved resolutions and restores the original branch and HEAD", function()
    local ctx, target, current = conflicted()
    save_resolution(false)
    local handle = resume(ctx, "abort")
    h.assert_contains(text(handle), "Saved tracked edits, including conflict resolutions, will be discarded.")
    vim.api.nvim_buf_set_lines(session.result_bufnr, 0, -1, false, { "keep unsaved resolution" })
    submit(handle)
    assert.is_true(notified("unsaved buffer"))
    assert.same({ "keep unsaved resolution" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
    assert.is_true(vim.bo[session.result_bufnr].modified)
    assert.equals(target, oid())
    save_resolution(false)
    invoke(handle, "n")
    settle()
    assert.equals("rebase", state().kind)
    assert.equals(target, oid())
    assert.same({ "resolved together" }, repo.read_file("tracked.txt"))
    submit(resume(ctx, "abort"))
    assert.equals("main", vim.trim(repo.command({ "branch", "--show-current" })))
    assert.equals(current, oid())
    assert.same({ "current" }, repo.read_file("tracked.txt"))
    assert.equals("", repo.command({ "status", "--porcelain" }))
    assert.is_nil(state())
    assert.is_false(session.merge == true)
  end)

  it("refuses a second start while a worktree-local merge is pending", function()
    local target, current = diverge()
    repo.command({ "merge", "--no-ff", "--no-commit", "topic" })
    local pending = state()
    assert.equals("merge", pending and pending.kind)
    local handle = confirm(open(), target)
    local index, status = repo.command({ "write-tree" }), repo.command({ "status", "--porcelain" })
    submit(handle)
    assert.equals(current, oid())
    assert.equals(pending.token, state().token)
    assert.equals(index, repo.command({ "write-tree" }))
    assert.equals(status, repo.command({ "status", "--porcelain" }))
    assert.is_true(notified("already in progress"), "Pending operations must explain why a new rebase cannot start")
  end)

  it("leaves the real pending rebase and staged resolution visible after Git continue fails", function()
    local ctx, target, current = conflicted()
    save_resolution(true)
    local before = state()
    local hook = repo.git_path("hooks/prepare-commit-msg")
    vim.fn.mkdir(vim.fn.fnamemodify(hook, ":h"), "p")
    assert.equals(0, vim.fn.writefile({ "#!/bin/sh", "echo deliberate-rebase-failure >&2", "exit 1" }, hook))
    assert((vim.uv or vim.loop).fs_chmod(hook, 493))
    submit(resume(ctx, "continue"))
    assert.is_true(notified("deliberate-rebase-failure"))
    assert.equals("rebase", state().kind)
    assert.equals(before.token, state().token)
    assert.equals(target, oid())
    assert.equals(current, oid("main"))
    assert.same({ "resolved together" }, repo.read_file("tracked.txt"))
    assert.equals("resolved together\n", repo.blob(":0", "tracked.txt"))
    assert.equals("", repo.command({ "ls-files", "--unmerged" }))
    h.assert_contains(repo.command({ "diff", "--cached" }), "resolved together")
    assert.is_true(#session.panel.data.status_result.staged > 0, "Review must show Git's surviving staged resolution")
  end)
end)
