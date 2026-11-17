local h = require("tests.support")
local fixture = require("tests.fixtures.refresh_repo")
local lifecycle = require("codediff.ui.lifecycle")
local popup = require("codediff.ui.popup")
local refresh = require("codediff.ui.refresh")
local revision = require("codediff.core.git.revision")

local function title(win)
  local value = vim.api.nvim_win_get_config(win).title
  if type(value) == "string" then return vim.trim(value) end
  local parts = {}
  for _, chunk in ipairs(value or {}) do parts[#parts + 1] = chunk[1] end
  return vim.trim(table.concat(parts))
end

local function titles(session)
  return { title(session.original_win), title(session.modified_win) }
end

local function expect_titles(session, original, modified)
  assert.is_true(vim.wait(10000, function()
    return vim.deep_equal({ original, modified }, titles(session))
  end, 10), vim.inspect(titles(session)))
end

describe("Status popup source titles", function()
  local repo, cwd, columns, lines, get_head

  local function open()
    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("a.txt")))
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("CodeDiff")
    assert.is_true(vim.wait(10000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.panel and session.panel.view and session.stored_diff_result and session.refresh and not session.refresh.loading
    end, 10), "status popup did not load")
    return lifecycle.get_session(tabpage)
  end

  local function select(session, group, name, status)
    session.panel.view.on_file_select({ path = name or "a.txt", status = status or "M", group = group })
    assert.is_true(vim.wait(10000, function()
      return session.panel.data.current_file_group == group and session.stored_diff_result and not session.refresh.loading
    end, 10), "selection did not finish")
  end

  local function full_refresh(session)
    local done = false
    refresh.request(session.tabpage, { full = true }, function() done = true end)
    assert.is_true(vim.wait(10000, function() return done end, 10), "full refresh did not finish")
  end

  before_each(function()
    h.ensure_plugin_loaded()
    lifecycle.cleanup_all()
    cwd, columns, lines = vim.fn.getcwd(), vim.o.columns, vim.o.lines
    get_head = revision.get_head
    vim.o.columns, vim.o.lines = 120, 36
    require("codediff").setup({ diff = { layout = "side-by-side" }, explorer = { auto_refresh = false, auto_open_on_cursor = false } })
    repo = fixture.new("workspace")
  end)

  after_each(function()
    revision.get_head = get_head
    lifecycle.cleanup_all()
    h.close_extra_tabs()
    vim.cmd("enew!")
    vim.fn.chdir(cwd)
    repo.cleanup()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("distinguishes the index baseline from HEAD and survives resize and selection changes", function()
    local session = open()
    select(session, "unstaged")
    expect_titles(session, "main (index)", "Current")
    assert.equals("index-A", vim.api.nvim_buf_get_lines(session.original_bufnr, 1, 2, false)[1])
    assert.equals("working-A", vim.api.nvim_buf_get_lines(session.modified_bufnr, 1, 2, false)[1])
    select(session, "staged")
    expect_titles(session, "main @ " .. repo.base:sub(1, 8), "Current (index)")
    assert.equals("base-A", vim.api.nvim_buf_get_lines(session.original_bufnr, 1, 2, false)[1])
    assert.equals("index-A", vim.api.nvim_buf_get_lines(session.modified_bufnr, 1, 2, false)[1])
    vim.o.columns = 100
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.same({ "main @ " .. repo.base:sub(1, 8), "Current (index)" }, titles(session))
    select(session, "unstaged")
    expect_titles(session, "main (index)", "Current")
  end)

  it("shows detached commit identity on both kinds of comparison", function()
    repo.command({ "switch", "--detach", repo.base })
    local session = open()
    select(session, "unstaged")
    expect_titles(session, repo.base:sub(1, 8) .. " (index)", "Current")
    select(session, "staged")
    expect_titles(session, repo.base:sub(1, 8), "Current (index)")
  end)

  it("retains an unborn branch name without presenting the empty tree as a commit", function()
    repo.cleanup()
    repo = fixture.new("basic", { unborn = true })
    repo.write_file("a.txt", { "new file" })
    repo.command({ "add", "a.txt" })
    repo.write_file("a.txt", { "working addition" })
    local session = open()
    select(session, "unstaged")
    expect_titles(session, "main (index)", "Current")
    select(session, "staged", "a.txt", "A")
    expect_titles(session, "main (unborn)", "Current (index)")
  end)

  it("updates on branch creation, checkout and commits through normal full refresh", function()
    local session = open()
    select(session, "staged")
    expect_titles(session, "main @ " .. repo.base:sub(1, 8), "Current (index)")
    repo.command({ "switch", "-c", "review/title" })
    full_refresh(session)
    expect_titles(session, "review/title @ " .. repo.base:sub(1, 8), "Current (index)")
    repo.command({ "switch", "main" })
    full_refresh(session)
    expect_titles(session, "main @ " .. repo.base:sub(1, 8), "Current (index)")
    local committed = repo.commit("commit reviewed changes")
    repo.write_file("a.txt", { "after commit" })
    repo.command({ "add", "a.txt" })
    full_refresh(session)
    select(session, "staged")
    expect_titles(session, "main @ " .. committed:sub(1, 8), "Current (index)")
    assert.equals("working-A", vim.api.nvim_buf_get_lines(session.original_bufnr, 1, 2, false)[1])
  end)

  it("updates HEAD identity even when a new commit leaves the selected contents unchanged", function()
    local session = open()
    select(session, "staged")
    expect_titles(session, "main @ " .. repo.base:sub(1, 8), "Current (index)")
    repo.command({ "commit", "--allow-empty", "--only", "-m", "identity only" }, 0, {
      env = { GIT_AUTHOR_DATE = "2001-03-01T12:00:00+00:00", GIT_COMMITTER_DATE = "2001-03-01T12:00:00+00:00" },
    })
    local oid = vim.trim(repo.command({ "rev-parse", "HEAD" }))
    full_refresh(session)
    expect_titles(session, "main @ " .. oid:sub(1, 8), "Current (index)")
    assert.equals("base-A", vim.api.nvim_buf_get_lines(session.original_bufnr, 1, 2, false)[1])
  end)

  it("ignores delayed metadata from an older request and a closed session", function()
    local session = open()
    select(session, "unstaged")
    expect_titles(session, "main (index)", "Current")
    local pending = {}
    revision.get_head = function(root, callback)
      get_head(root, function(err, head)
        pending[#pending + 1] = function() callback(err, head) end
      end)
    end
    popup.refresh_titles(session)
    assert.is_true(vim.wait(10000, function() return #pending == 1 end, 10))
    repo.command({ "switch", "-c", "newer/title" })
    popup.refresh_titles(session)
    assert.is_true(vim.wait(10000, function() return #pending == 2 end, 10))
    pending[2]()
    expect_titles(session, "newer/title (index)", "Current")
    pending[1]()
    assert.same({ "newer/title (index)", "Current" }, titles(session))
    popup.refresh_titles(session)
    assert.is_true(vim.wait(10000, function() return #pending == 3 end, 10))
    assert.is_true(lifecycle.close(session.tabpage))
    revision.get_head = get_head
    repo.command({ "switch", "main" })
    local replacement = open()
    expect_titles(replacement, "main (index)", "Current")
    pending[3]()
    assert.same({ "main (index)", "Current" }, titles(replacement))
  end)

  it("preserves the fixed merge roles and advertises the merge help key", function()
    repo.cleanup()
    repo = fixture.new("merge")
    local session = open()
    assert.is_true(vim.wait(10000, function() return session.result_win ~= nil end, 10))
    local expected = { "Incoming (:3)", "Current (:2)", "Base (:1)" }
    local function merge_titles()
      return { title(session.original_win), title(session.modified_win), title(session.base_win) }
    end
    assert.same(expected, merge_titles())
    assert.is_truthy(title(session.result_win):find("Result", 1, true))
    full_refresh(session)
    assert.same(expected, merge_titles())
    for _, pane in ipairs(session.panel.view.panes) do
      local footer = vim.api.nvim_win_get_config(pane.winid).footer[1][1]
      assert.is_truthy(footer:find("g? help", 1, true))
    end
  end)

  it("falls back to source labels when HEAD metadata cannot be read", function()
    local session = open()
    select(session, "unstaged")
    expect_titles(session, "main (index)", "Current")
    assert.equals(0, vim.fn.delete(repo.path(".git")))
    popup.refresh_titles(session)
    expect_titles(session, "Index", "Current")
  end)

  it("leaves explicit revision comparisons outside the status title policy", function()
    lifecycle.cleanup_all()
    repo.command({ "reset", "--hard", repo.base })
    vim.fn.chdir(repo.dir)
    vim.cmd("CodeDiff " .. repo.first .. " " .. repo.second)
    local session
    assert.is_true(vim.wait(10000, function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.stored_diff_result and session.refresh and not session.refresh.loading
    end, 10))
    assert.is_nil(session.popup)
    assert.equals(repo.first, session.original_revision)
    assert.equals(repo.second, session.modified_revision)
    local labels = { vim.api.nvim_buf_get_name(session.original_bufnr), vim.api.nvim_buf_get_name(session.modified_bufnr) }
    assert.is_truthy(labels[1]:find(repo.first, 1, true))
    assert.is_truthy(labels[2]:find(repo.second, 1, true))
    full_refresh(session)
    assert.same(labels, { vim.api.nvim_buf_get_name(session.original_bufnr), vim.api.nvim_buf_get_name(session.modified_bufnr) })
    assert.equals(repo.first, session.original_revision)
    assert.equals(repo.second, session.modified_revision)
  end)

  it("keeps history commit labels instead of replacing them with checked-out identity", function()
    repo.command({ "reset", "--hard", repo.second })
    vim.fn.chdir(repo.dir)
    vim.cmd("CodeDiff history")
    local session
    assert.is_true(vim.wait(10000, function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.original_revision and session.modified_revision
        and session.stored_diff_result and session.refresh and not session.refresh.loading
    end, 10))
    assert.is_nil(session.popup)
    assert.equals(repo.first, session.original_revision)
    assert.equals(repo.second, session.modified_revision)
    local labels = { vim.api.nvim_buf_get_name(session.original_bufnr), vim.api.nvim_buf_get_name(session.modified_bufnr) }
    assert.is_truthy(labels[1]:find(repo.first, 1, true))
    assert.is_truthy(labels[2]:find(repo.second, 1, true))
    full_refresh(session)
    assert.same(labels, { vim.api.nvim_buf_get_name(session.original_bufnr), vim.api.nvim_buf_get_name(session.modified_bufnr) })
    assert.equals(repo.first, session.original_revision)
    assert.equals(repo.second, session.modified_revision)
  end)
end)
