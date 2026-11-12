local git = require("codediff.core.git")
local tracking = require("codediff.ui.conflict.tracking")
local fixtures = require("tests.support.repository")

local function await(start)
  local done, failure, value
  start(function(err, result)
    failure, value, done = err, result, true
  end)
  assert.is_true(vim.wait(5000, function() return done end, 10), "Git callback timed out")
  return failure, value
end

local function build(repo)
  repo.write_file("dir/a.txt", { "base" })
  repo.write_file("dir/b.txt", { "base" })
  repo.write_file("clean.txt", { "unchanged" })
  repo.commit("base")
  repo.command({ "checkout", "-b", "incoming" })
  repo.write_file("dir/a.txt", { "incoming" })
  repo.write_file("dir/b.txt", { "incoming" })
  repo.commit("incoming")
  repo.command({ "checkout", "main" })
  repo.write_file("dir/a.txt", { "current" })
  repo.write_file("dir/b.txt", { "current" })
  repo.commit("current")
end

local function changed_line()
  return { changes = { {
    original = { start_line = 1, end_line = 2 },
    modified = { start_line = 1, end_line = 2 },
  } } }
end

describe("merge input validation and staging safety", function()
  local repo, buffers, runner, run_async, changes, get_status, notify

  before_each(function()
    repo = fixtures.new({ key = "merge-safety", build = build })
    repo.command({ "merge", "incoming", "--no-edit" }, 1)
    repo.write_file("clean.txt", { "ordinary unstaged edit" })
    buffers = {}
    runner = require("codediff.core.git.runner")
    run_async = runner.run_async
    changes = require("codediff.core.git.changes")
    get_status = changes.get_status
    notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    runner.run_async = run_async
    changes.get_status = get_status
    vim.notify = notify
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    repo.cleanup()
  end)

  local function inputs(name)
    local err, value = await(function(cb) git.get_merge_inputs(repo.dir, name, cb) end)
    assert.is_nil(err)
    return value
  end

  local function review(name)
    local source = inputs(name)
    -- A manually saved Base is not an explicit approval.
    repo.write_file(name, source.base_lines)
    local buf = vim.fn.bufadd(repo.path(name))
    vim.fn.bufload(buf)
    buffers[#buffers + 1] = buf
    local session = { result_bufnr = buf, merge_inputs = source }
    local ok, err = tracking.bind_result(session, source.base_lines, {
      base_to_original_diff = changed_line(), base_to_modified_diff = changed_line(),
      original_lines = source.incoming_lines, modified_lines = source.current_lines,
    })
    assert.is_true(ok, err)
    assert.equals(1, tracking.unresolved_count(session))
    return session, source
  end

  local function use_base(session, source, save)
    local ok, err = tracking.apply(session, { {
      block = session.conflict_blocks[1], lines = source.base_lines,
      resolved = true, accepted = "base",
    } })
    assert.is_true(ok, err)
    if save then
      vim.api.nvim_buf_call(session.result_bufnr, function() vim.cmd("silent write") end)
    end
  end

  local scopes = {
    file = function(cb) git.stage_file(repo.dir, "dir/a.txt", cb) end,
    folder = function(cb) git.stage_file(repo.dir, "dir", cb) end,
    all = function(cb) git.stage_all(repo.dir, cb) end,
  }

  for scope, stage in pairs(scopes) do
    for _, state in ipairs({ "unopened", "unresolved", "unsaved" }) do
      it("refuses " .. state .. " conflicts for " .. scope .. " without partial staging", function()
        if state ~= "unopened" then
          local session, source = review("dir/a.txt")
          if state == "unsaved" then
            use_base(session, source, false)
            assert.is_true(vim.bo[session.result_bufnr].modified)
          end
        end
        local before = repo.command({ "ls-files", "--stage", "-z" })
        local err = await(stage)
        assert.is_string(err)
        assert.equals(before, repo.command({ "ls-files", "--stage", "-z" }))
      end)
    end

    it("stages saved explicitly approved Base for " .. scope, function()
      local session, source = review("dir/a.txt")
      use_base(session, source, true)
      if scope ~= "file" then
        local other, other_source = review("dir/b.txt")
        use_base(other, other_source, true)
      end
      assert.is_nil(await(stage))
      assert.equals("base\n", repo.blob(":0", "dir/a.txt"))
      assert.equals("", repo.command({ "ls-files", "--unmerged", "--", "dir/a.txt" }))
      assert.equals(session.result_bufnr, tracking.get_state(repo.path("dir/a.txt")).result_bufnr)
    end)
  end

  it("preflights every conflict before staging any ordinary or approved file", function()
    local session, source = review("dir/a.txt")
    use_base(session, source, true)
    local before = repo.command({ "ls-files", "--stage", "-z" })
    assert.is_string(await(function(cb) git.stage_all(repo.dir, cb) end))
    assert.equals(before, repo.command({ "ls-files", "--stage", "-z" }))
    assert.equals("unchanged\n", repo.blob(":0", "clean.txt"))
  end)

  it("keeps ordinary file staging available with unrelated conflicts", function()
    assert.is_nil(await(function(cb) git.stage_file(repo.dir, "clean.txt", cb) end))
    assert.equals("ordinary unstaged edit\n", repo.blob(":0", "clean.txt"))
  end)

  it("rechecks approval after an asynchronous staging request", function()
    local session, source = review("dir/a.txt")
    use_base(session, source, true)
    local err = await(function(cb)
      git.stage_file(repo.dir, "dir/a.txt", cb)
      vim.api.nvim_buf_set_lines(session.result_bufnr, 0, 1, false, { "not saved or approved" })
    end)
    assert.is_string(err)
    assert.not_equal("", repo.command({ "ls-files", "--unmerged", "--", "dir/a.txt" }))
  end)

  it("rechecks input identity at the mutation boundary", function()
    local session, source = review("dir/a.txt")
    use_base(session, source, true)
    local oid = vim.trim(repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = "new incoming\n" }))
    local err = await(function(cb)
      git.stage_file(repo.dir, "dir/a.txt", cb)
      repo.command({ "update-index", "--index-info" }, 0, { stdin = "100644 " .. oid .. " 3\tdir/a.txt\n" })
    end)
    assert.matches("inputs changed", err)
    assert.not_equal("", repo.command({ "ls-files", "--unmerged", "--", "dir/a.txt" }))
  end)

  it("refuses externally changed working bytes despite a clean approved buffer", function()
    local session, source = review("dir/a.txt")
    use_base(session, source, true)
    repo.write_file("dir/a.txt", { "external unreviewed edit" })
    assert.is_false(vim.bo[session.result_bufnr].modified)
    assert.is_string(await(function(cb) git.stage_file(repo.dir, "dir/a.txt", cb) end))
    assert.not_equal("", repo.command({ "ls-files", "--unmerged", "--", "dir/a.txt" }))
  end)

  it("refuses staging when the actual index cannot be read", function()
    local before = repo.command({ "ls-files", "--stage", "-z" })
    local err = await(function(cb) git.stage_all(repo.path("missing-directory"), cb) end)
    assert.matches("Cannot read unmerged index", err)
    assert.equals(before, repo.command({ "ls-files", "--stage", "-z" }))
  end)

  it("does not permit hunk patches or reset to bypass conflict review", function()
    local patch = "--- a/dir/a.txt\n+++ b/dir/a.txt\n@@ -1 +1 @@\n-current\n+base\n"
    assert.is_string(await(function(cb) git.apply_patch(repo.dir, patch, { paths = { "dir/a.txt" } }, cb) end))
    local session, source = review("dir/a.txt")
    use_base(session, source, true)
    assert.is_string(await(function(cb) git.apply_patch(repo.dir, patch, { paths = { "dir/a.txt" } }, cb) end))
    assert.is_string(await(function(cb) git.unstage_file(repo.dir, "dir/a.txt", cb) end))
    assert.is_string(await(function(cb) git.unstage_all(repo.dir, cb) end))
    assert.not_equal("", repo.command({ "ls-files", "--unmerged", "--", "dir/a.txt" }))
  end)

  it("reads immutable Incoming, Current and Base with fixed roles", function()
    local source = inputs("dir/a.txt")
    assert.same({ "base" }, source.base_lines)
    assert.same({ "current" }, source.current_lines)
    assert.same({ "incoming" }, source.incoming_lines)
    assert.is_string(source.identity)
  end)

  it("rejects ordinary files before creating a merge view or editing a buffer", function()
    local view = require("codediff.ui.view")
    local create, opened = view.create, false
    view.create = function() opened = true end
    local before = repo.read_file("clean.txt")
    local ok, err = pcall(require("codediff.commands.handlers.merge").run, { fargs = { repo.path("clean.txt") } }, {})
    view.create = create
    assert.is_true(ok, err)
    assert.is_false(opened)
    assert.same(before, repo.read_file("clean.txt"))
  end)

  it("does not replace status or stage read failures with empty Base", function()
    changes.get_status = function(_, callback) callback("injected status failure") end
    local err, source = await(function(cb) git.get_merge_inputs(repo.dir, "dir/a.txt", cb) end)
    assert.matches("injected status failure", err)
    assert.is_nil(source)
    changes.get_status = get_status
    runner.run_async = function(args, opts, callback)
      if args[1] == "cat-file" then
        callback("injected stage failure")
      else
        run_async(args, opts, callback)
      end
    end
    err, source = await(function(cb) git.get_merge_inputs(repo.dir, "dir/a.txt", cb) end)
    assert.matches("injected stage failure", err)
    assert.is_nil(source)
  end)

  it("rejects binary and incomplete delete/rename inputs", function()
    local oid = vim.trim(repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = "binary\0content" }))
    repo.command({ "update-index", "--index-info" }, 0, { stdin = "100644 " .. oid .. " 2\tdir/a.txt\n" })
    local err = await(function(cb) git.get_merge_inputs(repo.dir, "dir/a.txt", cb) end)
    assert.matches("binary conflict", err)
    repo.command({ "update-index", "--index-info" }, 0, {
      stdin = "0 " .. string.rep("0", 40) .. "\tdir/a.txt\n100644 " .. oid .. " 3\tdir/a.txt\n",
    })
    err = await(function(cb) git.get_merge_inputs(repo.dir, "dir/a.txt", cb) end)
    assert.matches("rename/delete conflict", err)
  end)

  it("accepts an actual empty Base and a missing Base only for add/add", function()
    local incoming = vim.trim(repo.command({ "rev-parse", ":3:dir/a.txt" }))
    local current = vim.trim(repo.command({ "rev-parse", ":2:dir/a.txt" }))
    local empty = vim.trim(repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = "" }))
    repo.command({ "update-index", "--index-info" }, 0, { stdin = "100644 " .. empty .. " 1\tdir/a.txt\n" })
    assert.same({}, inputs("dir/a.txt").base_lines)
    repo.command({ "update-index", "--index-info" }, 0, {
      stdin = "0 " .. string.rep("0", 40) .. "\tdir/a.txt\n100644 " .. current .. " 2\tdir/a.txt\n100644 " .. incoming .. " 3\tdir/a.txt\n",
    })
    assert.same({}, inputs("dir/a.txt").base_lines)
  end)

  it("renders unknown review state separately from explicit unresolved counts", function()
    local nodes = require("codediff.ui.explorer.nodes")
    local node = nodes.create_file_nodes({ { path = "dir/a.txt", status = "!" } }, repo.dir, "conflicts")[1]
    assert.matches("needs review", nodes.prepare_node(node, 80):content())
    local session, source = review("dir/a.txt")
    assert.matches("1 unresolved", nodes.prepare_node(node, 80):content())
    use_base(session, source, true)
    assert.matches("0 unresolved", nodes.prepare_node(node, 80):content())
    local oid = vim.trim(repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = "new incoming\n" }))
    repo.command({ "update-index", "--index-info" }, 0, { stdin = "100644 " .. oid .. " 3\tdir/a.txt\n" })
    local err, status = await(function(cb) git.get_status(repo.dir, cb, { "dir/a.txt" }) end)
    assert.is_nil(err)
    local stale = nodes.create_file_nodes(status.conflicts, repo.dir, "conflicts")[1]
    assert.matches("needs review", nodes.prepare_node(stale, 80):content())
  end)
end)
