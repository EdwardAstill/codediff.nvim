local h = require("tests.support")
local repositories = require("tests.support.repository")
local lifecycle = require("codediff.ui.lifecycle")
local actions = require("codediff.ui.view.actions.repository")
h.ensure_plugin_loaded()

describe("Review branch merge", function()
  local repo, session, notify, notifications, errors
  local function eventually(predicate)
    assert.is_true(vim.wait(10000, predicate, 20), "merge review should settle")
  end
  local function invoke(handle, key)
    vim.api.nvim_set_current_win(handle.winid)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, "n")) do
      if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == vim.api.nvim_replace_termcodes(key, true, true, true) then
        map.callback()
        return
      end
    end
    error("Missing mapping: " .. key)
  end
  local function notified(fragment)
    for _, message in ipairs(notifications) do
      if message:find(fragment, 1, true) then return true end
    end
    return false
  end
  local function oid(ref)
    return vim.trim(repo.command({ "rev-parse", ref or "HEAD" }))
  end
  local function open()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("tracked.txt")))
    require("codediff.commands").vscode_diff({ fargs = {} })
    eventually(function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.popup and session.panel and session.panel.view and session.refresh and not session.refresh.loading
    end)
    return { tabpage = session.tabpage }
  end
  local function choose(ctx)
    local picker = require("codediff.ui.graph").open(ctx)
    local target = vim.trim(repo.command({ "rev-parse", "--short", "topic" }))
    local selected
    eventually(function()
      for row, line in ipairs(vim.api.nvim_buf_get_lines(picker.bufnr, 0, -1, false)) do
        if line:find(target, 1, true) then selected = row; return true end
      end
      return false
    end)
    vim.api.nvim_win_set_cursor(picker.winid, { selected, 0 })
    invoke(picker, "m")
    local confirmation = session.popup.dialog
    assert.is_not.equal(picker, confirmation)
    local text = table.concat(vim.api.nvim_buf_get_lines(confirmation.bufnr, 0, -1, false), "\n")
    h.assert_contains(text, "into checked-out branch main")
    h.assert_contains(text, "Selected commit: " .. oid("topic"))
    h.assert_contains(text, "Checked-out HEAD: main @ " .. oid())
    h.assert_contains(text, "fast-forward or create a merge commit")
    return confirmation
  end
  local function topic(content)
    repo.command({ "checkout", "-b", "topic" })
    repo.write_file("tracked.txt", { content or "incoming" })
    local target = repo.commit("topic change")
    repo.command({ "checkout", "main" })
    return target
  end
  local function submit(handle)
    invoke(handle, "y")
    eventually(function()
      local refresh = session.refresh
      return not session.popup.repository_busy and refresh and not refresh.loading and not refresh.running
        and not next(refresh.pending) and #refresh.callbacks == 0
    end)
  end
  before_each(function()
    require("codediff").setup({ explorer = { auto_open_on_cursor = false } })
    lifecycle.cleanup_all()
    notifications, errors, notify = {}, {}, vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = message
      if level == vim.log.levels.ERROR then errors[#errors + 1] = message end
    end
    repo = repositories.new({ key = "branch-merge", build = function(seed)
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

  it("fast-forwards the checked-out branch and reloads ordinary buffers", function()
    local target = topic()
    local ctx = open()
    local buf = vim.fn.bufnr(repo.path("tracked.txt"))
    submit(choose(ctx))
    assert.equals(target, oid())
    assert.equals("main", vim.trim(repo.command({ "branch", "--show-current" })))
    eventually(function() return vim.deep_equal({ "incoming" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) end)
    assert.equals("", repo.command({ "status", "--porcelain" }))
  end)

  it("creates a two-parent merge for clean divergence", function()
    local target = topic()
    repo.write_file("other.txt", { "current" })
    local current = repo.commit("current change")
    submit(choose(open()))
    assert.equals(current, oid("HEAD^1"))
    assert.equals(target, oid("HEAD^2"))
    assert.same({ "incoming" }, repo.read_file("tracked.txt"))
    assert.same({ "current" }, repo.read_file("other.txt"))
    h.assert_contains(repo.command({ "log", "-1", "--format=%B" }), "Merge ")
    h.assert_contains(repo.command({ "log", "-1", "--format=%B" }), "topic")
  end)

  it("opens real incoming/current/base/result buffers for actual unmerged status", function()
    topic()
    repo.write_file("tracked.txt", { "current" })
    repo.commit("current conflict")
    submit(choose(open()))
    eventually(function()
      if not session.merge or not session.refresh or session.refresh.loading then return false end
      for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr, session.base_bufnr, session.result_bufnr }) do
        if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return false end
      end
      return session.source_revisions and session.source_revisions.original == ":3" and session.source_revisions.modified == ":2"
    end)
    assert.same({ "incoming" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))
    assert.same({ "current" }, vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false))
    assert.same({ "base" }, vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false))
    h.assert_contains(repo.command({ "ls-files", "--unmerged" }), "tracked.txt")
    assert.same({}, errors, "Expected conflicts should open the resolver without an error prompt")
  end)

  for _, key in ipairs({ "n", "q", "<Esc>", "<C-q>" }) do
    it("cancels confirmation with " .. key .. " without repository mutations", function()
      topic()
      local before = oid()
      local handle = choose(open())
      local index = repo.command({ "write-tree" })
      invoke(handle, key)
      assert.equals(before, oid())
      assert.equals(index, repo.command({ "write-tree" }))
      assert.same({ "base" }, repo.read_file("tracked.txt"))
      assert.equals("", repo.command({ "status", "--porcelain" }))
    end)
  end

  for _, staged in ipairs({ false, true }) do
    it("protects dirty tracked " .. (staged and "index" or "worktree"), function()
      topic()
      local ctx = open()
      local handle = choose(ctx)
      repo.write_file("other.txt", { "keep me" })
      if staged then repo.command({ "add", "other.txt" }) end
      submit(handle)
      assert.is_true(notified("tracked worktree or index has changes"))
      assert.equals(repo.seed.base, oid())
      assert.same({ "keep me" }, repo.read_file("other.txt"))
      assert.equals(staged and "keep me\n" or "other base\n", repo.blob(":0", "other.txt"))
    end)
  end

  it("protects unsaved ordinary buffers, including untracked files", function()
    topic()
    local handle = choose(open())
    local buf = vim.fn.bufadd(repo.path("unsaved.txt"))
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep unsaved" })
    submit(handle)
    assert.is_true(notified("unsaved buffer"))
    assert.equals(repo.seed.base, oid())
    assert.is_true(vim.bo[buf].modified)
  end)

  it("rejects a different branch even when its HEAD commit is unchanged", function()
    topic()
    local handle = choose(open())
    repo.command({ "checkout", "-b", "other" })
    submit(handle)
    assert.is_true(notified("HEAD changed"))
    assert.equals(repo.seed.base, oid())
    assert.equals("other", vim.trim(repo.command({ "branch", "--show-current" })))
  end)

  it("rejects a changed commit on the same destination branch", function()
    topic()
    local handle = choose(open())
    local changed = repo.commit("external commit")
    submit(handle)
    assert.is_true(notified("HEAD changed"))
    assert.equals(changed, oid())
  end)

  it("merges the confirmed commit even when the source ref moves", function()
    local target = topic()
    local handle = choose(open())
    repo.command({ "update-ref", "refs/heads/topic", repo.seed.base })
    submit(handle)
    assert.equals(target, oid())
  end)

  it("commits an explicitly staged Current-only resolution with no tree diff", function()
    local incoming = topic()
    repo.write_file("tracked.txt", { "current" })
    local current = repo.commit("current conflict")
    local ctx = open()
    submit(choose(ctx))
    eventually(function() return session.merge and session.refresh and not session.refresh.loading end)
    repo.command({ "checkout", "--ours", "--", "tracked.txt" })
    repo.command({ "add", "--", "tracked.txt" })
    assert.equals("", repo.command({ "diff", "--cached" }))
    local handle = actions.commit(ctx)
    eventually(function()
      return not vim.inspect(vim.api.nvim_win_get_config(handle.winid).title):find("reading HEAD", 1, true)
    end)
    vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, { "Keep Current resolution" })
    invoke(handle, "<C-s>")
    eventually(function() return not session.popup.repository_busy end)
    assert.equals(current, oid("HEAD^1"))
    assert.equals(incoming, oid("HEAD^2"))
    assert.equals(oid("HEAD^1^{tree}"), oid("HEAD^{tree}"))
    assert.equals(0, vim.fn.filereadable(repo.git_path("MERGE_HEAD")))
    assert.same({ "current" }, repo.read_file("tracked.txt"))
  end)
  it("ignores confirmation callbacks after the dialog is replaced", function()
    topic()
    local ctx = open()
    local handle = choose(ctx)
    local callback
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, "n")) do
      if map.lhs == "y" then callback = map.callback end
    end
    actions.branches(ctx)
    callback()
    assert.equals(repo.seed.base, oid())
    assert.equals("", repo.command({ "status", "--porcelain" }))
  end)

  it("reloads changed files and refreshes even after a post-merge hook fails", function()
    local target = topic()
    local ctx = open()
    local buf = vim.fn.bufnr(repo.path("tracked.txt"))
    local hook = repo.git_path("hooks/post-merge")
    vim.fn.writefile({ "#!/bin/sh", "echo post-merge-ran >&2", "exit 1" }, hook)
    assert((vim.uv or vim.loop).fs_chmod(hook, 493))
    submit(choose(ctx))
    assert.equals(target, oid())
    eventually(function()
      return vim.deep_equal({ "incoming" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        and session.refresh and not session.refresh.loading and not session.refresh.running
    end)
    assert.is_false(session.merge == true)
  end)


  it("surfaces real Git failures without aborting or opening a false conflict resolver", function()
    topic()
    repo.command({ "config", "merge.ff", "false" })
    local hook = repo.git_path("hooks/pre-merge-commit")
    vim.fn.writefile({ "#!/bin/sh", "echo deliberate-merge-failure >&2", "exit 1" }, hook)
    assert((vim.uv or vim.loop).fs_chmod(hook, 493))
    submit(choose(open()))
    assert.is_true(notified("deliberate-merge-failure"))
    assert.equals(repo.seed.base, oid())
    assert.same({ "incoming" }, repo.read_file("tracked.txt"))
    assert.equals("", repo.command({ "ls-files", "--unmerged" }))
    assert.is_false(session.merge == true)
    assert.equals(1, vim.fn.filereadable(repo.git_path("MERGE_HEAD")))
  end)
end)
