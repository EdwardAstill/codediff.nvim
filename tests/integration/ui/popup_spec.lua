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

local function assert_diff_numbers(session)
  for _, side in ipairs({ "original", "modified", "base", "result" }) do
    local win = session[side .. "_win"]
    if win then
      assert.is_true(vim.wo[win].number)
      assert.is_false(vim.wo[win].relativenumber)
    end
  end
  for _, pane in ipairs(session.panel.view.panes) do
    assert.is_false(vim.wo[pane.winid].number)
    assert.is_false(vim.wo[pane.winid].relativenumber)
  end
end

local function chrome_options()
  return { laststatus = vim.o.laststatus, cmdheight = vim.o.cmdheight, showmode = vim.o.showmode, ruler = vim.o.ruler }
end

describe("Status popup workspace", function()
  local repo, saved_cwd, saved_columns, saved_lines, saved_hidden, saved_confirm
  local user_buffers, user_tabs, saved_chrome, saved_number, saved_relativenumber

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
    saved_chrome = chrome_options()
    saved_number, saved_relativenumber = vim.wo.number, vim.wo.relativenumber
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
    user_buffers, user_tabs = {}, {}
  end)

  after_each(function()
    vim.fn.confirm = saved_confirm
    lifecycle.cleanup_all()
    for _, tab in ipairs(user_tabs) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.cmd(vim.api.nvim_tabpage_get_number(tab) .. "tabclose!")
      end
    end
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
    for name, value in pairs(saved_chrome) do
      vim.o[name] = value
    end
    vim.wo.number, vim.wo.relativenumber = saved_number, saved_relativenumber
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

  it("restores chrome on tab switches and closing a different popup leaves the current one hidden", function()
    vim.o.laststatus, vim.o.cmdheight, vim.o.showmode, vim.o.ruler = 3, 2, true, true
    local expected = chrome_options()
    local hidden = { laststatus = 0, cmdheight = 0, showmode = false, ruler = false }
    local first = open()
    assert.same(hidden, chrome_options())
    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    user_tabs[#user_tabs + 1] = second_tab
    assert.same(expected, chrome_options())
    local second = open()
    assert.same(hidden, chrome_options())
    vim.api.nvim_set_current_tabpage(first.tabpage)
    assert.same(hidden, chrome_options())
    assert.is_true(lifecycle.close(second.tabpage))
    assert.same(hidden, chrome_options())
    assert.is_true(lifecycle.close(first.tabpage))
    assert.same(expected, chrome_options())
  end)

  it("keeps absolute diff numbers without changing the underlying window preferences", function()
    local underlying = vim.api.nvim_get_current_win()
    vim.wo[underlying].number, vim.wo[underlying].relativenumber = false, true
    local session = open()
    assert_diff_numbers(session)
    for _, pane in ipairs(session.panel.view.panes) do
      assert.is_true(vim.api.nvim_win_get_width(pane.winid) + 2 <= 26)
      assert.is_true(vim.api.nvim_win_get_width(pane.winid) < 120 * 0.17)
      local footer = vim.api.nvim_win_get_config(pane.winid).footer
      assert.is_truthy(footer[1][1]:find(pane.group == "staged" and "s unstage" or "s stage", 1, true))
    end
    assert.is_false(vim.wo[underlying].number)
    assert.is_true(vim.wo[underlying].relativenumber)
    lifecycle.close(session.tabpage)
    assert.is_false(vim.wo[underlying].number)
    assert.is_true(vim.wo[underlying].relativenumber)
  end)

  it("closes an owned child dialog with the review", function()
    local session = open()
    local dialog = require("codediff.ui.dialog").open({ tabpage = session.tabpage }, { title = "Review", lines = { "Close with parent" } })
    assert.equal(dialog, session.popup.dialog)
    assert.is_true(lifecycle.close(session.tabpage))
    assert.is_nil(session.popup.dialog)
    assert.is_false(vim.api.nvim_win_is_valid(dialog.winid))
    assert.is_false(vim.api.nvim_buf_is_valid(dialog.bufnr))
  end)

  it("restores chrome even if a close hook fails", function()
    local expected = chrome_options()
    local session = open()
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffClose",
      once = true,
      callback = function() error("test close hook failure") end,
    })
    pcall(lifecycle.close, session.tabpage)
    assert.is_nil(lifecycle.get_session(session.tabpage))
    assert.same(expected, chrome_options())
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
      assert_diff_numbers(session)
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
      assert_diff_numbers(session)
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
    vim.o.cmdheight = 2
    require("codediff.config").options.explorer.width = 28
    local before_layout = vim.fn.winlayout()
    local session = open()
    assert.is_true(vim.wait(10000, function()
      return session.result_win and vim.api.nvim_win_is_valid(session.result_win)
        and session.result_bufnr and vim.bo[session.result_bufnr].buftype == ""
    end, 20))
    assert_workspace(session)
    assert.equal("editor", vim.api.nvim_win_get_config(session.result_win).relative)
    assert.equal("editor", vim.api.nvim_win_get_config(session.base_win).relative)
    local incoming = vim.api.nvim_win_get_position(session.original_win)
    local current = vim.api.nvim_win_get_position(session.modified_win)
    local base = vim.api.nvim_win_get_position(session.base_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    assert.equals(incoming[1], current[1])
    assert.equals(base[1], result_position[1])
    assert.equals(incoming[2], base[2])
    assert.equals(current[2], result_position[2])
    assert.is_true(base[1] > incoming[1])
    assert_diff_numbers(session)
    assert.equals(2, vim.o.cmdheight)
    assert.equals(28, vim.api.nvim_win_get_width(session.panel.view.panes[1].winid))
    require("codediff.ui.view.actions.hunk").refresh_selection(session.tabpage)
    for _, side in ipairs({ "original", "modified", "base", "result" }) do
      local win = session[side .. "_win"]
      local cfg = vim.api.nvim_win_get_config(win)
      assert.equals("", vim.wo[win].winbar)
      assert.is_not_nil(cfg.title)
      local footer = cfg.footer[1][1]
      assert.is_truthy(footer:find("g?", 1, true))
      assert.is_nil(footer:find("stage", 1, true))
      assert.is_nil(footer:find("revert", 1, true))
    end
    local result_view = require("codediff.ui.conflict.view.result")
    vim.api.nvim_set_current_win(session.result_win)
    result_view.toggle_maximize(session.tabpage)
    assert.is_not_nil(session.merge_maximized)
    assert.is_truthy(vim.wo[session.merge_maximized.win].winbar:find("Result", 1, true))
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.is_nil(session.merge_maximized)
    assert_diff_numbers(session)
    assert.same(before_layout, vim.fn.winlayout())
    vim.o.columns, vim.o.lines = 40, 12
    vim.api.nvim_exec_autocmds("VimResized", {})
    for _, side in ipairs({ "original", "modified", "base", "result" }) do
      local cfg = vim.api.nvim_win_get_config(session[side .. "_win"])
      assert.is_true(cfg.width > 0 and cfg.height > 0)
      assert.is_true(cfg.col + cfg.width <= vim.o.columns)
      assert.is_true(cfg.row + cfg.height <= vim.o.lines)
    end
    local result = session.result_bufnr
    vim.api.nvim_buf_set_lines(result, 0, -1, false, { "unsaved merge resolution" })
    vim.fn.confirm = function() return 2 end
    assert.is_false(lifecycle.close(session.tabpage))
    assert.equal(session, lifecycle.get_session(session.tabpage))
    vim.api.nvim_win_close(session.result_win, true)
    assert.is_true(vim.wait(3000, function() return lifecycle.get_session(session.tabpage) == nil end, 10))
    assert.same(before_layout, vim.fn.winlayout())
    assert.is_true(vim.api.nvim_buf_is_loaded(result))
    assert.same({ "unsaved merge resolution" }, vim.api.nvim_buf_get_lines(result, 0, -1, false))
    assert.is_true(vim.bo[result].modified)
    vim.bo[result].modified = false
  end)
end)
