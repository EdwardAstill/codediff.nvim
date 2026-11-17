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

  local function setup_popup_keymaps(session)
    session.popup = require("codediff.ui.popup").capture()
    require("codediff.ui.conflict").setup_keymaps(session.tabpage)
    session.popup = nil
  end

  it("accepts the focused popup source with Enter and undoes without changing that source", function()
    local session = open_merge_view()
    setup_popup_keymaps(session)
    local tracking = require("codediff.ui.conflict.tracking")
    for _, source in ipairs({ { session.original_win, "line 3 (feature)" }, { session.modified_win, "line 3 (main)" } }) do
      vim.api.nvim_set_current_win(source[1])
      vim.api.nvim_win_set_cursor(source[1], { 3, 0 })
      local bufnr = vim.api.nvim_get_current_buf()
      local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.api.nvim_feedkeys("\r", "xt", false)
      assert.same({ "line 1", "line 2", source[2], "line 4" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
      assert.equals(0, tracking.unresolved_count(session))
      vim.api.nvim_feedkeys("u", "xt", false)
      assert.same({ "line 1", "line 2", "line 3", "line 4" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
      assert.equals(1, tracking.unresolved_count(session))
      assert.same(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.equals(source[1], vim.api.nvim_get_current_win())
    end
  end)

  it("puts the focused source first with b and preserves Result word movement", function()
    local session = open_merge_view()
    setup_popup_keymaps(session)
    assert.equals("NONE", effective(session.result_bufnr, "b"))
    assert.equals("NONE", effective(session.result_bufnr, "B"))
    for _, win in ipairs({ session.original_win, session.modified_win }) do
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      assert.equals("NONE", effective(vim.api.nvim_win_get_buf(win), "B"))
      vim.api.nvim_feedkeys("b", "xt", false)
      local first = win == session.original_win and "line 3 (feature)" or "line 3 (main)"
      local second = win == session.original_win and "line 3 (main)" or "line 3 (feature)"
      assert.same({ "line 1", "line 2", first, second, "line 4" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
      vim.api.nvim_feedkeys("u", "xt", false)
      assert.equals(1, require("codediff.ui.conflict.tracking").unresolved_count(session))
    end
  end)

  it("approves manual Result edits only with normal-mode Enter", function()
    local session = open_merge_view()
    setup_popup_keymaps(session)
    local tracking = require("codediff.ui.conflict.tracking")
    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_win_set_cursor(session.result_win, { 3, 0 })
    vim.api.nvim_feedkeys("ccmanual result\27", "xt", false)
    assert.equals(1, tracking.unresolved_count(session))
    local insert_enter = vim.fn.maparg("<CR>", "i", false, true)
    assert.is_true(next(insert_enter) == nil or insert_enter.buffer ~= 1, "popup must not claim insert Enter")
    vim.api.nvim_feedkeys("\r", "xt", false)
    assert.same({ "line 1", "line 2", "manual result", "line 4" }, vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false))
    assert.equals(0, tracking.unresolved_count(session))
    vim.api.nvim_feedkeys("u", "xt", false)
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("restores popup shortcut ownership without claiming native Enter or Base Enter", function()
    local session = open_merge_view()
    local lifecycle = require("codediff.ui.lifecycle")
    assert.equals("NONE", effective(session.original_bufnr, "<CR>"))
    local calls = 0
    vim.keymap.set("n", "<CR>", function() calls = calls + 1 end, { buffer = session.original_bufnr, desc = "USER ENTER" })
    setup_popup_keymaps(session)
    assert.equals("NONE", effective(session.base_bufnr, "<CR>"))
    lifecycle.release_keymap_scope(session.tabpage, "conflict")
    assert.equals("USER ENTER [buf]", effective(session.original_bufnr, "<CR>"))
    assert.equals("NONE", effective(session.original_bufnr, "b"))
    assert.equals("NONE", effective(session.original_bufnr, "B"))
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_feedkeys("\r", "xt", false)
    assert.equals(1, calls)
  end)

  it("leaves do and dp to the user instead of claiming them", function()
    -- A mapping the user already had. codediff must not delete or shadow it.
    vim.keymap.set("n", "do", function() end, { desc = "USER MAPPING" })

    local session = open_merge_view()

    assert.equals("USER MAPPING [global]", effective(session.original_bufnr, "do"), "merge view must hand `do` back to the user's mapping")
    assert.equals("NONE", effective(session.original_bufnr, "dp"), "merge view must not claim `dp`")
  end)

  it("leaves the normal mark prefix available in editable Result", function()
    local session = open_merge_view()
    assert.is_false(require("codediff.ui.lifecycle").owns_keymap(session.tabpage, "m"))
    vim.api.nvim_set_current_win(session.result_win)
    vim.api.nvim_win_set_cursor(session.result_win, { 2, 0 })
    vim.cmd("normal ma")
    assert.equals(2, vim.api.nvim_buf_get_mark(session.result_bufnr, "a")[1])
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
