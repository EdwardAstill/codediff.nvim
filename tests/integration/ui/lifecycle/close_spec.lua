local commands = require("codediff.commands")
local lifecycle = require("codediff.ui.lifecycle")

local created_buffers = {}
local created_files = {}
local merge_repo

local function reset_tabs()
  vim.cmd("tabnew")
  vim.cmd("tabonly!")
end

local function create_session(exit_on_close)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  vim.cmd("vsplit")
  local windows = vim.api.nvim_tabpage_list_wins(tabpage)
  local original_bufnr = vim.api.nvim_create_buf(false, true)
  local modified_bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(created_buffers, original_bufnr)
  table.insert(created_buffers, modified_bufnr)
  vim.api.nvim_win_set_buf(windows[1], original_bufnr)
  vim.api.nvim_win_set_buf(windows[2], modified_bufnr)
  lifecycle.create_session(tabpage, {
    original = "original.txt",
    modified = "modified.txt",
    exit_on_close = exit_on_close,
  }, {
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = windows[1],
    modified_win = windows[2],
    lines_diff = {},
  })
  return tabpage
end

local function create_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  table.insert(created_files, path)
  return path
end

describe("CodeDiff close", function()
  before_each(function()
    lifecycle.setup()
    created_buffers = {}
    created_files = {}
    reset_tabs()
  end)

  after_each(function()
    lifecycle.cleanup_all()
    reset_tabs()
    if merge_repo then
      merge_repo.cleanup()
      merge_repo = nil
    end
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    for _, path in ipairs(created_files) do
      vim.fn.delete(path)
    end
  end)

  it("closes only the CodeDiff tab when another tab exists", function()
    local tabpage = create_session(false)
    local close_count = 0
    local autocmd = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffClose",
      callback = function()
        close_count = close_count + 1
      end,
    })

    assert.is_true(lifecycle.close(tabpage))

    assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.equals(1, #vim.api.nvim_list_tabpages())
    assert.is_nil(lifecycle.get_session(tabpage))
    assert.equals(1, close_count)
    vim.api.nvim_del_autocmd(autocmd)
  end)

  it("leaves a replacement tab when closing the last CodeDiff tab", function()
    local tabpage = create_session(false)
    vim.cmd("tabonly!")

    assert.is_true(lifecycle.close(tabpage))

    local tabs = vim.api.nvim_list_tabpages()
    assert.equals(1, #tabs)
    assert.is_not.equal(tabpage, tabs[1])
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("keeps the session when unsaved-change confirmation is cancelled", function()
    local tabpage = create_session(false)
    vim.cmd("tabonly!")
    local path = create_file({ "original" })
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "modified" })
    lifecycle.track_conflict_file(tabpage, path)
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end

    local closed = lifecycle.close(tabpage)
    vim.fn.confirm = original_confirm

    assert.is_false(closed)
    assert.is_true(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.is_not_nil(lifecycle.get_session(tabpage))
    assert.equals(1, #vim.api.nvim_list_tabpages())
  end)

  it("exits Neovim only for an opted-in session", function()
    local tabpage = create_session(true)
    local original_cmd = vim.cmd
    local qall_called = false
    vim.cmd = function(command)
      if command == "qall" then
        qall_called = true
        return
      end
      return original_cmd(command)
    end

    local ok, closed = pcall(lifecycle.close, tabpage)
    vim.cmd = original_cmd

    assert.is_true(ok)
    assert.is_true(closed)
    assert.is_true(qall_called)
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("closes through the :CodeDiff toggle", function()
    local tabpage = create_session(false)

    commands.vscode_diff({ fargs = {} })

    assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
    assert.is_nil(lifecycle.get_session(tabpage))
  end)

  it("preserves merge edits on keep-and-close without reporting unresolved mergetool success", function()
    merge_repo = require("tests.fixtures.refresh_repo").new("merge")
    local filename = merge_repo.path("merge.txt")
    local disk = merge_repo.read_file("merge.txt")
    vim.cmd("CodeDiff merge " .. vim.fn.fnameescape(filename))
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session)
    local bufnr = session.result_bufnr
    table.insert(created_buffers, bufnr)
    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "manual result" })

    session.exit_on_close = true
    assert.is_false(lifecycle.close(tabpage))
    assert.equals(session, lifecycle.get_session(tabpage))
    assert.same(disk, merge_repo.read_file("merge.txt"))

    session.exit_on_close = false
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function() return 3 end
    local ok, closed = pcall(lifecycle.close, tabpage)
    vim.fn.confirm = original_confirm
    assert.is_true(ok, closed)
    assert.is_true(closed)
    assert.is_true(vim.bo[bufnr].modified)
    assert.equals("manual result", vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1])
    assert.same(disk, merge_repo.read_file("merge.txt"))

    vim.cmd("CodeDiff merge " .. vim.fn.fnameescape(filename))
    local reopened = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
    assert.equals(bufnr, reopened.result_bufnr)
    assert.equals("manual result", vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1])
    assert.equals(2, require("codediff.ui.conflict.tracking").unresolved_count(reopened))

    require("codediff.ui.conflict").accept_all_current(reopened.tabpage)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
    local oid = vim.trim(merge_repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = "new incoming\n" }))
    merge_repo.command({ "update-index", "--index-info" }, 0, { stdin = "100644 " .. oid .. " 3\tmerge.txt\n" })
    reopened.exit_on_close = true
    assert.is_false(lifecycle.close(reopened.tabpage))
    assert.equals(reopened, lifecycle.get_session(reopened.tabpage))
    assert.equals("new incoming\n", merge_repo.blob(":3", "merge.txt"))
  end)
end)
