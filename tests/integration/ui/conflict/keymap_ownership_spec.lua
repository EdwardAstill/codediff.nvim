-- Which keys a merge view claims, and which it deliberately leaves alone.
--
-- In a merge grid codediff does NOT bind do/dp. The conflict mappings
-- (2do/3do, ]x, <leader>c*) replace them, and not claiming do/dp hands those
-- keys back to whatever the user had mapped for the duration of the merge,
-- rather than deleting the user's mapping.
--
-- That behaviour is load-bearing and had no coverage. It is also easy to break
-- from a distance: setup_all_keymaps decides via `is_conflict`, and any change
-- to how a session reports "I am a merge view" lands here first.

local h = require("tests.support")
local path = require("codediff.core.path")

--- What `key` actually resolves to in `bufnr`, and whether it is buffer-local.
local function effective(bufnr, key)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "<invalid buffer>"
  end
  local m = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  if type(m) ~= "table" or next(m) == nil then
    return "NONE"
  end
  return (m.desc or "<set>") .. (m.buffer == 1 and " [buf]" or " [global]")
end

describe("merge view keymap ownership", function()
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    pcall(vim.keymap.del, "n", "do")
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  --- Leave the repo mid-merge with a conflicted file.txt, then open the
  --- merge grid the way :CodeDiff merge does.
  local function open_merge_view()
    repo.write_file("file.txt", { "line 1", "line 2", "line 3", "line 4" })
    repo.git("add file.txt")
    repo.git("commit -m c0")

    repo.git("checkout -b feature")
    repo.write_file("file.txt", { "line 1", "line 2", "line 3 (feature)", "line 4" })
    repo.git("commit -am feature")

    repo.git("checkout main")
    repo.write_file("file.txt", { "line 1", "line 2", "line 3 (main)", "line 4" })
    repo.git("commit -am main")

    local merge_out = repo.git("merge feature --no-edit")
    assert.is_true(merge_out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")

    vim.cmd("edit " .. repo.dir .. "/file.txt")
    local ready, tabpage = false, nil
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
    assert.is_true(vim.wait(10000, function()
      local s = tabpage and lifecycle.get_session(tabpage)
      return ready and s ~= nil and s.result_bufnr ~= nil
    end, 50), "merge view never produced a result pane")
    return lifecycle.get_session(tabpage)
  end

  it("leaves do and dp to the user instead of claiming them", function()
    -- A mapping the user already had. codediff must not delete or shadow it.
    vim.keymap.set("n", "do", function() end, { desc = "USER MAPPING" })

    local session = open_merge_view()

    assert.equals("USER MAPPING [global]", effective(session.original_bufnr, "do"), "merge view must hand `do` back to the user's mapping")
    assert.equals("NONE", effective(session.original_bufnr, "dp"), "merge view must not claim `dp`")
  end)

  it("gets changes again in an ordinary diff", function()
    -- The counterpart: outside a merge, do/dp are codediff's. Without this a
    -- change that simply never binds them would pass the assertions above.
    local left = h.get_temp_path("merge_kmap_left.txt")
    local right = h.get_temp_path("merge_kmap_right.txt")
    vim.fn.writefile({ "a", "b" }, left)
    vim.fn.writefile({ "a", "B" }, right)

    require("codediff.ui.view").create({
      original = path.make_ref(left, nil),
      modified = path.make_ref(right, nil),
    })

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    assert.is_true(
      vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s ~= nil and s.stored_diff_result ~= nil
      end, 50),
      "plain diff never became ready"
    )

    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { 2, 0 })
    vim.api.nvim_feedkeys("do", "xt", false)
    assert.same({ "a", "B" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))

    vim.fn.delete(left)
    vim.fn.delete(right)
  end)

  it("stops treating the session as a merge after switching to a normal file", function()
    -- view.update can retarget a session from a conflicted file to an ordinary
    -- one. The merge flag has to follow, or do/dp stay unclaimed forever.
    repo.write_file("plain.txt", { "p1", "p2" })
    repo.git("add plain.txt")
    repo.git("commit -m plain")

    local session = open_merge_view()
    local tabpage = vim.api.nvim_get_current_tabpage()
    repo.write_file("plain.txt", { "p1", "edited" })
    assert.is_true(session.merge, "merge view should be flagged as a merge")

    -- Retarget the same tab at an ordinary file, the way selecting another
    -- entry in the explorer does.
    require("codediff.ui.view").update(tabpage, {
      git_root = repo.dir,
      original = path.make_ref("plain.txt", repo.dir),
      modified = path.make_ref("plain.txt", repo.dir),
      original_revision = "HEAD",
    }, false)

    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(
      vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s ~= nil and s.modified.relative == "plain.txt" and s.stored_diff_result ~= nil
      end, 50),
      "retargeted diff never became ready"
    )

    local after = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(after.modified_win)
    vim.api.nvim_win_set_cursor(after.modified_win, { 2, 0 })
    vim.api.nvim_feedkeys("do", "xt", false)
    assert.same({ "p1", "p2" }, vim.api.nvim_buf_get_lines(after.modified_bufnr, 0, -1, false))
  end)

  it("undoes and redoes Result while each immutable source pane has focus", function()
    local session = open_merge_view()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local conflict = require("codediff.ui.conflict")
    local tracking = require("codediff.ui.conflict.tracking")
    for _, win in ipairs({ session.original_win, session.modified_win, session.base_win }) do
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      local source = vim.api.nvim_win_get_buf(win)
      local before = vim.api.nvim_buf_get_lines(source, 0, -1, false)
      assert.is_true(conflict.accept_current(tabpage))
      assert.equals("line 3 (main)", vim.api.nvim_buf_get_lines(session.result_bufnr, 2, 3, false)[1])
      vim.api.nvim_feedkeys("u", "xt", false)
      assert.equals("line 3", vim.api.nvim_buf_get_lines(session.result_bufnr, 2, 3, false)[1])
      assert.equals(1, tracking.unresolved_count(session))
      vim.api.nvim_feedkeys("\18", "xt", false)
      assert.equals("line 3 (main)", vim.api.nvim_buf_get_lines(session.result_bufnr, 2, 3, false)[1])
      assert.equals(0, tracking.unresolved_count(session))
      assert.same(before, vim.api.nvim_buf_get_lines(source, 0, -1, false))
      assert.equals(win, vim.api.nvim_get_current_win())
      assert.is_true(conflict.discard(tabpage))
    end
  end)

  it("restores source undo mappings and leaves Result undo mappings owned by the user", function()
    local session = open_merge_view()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.release_keymap_scope(tabpage, "conflict")
    local source_calls, result_calls = 0, 0
    vim.keymap.set("n", "u", function() source_calls = source_calls + 1 end, { buffer = session.original_bufnr })
    vim.keymap.set("n", "u", function() result_calls = result_calls + 1 end, { buffer = session.result_bufnr })
    require("codediff.ui.conflict").setup_keymaps(tabpage)
    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_feedkeys("u", "xt", false)
    assert.equals(1, result_calls)
    lifecycle.release_keymap_scope(tabpage, "conflict")
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_feedkeys("u", "xt", false)
    assert.equals(1, source_calls)
  end)
end)
