local h = require("tests.support")
local repositories = require("tests.support.repository")
local lifecycle = require("codediff.ui.lifecycle")
local actions = require("codediff.ui.view.actions.repository")
local dialog = require("codediff.ui.dialog")
h.ensure_plugin_loaded()

describe("Review repository dialogs", function()
  local repo, session, notifications, notify

  local function eventually(predicate)
    assert.is_true(vim.wait(10000, predicate, 20), "repository action should settle")
  end

  local function text(handle)
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
  end

  local function invoke(handle, key)
    vim.api.nvim_set_current_win(handle.winid)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, "n")) do
      if mapping.lhs == key then
        assert.is_function(mapping.callback)
        mapping.callback()
        return
      end
    end
    error("Missing dialog mapping: " .. key)
  end

  local function open()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("tracked.txt")))
    require("codediff.commands").vscode_diff({ fargs = {} })
    eventually(function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.popup and session.panel and session.panel.view
    end)
    return { tabpage = session.tabpage }
  end

  local function commit_dialog(ctx, message)
    local handle = actions.commit(ctx)
    eventually(function()
      return not vim.inspect(vim.api.nvim_win_get_config(handle.winid).title):find("reading HEAD", 1, true)
    end)
    if message then vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, message) end
    return handle
  end

  local function stash_dialog(ctx)
    actions.stash(ctx)
    eventually(function()
      return session.popup.dialog and text(session.popup.dialog):find("Untracked files stay", 1, true) ~= nil
    end)
    return session.popup.dialog
  end

  local function notified(fragment)
    for _, message in ipairs(notifications) do
      if message:find(fragment, 1, true) then return true end
    end
    return false
  end

  before_each(function()
    require("codediff").setup({ explorer = { auto_open_on_cursor = false } })
    lifecycle.cleanup_all()
    notifications = {}
    notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    repo = repositories.new({ key = "repository-actions", build = function(seed)
      seed.write_file("tracked.txt", { "base" })
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

  it("commits only the index with a multiline draft, not HEAD/help text, and prevents duplicate submission", function()
    repo.write_file("tracked.txt", { "staged" })
    repo.command({ "add", "tracked.txt" })
    repo.write_file("tracked.txt", { "unstaged" })
    local ctx = open()
    local handle = commit_dialog(ctx, { "reviewed change", "", "longer message" })
    local title = vim.inspect(vim.api.nvim_win_get_config(handle.winid).title)
    h.assert_contains(title, "main @ " .. repo.seed.base:sub(1, 8))
    invoke(handle, "s")
    invoke(handle, "s")
    eventually(function() return not session.popup.repository_busy and not session.popup.dialog end)
    assert.equals("staged\n", repo.blob("HEAD", "tracked.txt"))
    assert.same({ "unstaged" }, repo.read_file("tracked.txt"))
    assert.equals("reviewed change\n\nlonger message\n\n", repo.command({ "log", "-1", "--format=%B" }))
    assert.equals("2", vim.trim(repo.command({ "rev-list", "--count", "HEAD" })))
  end)

  it("preserves drafts for empty messages, empty index and real hook failures", function()
    local ctx = open()
    local handle = commit_dialog(ctx)
    invoke(handle, "s")
    assert.is_true(notified("message is empty"))
    vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, { "keep this draft" })
    invoke(handle, "s")
    eventually(function() return notified("No staged changes") end)
    assert.equals("keep this draft", text(handle))
    repo.write_file("tracked.txt", { "staged" })
    repo.command({ "add", "tracked.txt" })
    local hook = repo.git_path("hooks/pre-commit")
    vim.fn.mkdir(vim.fn.fnamemodify(hook, ":h"), "p")
    vim.fn.writefile({ "#!/bin/sh", "echo deliberate-hook-failure >&2", "exit 1" }, hook)
    assert((vim.uv or vim.loop).fs_chmod(hook, 493))
    invoke(handle, "s")
    eventually(function() return notified("deliberate-hook-failure") end)
    assert.equals("keep this draft", text(handle))
    assert.equals(repo.seed.base, vim.trim(repo.command({ "rev-parse", "HEAD" })))
  end)

  it("refuses a switched HEAD even when the new branch points to the same commit", function()
    repo.write_file("tracked.txt", { "staged" })
    repo.command({ "add", "tracked.txt" })
    local handle = commit_dialog(open(), { "do not commit on another branch" })
    repo.command({ "checkout", "-b", "other" })
    invoke(handle, "s")
    eventually(function() return notified("HEAD changed") end)
    assert.equals("do not commit on another branch", text(handle))
    assert.equals(repo.seed.base, vim.trim(repo.command({ "rev-parse", "HEAD" })))
  end)

  it("labels detached HEAD without listing branches in the commit message", function()
    repo.command({ "checkout", "--detach" })
    local handle = commit_dialog(open(), { "detached draft" })
    h.assert_contains(vim.inspect(vim.api.nvim_win_get_config(handle.winid).title), "detached HEAD @")
    assert.equals("detached draft", text(handle))
  end)

  it("commits the first staged file on an unborn branch", function()
    repo.command({ "checkout", "--orphan", "new-history" })
    repo.command({ "rm", "-rf", "." })
    repo.write_file("tracked.txt", { "first" })
    repo.command({ "add", "tracked.txt" })
    local handle = commit_dialog(open(), { "first commit" })
    h.assert_contains(vim.inspect(vim.api.nvim_win_get_config(handle.winid).title), "new-history @ unborn")
    invoke(handle, "s")
    eventually(function() return not session.popup.repository_busy and not session.popup.dialog end)
    assert.equals("first\n", repo.blob("HEAD", "tracked.txt"))
    assert.equals("1", vim.trim(repo.command({ "rev-list", "--count", "HEAD" })))
  end)

  it("stashes staged and unstaged tracked changes, reloads clean buffers and leaves untracked files", function()
    repo.write_file("tracked.txt", { "indexed" })
    repo.command({ "add", "tracked.txt" })
    repo.write_file("tracked.txt", { "working" })
    repo.write_file("untracked.txt", { "leave me" })
    repo.write_file("added.txt", { "new tracked file" })
    repo.command({ "add", "added.txt" })
    local added_buf = vim.fn.bufadd(repo.path("added.txt"))
    vim.fn.bufload(added_buf)
    local ctx = open()
    local work_buf = vim.fn.bufnr(repo.path("tracked.txt"))
    local confirmation = stash_dialog(ctx)
    h.assert_contains(text(confirmation), "main @ " .. repo.seed.base:sub(1, 8))
    invoke(confirmation, "y")
    eventually(function() return not session.popup.repository_busy end)
    assert.equals("indexed\n", repo.blob("stash@{0}^2", "tracked.txt"))
    assert.equals("working\n", repo.blob("stash@{0}", "tracked.txt"))
    assert.equals("base\n", repo.blob(":0", "tracked.txt"))
    assert.same({ "base" }, repo.read_file("tracked.txt"))
    assert.same({ "leave me" }, repo.read_file("untracked.txt"))
    assert.same({ "base" }, vim.api.nvim_buf_get_lines(work_buf, 0, -1, false))
    assert.is_false(vim.bo[work_buf].modified)
    assert.equals("new tracked file\n", repo.blob("stash@{0}^2", "added.txt"))
    assert.equals(0, vim.fn.filereadable(repo.path("added.txt")))
    assert.same({ "" }, vim.api.nvim_buf_get_lines(added_buf, 0, -1, false))
    assert.is_false(vim.bo[added_buf].modified)
  end)

  it("cancels stash when a tracked buffer has unsaved edits, including staged deletions", function()
    repo.write_file("tracked.txt", { "disk changes" })
    local ctx = open()
    local buf = vim.fn.bufnr(repo.path("tracked.txt"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    repo.command({ "rm", "--cached", "tracked.txt" })
    invoke(stash_dialog(ctx), "y")
    eventually(function() return notified("unsaved tracked buffer") end)
    assert.equals("", repo.command({ "stash", "list" }))
    assert.same({ "disk changes" }, repo.read_file("tracked.txt"))
    assert.same({ "unsaved" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("never stashes on cancel and does not overwrite an unsaved untracked buffer", function()
    repo.write_file("tracked.txt", { "changes" })
    repo.write_file("untracked.txt", { "disk" })
    local buf = vim.fn.bufadd(repo.path("untracked.txt"))
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved untracked" })
    local ctx = open()
    invoke(stash_dialog(ctx), "n")
    assert.equals("", repo.command({ "stash", "list" }))
    assert.same({ "changes" }, repo.read_file("tracked.txt"))
    invoke(stash_dialog(ctx), "y")
    eventually(function() return not session.popup.repository_busy end)
    assert.same({ "unsaved untracked" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same({ "disk" }, repo.read_file("untracked.txt"))
  end)

  it("lists local branches and worktrees separately without mutating refs or unusual paths", function()
    repo.command({ "branch", "topic/review" })
    local unusual = repo.root .. "/linked\nworktree"
    repo.command({ "worktree", "add", "--detach", unusual, "HEAD" })
    repo.command({ "worktree", "lock", "--reason", "review\nlock", unusual })
    local ctx = open()
    local before = repo.command({ "show-ref" })
    local branches = actions.branches(ctx)
    eventually(function() return text(branches) ~= "Loading..." end)
    h.assert_contains(text(branches), "* main")
    h.assert_contains(text(branches), "topic/review")
    h.assert_contains(text(branches), "base")
    assert.is_nil(text(branches):find(repo.root, 1, true))
    local worktrees = actions.worktrees(ctx)
    eventually(function() return text(worktrees) ~= "Loading..." end)
    h.assert_contains(text(worktrees), vim.fn.strtrans(unusual))
    h.assert_contains(text(worktrees), "detached")
    h.assert_contains(text(worktrees), "locked: " .. vim.fn.strtrans("review\nlock"))
    h.assert_contains(text(worktrees), "bare")
    assert.equals(before, repo.command({ "show-ref" }))
    assert.equals("", repo.command({ "status", "--porcelain" }))
  end)

  it("shows an empty branch list for an unborn repository and real Git errors in the list", function()
    repo.cleanup()
    repo = repositories.new({ unborn = true })
    repo.write_file("tracked.txt", { "untracked first file" })
    local ctx = open()
    local handle = actions.branches(ctx)
    eventually(function() return text(handle) ~= "Loading..." end)
    assert.equals("No local branches.", text(handle))
    session.git_root = repo.root .. "/missing-repository"
    local errors = actions.worktrees(ctx)
    eventually(function() return text(errors) ~= "Loading..." end)
    h.assert_contains(text(errors), "missing-repository")
    session.git_root = repo.dir
  end)

  it("replaces and cleans child dialogs and restores focus", function()
    local ctx = open()
    local parent = vim.api.nvim_get_current_win()
    local first = dialog.open(ctx, { title = "First", lines = { "info" } })
    local second = dialog.confirm(ctx, "Confirm", { "No default acceptance" }, function() error("must not confirm") end)
    assert.is_false(vim.api.nvim_buf_is_valid(first.bufnr))
    invoke(second, "n")
    assert.equals(parent, vim.api.nvim_get_current_win())
    assert.is_nil(session.popup.dialog)
    local child = dialog.open(ctx, { title = "Owned", lines = { "cleanup" } })
    lifecycle.close(ctx.tabpage)
    assert.is_false(vim.api.nvim_win_is_valid(child.winid))
    assert.is_false(vim.api.nvim_buf_is_valid(child.bufnr))
  end)
end)
