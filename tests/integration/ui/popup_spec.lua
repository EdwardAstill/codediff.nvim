local h = require("tests.support")
local lifecycle = require("codediff.ui.lifecycle")
local view = require("codediff.ui.view")

local function workspace_windows(session)
  return { session.panel.view.panes[1].winid, session.panel.view.panes[2].winid, session.original_win, session.modified_win }
end

local function assert_workspace(session)
  assert.is_not_nil(session.popup)
  local wins = workspace_windows(session)
  for _, win in ipairs(wins) do
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.equal("editor", vim.api.nvim_win_get_config(win).relative)
  end
  assert.equal(4, #wins)
  assert.is_true(wins[3] ~= wins[4])
  return wins
end

describe("Status popup workspace", function()
  local repo, saved_cwd, saved_columns, saved_lines, saved_hidden, saved_confirm
  local user_buffers

  local function open()
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("CodeDiff")
    assert.is_true(vim.wait(10000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.panel and session.panel.view and session.panel.view.panes
        and session.stored_diff_result and session.stored_diff_result.changes
    end, 20), "status workspace did not finish loading")
    assert.equal(tabpage, vim.api.nvim_get_current_tabpage())
    return lifecycle.get_session(tabpage)
  end

  local function select_file(session, name, status, group, side)
    session.panel.view.on_file_select({ path = name, status = status, group = group or "unstaged" })
    assert.is_true(vim.wait(10000, function()
      local ref = session[side or "modified"]
      return ref and ref.relative == name and session.stored_diff_result and session.stored_diff_result.changes
    end, 20), "selected file did not render: " .. name)
  end

  before_each(function()
    h.ensure_plugin_loaded()
    lifecycle.cleanup_all()
    saved_cwd, saved_columns, saved_lines = vim.fn.getcwd(), vim.o.columns, vim.o.lines
    saved_hidden, saved_confirm = vim.o.hidden, vim.fn.confirm
    vim.o.columns, vim.o.lines = 120, 36
    require("codediff").setup({ diff = { layout = "side-by-side" }, explorer = { auto_open_on_cursor = false } })
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "base", "second" })
    repo.write_file("deleted.txt", { "deleted content" })
    repo.write_file("staged.txt", { "staged base" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("tracked.txt", { "changed", "second" })
    repo.write_file("staged.txt", { "staged change" })
    repo.write_file("added.txt", { "new staged content" })
    repo.git({ "add", "staged.txt", "added.txt" }, 0)
    repo.write_file("new.txt", { "untracked content" })
    repo.write_file("empty.txt", {})
    vim.fn.delete(repo.path("deleted.txt"))
    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("tracked.txt")))
    user_buffers = {}
  end)

  after_each(function()
    vim.fn.confirm = saved_confirm
    lifecycle.cleanup_all()
    vim.o.hidden = true
    vim.cmd("only!")
    vim.cmd("enew!")
    for _, buf in ipairs(user_buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.chdir(saved_cwd)
    repo.cleanup()
    vim.o.columns, vim.o.lines, vim.o.hidden = saved_columns, saved_lines, saved_hidden
  end)

  it("preserves the current tab, underlying splits, unsaved buffers, focus and mappings", function()
    local working = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(working, 0, 1, false, { "unsaved working change" })
    vim.keymap.set("n", "]c", "<Cmd>echo 'user'<CR>", { buffer = working, desc = "user mapping" })
    vim.cmd("vsplit")
    local scratch = vim.api.nvim_create_buf(true, false)
    user_buffers[#user_buffers + 1] = scratch
    vim.api.nvim_win_set_buf(0, scratch)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "unsaved unnamed", "keep cursor" })
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    local return_win, return_view = vim.api.nvim_get_current_win(), vim.fn.winsaveview()
    local before_layout, before_tabs = vim.fn.winlayout(), vim.api.nvim_list_tabpages()
    local session = open()
    select_file(session, "tracked.txt", "M")
    assert_workspace(session)
    assert.same(before_layout, vim.fn.winlayout())
    assert.same(before_tabs, vim.api.nvim_list_tabpages())
    vim.o.hidden = false
    assert.is_true(lifecycle.close(session.tabpage))
    assert.same(before_layout, vim.fn.winlayout())
    assert.same(before_tabs, vim.api.nvim_list_tabpages())
    assert.equal(return_win, vim.api.nvim_get_current_win())
    assert.same(return_view, vim.fn.winsaveview())
    assert.same({ "unsaved unnamed", "keep cursor" }, vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
    assert.equal("unsaved working change", vim.api.nvim_buf_get_lines(working, 0, 1, false)[1])
    assert.is_true(vim.bo[working].modified)
    local mapping = vim.api.nvim_buf_call(working, function()
      return vim.fn.maparg("]c", "n", false, true)
    end)
    assert.equal("user mapping", mapping.desc)
    vim.bo[working].modified = false
  end)

  it("closes coherently when any of its four panes closes, and can reopen", function()
    local underlying = vim.api.nvim_tabpage_list_wins(0)
    for pane = 1, 4 do
      local session = open()
      local wins = assert_workspace(session)
      vim.api.nvim_win_close(wins[pane], true)
      assert.is_true(vim.wait(3000, function()
        return lifecycle.get_session(session.tabpage) == nil
      end, 10))
      assert.same(underlying, vim.api.nvim_tabpage_list_wins(0))
      for _, win in ipairs(wins) do
        assert.is_false(vim.api.nvim_win_is_valid(win))
      end
    end
  end)

  it("keeps all four bordered areas inside the editor after small-terminal resizes", function()
    local session = open()
    local underlying = vim.fn.winlayout()
    for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 12, 8 }, { 120, 36 } }) do
      vim.o.columns, vim.o.lines = size[1], size[2]
      vim.api.nvim_exec_autocmds("VimResized", {})
      local wins = assert_workspace(session)
      for _, win in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win)
        assert.is_true(cfg.width >= 1 and cfg.height >= 1)
        assert.is_true(cfg.row >= 0 and cfg.col >= 0)
        assert.is_true(cfg.col + cfg.width + 2 <= vim.o.columns)
        assert.is_true(cfg.row + cfg.height + 2 <= vim.o.lines - vim.o.cmdheight)
        assert.is_not_nil(cfg.border)
        assert.is_not_nil(cfg.title)
      end
      assert.same(underlying, vim.fn.winlayout())
    end
  end)

  it("can hide and reopen both status panes without ending the workspace", function()
    local session = open()
    local root = session.panel.view
    local before = assert_workspace(session)
    local actions = require("codediff.ui.explorer.actions")
    actions.toggle_visibility(root)
    vim.wait(30)
    assert.equal(session, lifecycle.get_session(session.tabpage))
    assert.is_false(vim.api.nvim_win_is_valid(before[1]))
    assert.is_false(vim.api.nvim_win_is_valid(before[2]))
    actions.toggle_visibility(root)
    local after = assert_workspace(session)
    assert.equal(before[3], after[3])
    assert.equal(before[4], after[4])
    for _, pane in ipairs(root.panes) do
      assert.is_false(vim.wo[pane.winid].scrollbind)
      assert.equal("", vim.wo[pane.winid].statuscolumn)
    end
  end)

  it("keeps both diff windows across added, empty, deleted and welcome states", function()
    local session = open()
    local wins = assert_workspace(session)
    vim.o.hidden = false
    local edited
    for _, file in ipairs({
      { "new.txt", "??", "unstaged", "modified" },
      { "empty.txt", "??", "unstaged", "modified" },
      { "deleted.txt", "D", "unstaged", "original" },
      { "added.txt", "A", "staged", "modified" },
      { "tracked.txt", "M", "unstaged", "modified" },
    }) do
      select_file(session, unpack(file))
      assert.same(wins, assert_workspace(session))
      if file[1] == "new.txt" then
        edited = session.modified_bufnr
        vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "unsaved untracked content" })
      end
    end
    assert.is_true(vim.api.nvim_buf_is_loaded(edited))
    assert.same({ "unsaved untracked content" }, vim.api.nvim_buf_get_lines(edited, 0, -1, false))
    assert.is_true(vim.bo[edited].modified)
    user_buffers[#user_buffers + 1] = edited
    assert.is_true(view.show_welcome(session.tabpage))
    assert.same(wins, assert_workspace(session))
    assert.is_true(require("codediff.ui.welcome").is_welcome_buffer(session.modified_bufnr))
    assert.is_false(view.toggle_layout(session.tabpage))
    assert.same(wins, assert_workspace(session))
    lifecycle.cleanup_all()
    for _, win in ipairs(wins) do
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end
  end)

  it("uses a floating conflict result, respects cancellation and retains merge edits on pane close", function()
    repo.git({ "add", "-A" }, 0)
    repo.git({ "commit", "-m", "prepare conflict" }, 0)
    repo.git({ "checkout", "-b", "feature" }, 0)
    repo.write_file("tracked.txt", { "feature", "second" })
    repo.git({ "commit", "-am", "feature" }, 0)
    repo.git({ "checkout", "main" }, 0)
    repo.write_file("tracked.txt", { "main", "second" })
    repo.git({ "commit", "-am", "main" }, 0)
    repo.git({ "merge", "feature", "--no-edit" }, 1)
    local before_layout = vim.fn.winlayout()
    local session = open()
    assert.is_true(vim.wait(10000, function()
      return session.result_win and vim.api.nvim_win_is_valid(session.result_win)
        and session.result_bufnr and vim.bo[session.result_bufnr].buftype == ""
    end, 20))
    assert_workspace(session)
    assert.equal("editor", vim.api.nvim_win_get_config(session.result_win).relative)
    assert.same(before_layout, vim.fn.winlayout())
    vim.fn.confirm = function() return 2 end
    assert.is_false(lifecycle.close(session.tabpage))
    assert.equal(session, lifecycle.get_session(session.tabpage))
    local result = session.result_bufnr
    vim.api.nvim_buf_set_lines(result, 0, -1, false, { "unsaved merge resolution" })
    vim.api.nvim_win_close(session.result_win, true)
    assert.is_true(vim.wait(3000, function() return lifecycle.get_session(session.tabpage) == nil end, 10))
    assert.same(before_layout, vim.fn.winlayout())
    assert.is_true(vim.api.nvim_buf_is_loaded(result))
    assert.same({ "unsaved merge resolution" }, vim.api.nvim_buf_get_lines(result, 0, -1, false))
    assert.is_true(vim.bo[result].modified)
    vim.bo[result].modified = false
  end)
end)
