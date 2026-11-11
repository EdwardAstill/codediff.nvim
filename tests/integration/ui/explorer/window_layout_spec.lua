-- The explorer stays left of both diff panes without inheriting editor gutters.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("Explorer window layout", function()
  local repo
  local original_statuscolumn

  before_each(function()
    original_statuscolumn = vim.o.statuscolumn
    vim.o.statuscolumn = "%s%=%l %C "
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("file1.txt", { "line 1", "line 2" })
    repo.write_file("file2.txt", { "hello" })
    repo.git("add .")
    repo.git("commit -m initial")
    repo.write_file("file1.txt", { "line 1", "line 2 modified" })
    repo.write_file("file2.txt", { "hello world" })
    vim.cmd("edit " .. repo.path("file1.txt"))
  end)

  after_each(function()
    vim.o.statuscolumn = original_statuscolumn
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("keeps both status panes left of the diff without inherited gutters", function()
    vim.cmd("CodeDiff")
    assert.is_true(h.wait_for_explorer(5000), "explorer window should appear")
    assert.is_true(h.wait_for_diff_ready(5000), "diff session should register")

    local session = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
    local explorer = session.panel.view
    assert.equal(2, #explorer.panes)
    local before_col = vim.api.nvim_win_get_position(session.original_win)[2]
    local after_col = vim.api.nvim_win_get_position(session.modified_win)[2]
    assert.is_true(after_col > before_col)
    for _, pane in ipairs(explorer.panes) do
      assert.equal("", vim.wo[pane.winid].statuscolumn,
        "explorer should not inherit the user's status column")
      assert.equal(0, vim.fn.getwininfo(pane.winid)[1].textoff,
        "explorer rows should use the full window width")
      assert.is_true(vim.api.nvim_win_get_position(pane.winid)[2] < before_col)
    end
    local top = vim.api.nvim_win_get_position(explorer.panes[1].winid)
    local bottom = vim.api.nvim_win_get_position(explorer.panes[2].winid)
    assert.equal(top[2], bottom[2])
    assert.is_true(bottom[1] > top[1])
  end)
end)
