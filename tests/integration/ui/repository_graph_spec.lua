local h = require("tests.support")
local repositories = require("tests.support.repository")
local lifecycle = require("codediff.ui.lifecycle")
local graph = require("codediff.ui.graph")
local runner = require("codediff.core.git.runner")
h.ensure_plugin_loaded()

local function eventually(predicate)
  assert.is_true(vim.wait(10000, predicate, 20), "repository graph should settle")
end

local function text(handle)
  return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

local function invoke(handle, key)
  vim.api.nvim_set_current_win(handle.winid)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, "n")) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == vim.api.nvim_replace_termcodes(key, true, true, true) then
      map.callback()
      return
    end
  end
  error("Missing graph mapping: " .. key)
end

local function select(handle, fragment)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
    if line:find(fragment, 1, true) then
      vim.api.nvim_win_set_cursor(handle.winid, { row, 0 })
      return row
    end
  end
  error("Missing graph entry: " .. fragment)
end

describe("Native repository graph", function()
  local repo, session, notify, notifications, run_async, columns, lines

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

  local function loaded(ctx)
    local handle = graph.open(ctx)
    eventually(function() return text(handle):find("HEAD: ", 1, true) ~= nil end)
    return handle
  end

  local function confirmation(handle, key)
    invoke(handle, key)
    local result = session.popup.dialog
    assert.is_not.equals(handle, result)
    return result
  end

  local function submit(handle)
    invoke(handle, "y")
    eventually(function()
      return not session.popup.repository_busy and session.refresh and not session.refresh.loading and not session.refresh.running
        and not next(session.refresh.pending) and #session.refresh.callbacks == 0
    end)
  end

  local function save_result()
    eventually(function() return session.merge and session.result_bufnr and vim.api.nvim_buf_is_loaded(session.result_bufnr) end)
    vim.api.nvim_buf_call(session.result_bufnr, function() vim.cmd("silent write") end)
  end

  local function topic()
    repo.command({ "checkout", "-b", "topic" })
    repo.write_file("tracked.txt", { "first topic" })
    local first = repo.commit("first topic")
    repo.write_file("tracked.txt", { "second topic" })
    local tip = repo.commit("second topic")
    repo.command({ "checkout", "main" })
    return first, tip
  end

  before_each(function()
    lifecycle.cleanup_all()
    require("codediff").setup({ explorer = { auto_refresh = false, auto_open_on_cursor = false } })
    notify, run_async = vim.notify, runner.run_async
    notifications = {}
    vim.notify = function(message) notifications[#notifications + 1] = message end
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 36
    repo = repositories.new({ key = "repository-graph", build = function(seed)
      seed.write_file("tracked.txt", { "base" })
      return { base = seed.commit("base") }
    end })
  end)

  after_each(function()
    runner.run_async = run_async
    lifecycle.cleanup_all()
    vim.notify = notify
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #repo.root) == repo.root then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    h.close_extra_tabs()
    repo.cleanup()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("renders local and remote decorations with checked-out identity, and freezes decorated selections", function()
    local _, tip = topic()
    repo.command({ "update-ref", "refs/remotes/origin/topic", tip })
    local ctx = open()
    local handle = loaded(ctx)
    h.assert_contains(text(handle), "HEAD: main @ " .. repo.seed.base)
    h.assert_contains(text(handle), "HEAD -> main")
    h.assert_contains(text(handle), "origin/topic")
    h.assert_contains(text(handle), "topic")
    assert.is_false(vim.wo[handle.winid].wrap)
    select(handle, "second topic")
    repo.command({ "branch", "-f", "topic", repo.seed.base })
    repo.command({ "update-ref", "refs/remotes/origin/topic", repo.seed.base })
    local confirm = confirmation(handle, "m")
    h.assert_contains(text(confirm), tip)
    submit(confirm)
    assert.equals(tip, oid())
    assert.equals(repo.seed.base, oid("topic"))
    assert.same({ "second topic" }, repo.read_file("tracked.txt"))
  end)

  it("merges an undecorated ancestor commit rather than its branch tip", function()
    local first, tip = topic()
    local handle = loaded(open())
    select(handle, "first topic")
    local confirm = confirmation(handle, "m")
    h.assert_contains(text(confirm), first)
    submit(confirm)
    assert.equals(first, oid())
    assert.equals(tip, oid("topic"))
    assert.same({ "first topic" }, repo.read_file("tracked.txt"))
  end)

  it("rebases the checked-out branch onto the selected commit", function()
    local first, tip = topic()
    repo.write_file("local.txt", { "local change" })
    local original = repo.commit("local commit")
    local handle = loaded(open())
    select(handle, "first topic")
    local confirm = confirmation(handle, "r")
    h.assert_contains(text(confirm), first)
    submit(confirm)
    assert.equals(first, oid("HEAD^"))
    assert.is_not.equals(original, oid())
    assert.equals(tip, oid("topic"))
    assert.same({ "first topic" }, repo.read_file("tracked.txt"))
    assert.same({ "local change" }, repo.read_file("local.txt"))
  end)

  it("preserves merge edges and ignores headers and connector rows", function()
    topic()
    repo.write_file("local.txt", { "local change" })
    repo.commit("local commit")
    repo.command({ "merge", "--no-ff", "topic", "-m", "merged topic" })
    local handle = loaded(open())
    local connector
    for row, line in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
      if line:find("\\", 1, true) or line:find("/", 1, true) then
        if line:match("^[ |/\\_%.%-]+$") then connector = row; break end
      end
    end
    assert.is_not_nil(connector)
    for _, row in ipairs({ 1, 2, connector }) do
      vim.api.nvim_win_set_cursor(handle.winid, { row, 0 })
      invoke(handle, "m")
      invoke(handle, "r")
      assert.equals(handle, session.popup.dialog)
    end
    select(handle, "merged topic")
    h.assert_contains(text(confirmation(handle, "m")), oid())
  end)

  it("shows detached HEAD even when no ref reaches its commit", function()
    repo.command({ "checkout", "--detach" })
    repo.write_file("tracked.txt", { "detached" })
    local detached = repo.commit("unreferenced detached commit")
    local handle = loaded(open())
    h.assert_contains(text(handle), "HEAD: detached HEAD @ " .. detached)
    h.assert_contains(text(handle), "unreferenced detached commit")
    h.assert_contains(vim.inspect(vim.api.nvim_win_get_config(handle.winid).title), "detached HEAD @")
  end)

  it("shows an unborn branch and empty history without an error", function()
    repo.cleanup()
    repo = repositories.new({ key = "repository-graph-unborn", unborn = true })
    repo.write_file("tracked.txt", { "unborn content" })
    repo.command({ "add", "tracked.txt" })
    local handle = loaded(open())
    h.assert_contains(text(handle), "HEAD: main @ unborn")
    h.assert_contains(text(handle), "No commits yet")
    vim.api.nvim_win_set_cursor(handle.winid, { 3, 0 })
    invoke(handle, "m")
    assert.equals(handle, session.popup.dialog)
    assert.same({}, notifications)
  end)

  it("escapes control text without changing the selected object ID", function()
    repo.command({ "checkout", "-b", "topic" })
    local target = repo.commit("control\ttext\27[31m")
    repo.command({ "checkout", "main" })
    local handle = loaded(open())
    local escaped = vim.fn.strtrans("control\ttext\27[31m")
    h.assert_contains(text(handle), escaped)
    assert.is_nil(text(handle):find("\27", 1, true))
    select(handle, escaped)
    h.assert_contains(text(confirmation(handle, "m")), target)
  end)

  it("grows a stable history prefix so older commits remain selectable", function()
    local parent = repo.seed.base
    local tree = vim.trim(repo.command({ "rev-parse", "HEAD^{tree}" }))
    for index = 1, 205 do
      parent = vim.trim(repo.command({ "commit-tree", tree, "-p", parent, "-m", "history " .. index }))
    end
    repo.command({ "update-ref", "refs/heads/main", parent })
    local handle = loaded(open())
    local prefix = text(handle):match("(.-)\n\nL: load")
    assert.is_not_nil(prefix)
    assert.is_nil(text(handle):find(" base", 1, true))
    select(handle, "history 205")
    invoke(handle, "L")
    eventually(function() return text(handle):find(" base", 1, true) ~= nil end)
    assert.equals(prefix, text(handle):sub(1, #prefix))
    assert.is_nil(text(handle):find("L: load", 1, true))
    select(handle, " base")
    h.assert_contains(text(confirmation(handle, "m")), repo.seed.base)
  end)

  it("discards stale refresh results and callbacks after closing", function()
    local delayed = {}
    runner.run_async = function(args, opts, callback)
      if args[1] ~= "log" then return run_async(args, opts, callback) end
      return run_async(args, opts, function(err, output)
        vim.schedule(function() delayed[#delayed + 1] = function() callback(err, output) end end)
      end)
    end
    local ctx = open()
    local handle = graph.open(ctx)
    eventually(function() return #delayed == 1 end)
    repo.commit("after refresh")
    invoke(handle, "R")
    eventually(function() return #delayed == 2 end)
    delayed[2]()
    eventually(function() return text(handle):find("after refresh", 1, true) ~= nil end)
    local refreshed = text(handle)
    delayed[1]()
    vim.wait(50, function() return false end)
    assert.equals(refreshed, text(handle))
    invoke(handle, "R")
    eventually(function() return #delayed == 3 end)
    invoke(handle, "q")
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    delayed[3]()
    vim.wait(50, function() return false end)
    assert.is_nil(session.popup.dialog)
  end)

  it("shows merge conflict state and resumes through real continue/abort confirmations", function()
    topic()
    repo.write_file("tracked.txt", { "current conflict" })
    local current = repo.commit("current conflict")
    repo.command({ "merge", "topic" }, 1)
    local ctx = open()
    save_result()
    local handle = loaded(ctx)
    h.assert_contains(text(handle), "In progress: merge")
    h.assert_contains(text(handle), "c continue / a abort")
    local continue = confirmation(handle, "c")
    h.assert_contains(vim.inspect(vim.api.nvim_win_get_config(continue.winid).title):lower(), "continue")
    invoke(continue, "n")
    handle = loaded(ctx)
    submit(confirmation(handle, "a"))
    assert.equals(current, oid())
    assert.same({ "current conflict" }, repo.read_file("tracked.txt"))
    assert.equals("", repo.command({ "ls-files", "--unmerged" }))
    h.assert_contains(text(loaded(ctx)), "HEAD: main @ " .. current)
  end)

  it("shows rebase state while detached and aborts back to its original branch", function()
    topic()
    repo.write_file("tracked.txt", { "current conflict" })
    local current = repo.commit("current conflict")
    repo.command({ "rebase", "topic" }, 1)
    local ctx = open()
    save_result()
    local handle = loaded(ctx)
    h.assert_contains(text(handle), "In progress: rebase")
    h.assert_contains(text(handle), "HEAD: detached HEAD @")
    submit(confirmation(handle, "a"))
    assert.equals(current, oid())
    assert.equals("main", vim.trim(repo.command({ "branch", "--show-current" })))
    assert.same({ "current conflict" }, repo.read_file("tracked.txt"))
  end)

  it("shows unsupported operation state without offering graph resume actions", function()
    local first = topic()
    repo.write_file("tracked.txt", { "current conflict" })
    repo.commit("current conflict")
    repo.command({ "cherry-pick", first }, 1)
    local handle = loaded(open())
    h.assert_contains(text(handle), "In progress: cherry-pick")
    invoke(handle, "c")
    invoke(handle, "a")
    assert.equals(handle, session.popup.dialog)
    assert.is_nil(text(handle):find("c continue / a abort", 1, true))
    assert.is_not.equals("", repo.command({ "ls-files", "--unmerged" }))
  end)

  it("opens the native graph from the review's g action", function()
    topic()
    open()
    invoke({ winid = session.modified_win, bufnr = session.modified_bufnr }, "g")
    eventually(function()
      return session.popup.dialog and text(session.popup.dialog):find("HEAD: main @ ", 1, true) ~= nil
    end)
    h.assert_contains(text(session.popup.dialog), "second topic")
    h.assert_contains(text(session.popup.dialog), repo.seed.base)
    invoke(session.popup.dialog, "q")
    assert.is_nil(session.popup.dialog)
  end)

  it("rejects missing popups and busy repositories", function()
    assert.is_nil(graph.open({ tabpage = vim.api.nvim_get_current_tabpage() }))
    local ctx = open()
    session.popup.repository_busy = true
    assert.is_nil(graph.open(ctx))
    session.popup.repository_busy = nil
    assert.is_nil(session.popup.dialog)
    assert.equals(2, #notifications)
  end)
end)
