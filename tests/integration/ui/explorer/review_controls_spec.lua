local h = require("tests.support")
local lifecycle = require("codediff.ui.lifecycle")
local hunks = require("codediff.ui.view.actions.hunk")
h.ensure_plugin_loaded()

local function eventually(predicate)
  assert.is_true(vim.wait(10000, predicate, 25), "review should settle")
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function bytes(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

local function write_bytes(path, content)
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path, "b")
end

describe("Popup review controls", function()
  local repo, cwd, save_map

  before_each(function()
    lifecycle.cleanup_all()
    cwd = vim.fn.getcwd()
    save_map = vim.fn.maparg("s", "n", false, true)
    require("codediff").setup({ explorer = { auto_open_on_cursor = false, flatten_dirs = false } })
    repo = h.create_temp_git_repo()
    vim.keymap.set("n", "s", "<Cmd>write<CR>")
  end)

  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
    vim.fn.chdir(cwd)
    vim.keymap.del("n", "s")
    if next(save_map) then vim.fn.mapset("n", false, save_map) end
    repo.cleanup()
  end)

  local function open(filename)
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path(filename)))
    require("codediff.commands").vscode_diff({ fargs = {} })
    local session
    eventually(function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.popup and session.panel and session.panel.view.panes and session.stored_diff_result
    end)
    return session, session.panel.view
  end

  local function select_file(session, pane, path)
    for line = 1, vim.api.nvim_buf_line_count(pane.bufnr) do
      local node = pane.tree:get_node(line)
      if node and node.data.path == path then
        vim.api.nvim_set_current_win(pane.winid)
        vim.api.nvim_win_set_cursor(pane.winid, { line, 0 })
        press("<CR>")
        eventually(function()
          return session.panel.view.data.current_file_path == path
            and session.modified_revision == (pane.group == "staged" and ":0" or nil)
            and session.stored_diff_result and #session.stored_diff_result.changes > 0
        end)
        return
      end
    end
    error("No tree entry for " .. path)
  end

  local function focus(session, line, original)
    local win = original and session.original_win or session.modified_win
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { line or 1, 0 })
    hunks.refresh_selection(session.tabpage)
  end

  local function fixture()
    local base = {}
    for i = 1, 30 do base[i] = "line " .. i end
    repo.write_file("file.txt", base)
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    local indexed = vim.deepcopy(base)
    indexed[1] = "staged first line"
    repo.write_file("file.txt", indexed)
    repo.git({ "add", "." }, 0)
    local working = vim.deepcopy(indexed)
    working[10], working[25] = "reject this", "keep this"
    repo.write_file("file.txt", working)
    return indexed, working
  end

  local function confirm(session, key)
    assert.is_not_nil(session.popup.dialog, "rejection must require explicit confirmation")
    vim.api.nvim_set_current_win(session.popup.dialog.winid)
    press(key)
  end

  it("stages from both trees instead of invoking global save, and restores displaced editing keys", function()
    fixture()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("file.txt")))
    local buf = vim.api.nvim_get_current_buf()
    local saves = 0
    vim.keymap.set("n", "s", function() saves = saves + 1 end, { buffer = buf })
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    vim.v.errmsg = ""
    press("s")
    eventually(function() return repo.git({ "diff", "--", "file.txt" }) == "" end)
    assert.equals(0, saves)
    assert.is_nil(vim.v.errmsg:find("E382", 1, true))
    select_file(session, root.panes[2], "file.txt")
    press("s")
    eventually(function() return repo.git({ "diff", "--cached", "--", "file.txt" }) == "" end)
    lifecycle.close(session.tabpage)
    vim.api.nvim_set_current_buf(buf)
    press("s")
    assert.equals(1, saves)
    vim.keymap.del("n", "s", { buffer = buf })
  end)

  it("marks the selected hunk in both panes, follows navigation, and clears on trees and close", function()
    fixture()
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    focus(session, 10)
    local ns = session.review_selection.ns
    local original, modified = session.original_bufnr, session.modified_bufnr
    assert.is_true(#vim.api.nvim_buf_get_extmarks(original, ns, 0, -1, {}) > 0)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(modified, ns, 0, -1, {}) > 0)
    assert.is_truthy(vim.inspect(vim.api.nvim_win_get_config(session.modified_win).footer):find("Hunk 1/2", 1, true))
    press("]")
    assert.equals(25, vim.api.nvim_win_get_cursor(session.modified_win)[1])
    assert.is_truthy(vim.inspect(vim.api.nvim_win_get_config(session.original_win).footer):find("Hunk 2/2", 1, true))
    vim.api.nvim_set_current_win(root.winid)
    assert.same({}, vim.api.nvim_buf_get_extmarks(modified, ns, 0, -1, {}))
    focus(session, 10)
    lifecycle.close(session.tabpage)
    assert.same({}, vim.api.nvim_buf_get_extmarks(modified, ns, 0, -1, {}))
  end)

  it("cancels rejection without changing disk, index, or buffer", function()
    local indexed, working = fixture()
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    focus(session, 10)
    press("r")
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
      local rows = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, session.review_selection.ns, 0, -1, {})) do
        rows[#rows + 1] = mark[2]
      end
      assert.same({ 9 }, rows, "confirmation must keep the target hunk visibly selected")
    end
    confirm(session, "n")
    assert.equals(table.concat(working, "\n") .. "\n", bytes(repo.path("file.txt")))
    assert.equals(table.concat(indexed, "\n") .. "\n", repo.git({ "show", ":file.txt" }))
    assert.same(working, vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false))
    assert.is_false(vim.bo[session.modified_bufnr].modified)
  end)

  it("rejects only the selected unstaged hunk and keeps staged content", function()
    local indexed, working = fixture()
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    focus(session, 10, true)
    press("r")
    confirm(session, "y")
    working[10] = indexed[10]
    assert.equals(table.concat(working, "\n") .. "\n", bytes(repo.path("file.txt")))
    assert.equals(table.concat(indexed, "\n") .. "\n", repo.git({ "show", ":file.txt" }))
    eventually(function() return #session.stored_diff_result.changes == 1 end)
    assert.same(working, vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false))
  end)

  it("refuses unsaved target text without writing any of it", function()
    local indexed, working = fixture()
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    focus(session, 10)
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 19, 20, false, { "unsaved text" })
    press("r")
    assert.is_nil(session.popup.dialog)
    assert.is_true(vim.bo[session.modified_bufnr].modified)
    assert.equals("unsaved text", vim.api.nvim_buf_get_lines(session.modified_bufnr, 19, 20, false)[1])
    assert.equals(table.concat(working, "\n") .. "\n", bytes(repo.path("file.txt")))
    assert.equals(table.concat(indexed, "\n") .. "\n", repo.git({ "show", ":file.txt" }))
    vim.bo[session.modified_bufnr].modified = false
  end)

  for _, target in ipairs({ "worktree", "index", "buffer" }) do
    it("rejects stale confirmation after " .. target .. " changes", function()
      local indexed, working = fixture()
      local session, root = open("file.txt")
      select_file(session, root.panes[1], "file.txt")
      focus(session, 10)
      press("r")
      if target == "worktree" then
        working[10] = "external change"
        repo.write_file("file.txt", working)
      elseif target == "index" then
        repo.git({ "add", "file.txt" }, 0)
        indexed = working
      else
        vim.api.nvim_buf_set_lines(session.modified_bufnr, 9, 10, false, { "unsaved during confirmation" })
      end
      confirm(session, "y")
      assert.equals(table.concat(working, "\n") .. "\n", bytes(repo.path("file.txt")))
      assert.equals(table.concat(indexed, "\n") .. "\n", repo.git({ "show", ":file.txt" }))
      if target == "buffer" then
        assert.equals("unsaved during confirmation", vim.api.nvim_buf_get_lines(session.modified_bufnr, 9, 10, false)[1])
        vim.bo[session.modified_bufnr].modified = false
      end
    end)
  end

  it("requires unstaging before rejection", function()
    local indexed, working = fixture()
    local session, root = open("file.txt")
    select_file(session, root.panes[2], "file.txt")
    focus(session, 1)
    press("r")
    assert.is_nil(session.popup.dialog)
    assert.equals(table.concat(working, "\n") .. "\n", bytes(repo.path("file.txt")))
    assert.equals(table.concat(indexed, "\n") .. "\n", repo.git({ "show", ":file.txt" }))
  end)

  for _, deleted in ipairs({ false, true }) do
    it("safely rejects a one-sided " .. (deleted and "deletion" or "addition"), function()
      repo.write_file("anchor.txt", { "anchor" })
      local content = "first\r\nsecond without final newline"
      if deleted then write_bytes(repo.path("boundary.txt"), content) end
      repo.git({ "add", "." }, 0)
      repo.git({ "commit", "-m", "initial" }, 0)
      if deleted then vim.fn.delete(repo.path("boundary.txt")) else write_bytes(repo.path("boundary.txt"), content) end
      local session, root = open("anchor.txt")
      select_file(session, root.panes[1], "boundary.txt")
      focus(session, 1, deleted)
      local index_before = repo.git({ "ls-files", "--stage" })
      press("r")
      confirm(session, "y")
      assert.equals(index_before, repo.git({ "ls-files", "--stage" }))
      if deleted then
        assert.equals(content, bytes(repo.path("boundary.txt")))
      else
        assert.equals(0, vim.fn.filereadable(repo.path("boundary.txt")))
      end
    end)
  end

  it("preserves CRLF and missing final newline when rejecting one of multiple hunks", function()
    local base = {}
    for i = 1, 30 do base[i] = "line " .. i end
    write_bytes(repo.path("file.txt"), table.concat(base, "\r\n"))
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    local working = vim.deepcopy(base)
    working[10], working[25] = "reject this", "keep this"
    write_bytes(repo.path("file.txt"), table.concat(working, "\r\n"))
    local session, root = open("file.txt")
    select_file(session, root.panes[1], "file.txt")
    focus(session, 10)
    press("r")
    confirm(session, "y")
    working[10] = base[10]
    assert.equals(table.concat(working, "\r\n"), bytes(repo.path("file.txt")))
    assert.equals("dos", vim.bo[session.modified_bufnr].fileformat)
    assert.is_false(vim.bo[session.modified_bufnr].endofline)
  end)

  it("shows standalone review help and closes it with h", function()
    require("codediff.ui.keymap_help").toggle(vim.api.nvim_get_current_tabpage())
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("Reject unstaged hunk", 1, true))
    assert.is_truthy(text:find("unsaved", 1, true))
    press("h")
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("keeps spatial tree movement and automatic previews with independent folder controls", function()
    require("codediff").setup({ explorer = { auto_open_on_cursor = true, flatten_dirs = false } })
    repo.write_file("src/a.txt", { "a" })
    repo.write_file("src/b.txt", { "b" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("src/a.txt", { "changed a" })
    repo.write_file("src/b.txt", { "changed b" })
    local session, root = open("src/a.txt")
    select_file(session, root, "src/a.txt")
    press("k")
    eventually(function() return root.data.current_file_path == "src/b.txt" end)
    press("i")
    eventually(function() return root.data.current_file_path == "src/a.txt" end)
    for line = 1, vim.api.nvim_buf_line_count(root.bufnr) do
      local node = root.tree:get_node(line)
      if node and node.data.dir_path == "src" then
        vim.api.nvim_win_set_cursor(root.winid, { line, 0 })
        press("j")
        assert.is_false(node:is_expanded())
        press("l")
        assert.is_true(node:is_expanded())
        return
      end
    end
    error("Expected src folder")
  end)
end)
