local h = require("tests.support")
local path = require("codediff.core.path")

describe("conflict editor layout", function()
  local repo
  local saved_layout
  local saved_original_position

  before_each(function()
    h.ensure_plugin_loaded()
    local config = require("codediff.config")
    saved_layout = config.options.diff.layout
    saved_original_position = config.options.diff.original_position
    config.options.diff.layout = "side-by-side"

    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "base" })
    repo.git("add file.txt")
    repo.git("commit -m base")
    repo.git("checkout -b feature")
    repo.write_file("file.txt", { "feature" })
    repo.git("commit -am feature")
    repo.git("checkout main")
    repo.write_file("file.txt", { "main" })
    repo.git("commit -am main")
    local merge_output = repo.git("merge feature --no-edit")
    assert.is_true(merge_output:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
  end)

  after_each(function()
    local config = require("codediff.config")
    config.options.diff.layout = saved_layout
    config.options.diff.original_position = saved_original_position
    require("codediff.ui.lifecycle").cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
    end
  end)

  it("fixes the four semantic roles regardless of ordinary diff positioning", function()
    require("codediff.config").options.diff.original_position = "right"
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("file.txt")))

    local ready = false
    local tabpage
    require("codediff.ui.view").create({
      git_root = repo.dir,
      original = path.make_ref("file.txt", repo.dir),
      modified = path.make_ref("file.txt", repo.dir),
      original_revision = ":3",
      modified_revision = ":2",
      conflict = true,
    }, nil, function()
      tabpage = vim.api.nvim_get_current_tabpage()
      ready = true
    end)

    local lifecycle = require("codediff.ui.lifecycle")
    local session
    assert.is_true(
      vim.wait(15000, function()
        session = lifecycle.get_session(tabpage)
        return ready
          and session
          and session.original_win
          and session.modified_win
          and session.result_win
          and session.base_win
          and vim.api.nvim_win_is_valid(session.original_win)
          and vim.api.nvim_win_is_valid(session.modified_win)
          and vim.api.nvim_win_is_valid(session.result_win)
          and vim.api.nvim_win_is_valid(session.base_win)
      end, 50),
      "four-pane merge editor never became ready"
    )

    local original_position = vim.api.nvim_win_get_position(session.original_win)
    local modified_position = vim.api.nvim_win_get_position(session.modified_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    local base_position = vim.api.nvim_win_get_position(session.base_win)
    assert.equals(original_position[1], modified_position[1])
    assert.equals(base_position[1], result_position[1])
    assert.equals(original_position[2], base_position[2])
    assert.equals(modified_position[2], result_position[2])
    assert.is_true(original_position[2] < modified_position[2])
    assert.is_true(original_position[1] < base_position[1])
    assert.same({ "base" }, vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false))
    for _, side in ipairs({ "original", "modified", "base" }) do
      assert.is_false(vim.bo[session[side .. "_bufnr"]].modifiable)
      assert.is_true(vim.bo[session[side .. "_bufnr"]].readonly)
    end
    assert.is_true(vim.bo[session.result_bufnr].modifiable)
    local result_view = require("codediff.ui.conflict.view.result")
    vim.api.nvim_set_current_win(session.base_win)
    result_view.toggle_maximize(tabpage)
    assert.is_not_nil(session.merge_maximized)
    assert.equals(session.base_bufnr, vim.api.nvim_get_current_buf())
    result_view.toggle_maximize(tabpage)
    assert.is_nil(session.merge_maximized)
    assert.equals(session.base_win, vim.api.nvim_get_current_win())
    result_view.toggle_scroll_sync(tabpage)
    assert.is_false(session.merge_scroll_sync)
    local cursor = vim.api.nvim_win_get_cursor(0)
    result_view.toggle_scroll_sync(tabpage)
    assert.is_true(session.merge_scroll_sync)
    assert.same(cursor, vim.api.nvim_win_get_cursor(0))
  end)
end)
