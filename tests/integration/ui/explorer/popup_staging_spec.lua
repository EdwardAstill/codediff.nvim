local h = require("tests.support")
local lifecycle = require("codediff.ui.lifecycle")
local actions = require("codediff.ui.explorer.actions")
local tree = require("codediff.ui.explorer.tree")
h.ensure_plugin_loaded()

describe("Popup staging trees", function()
  local repo

  before_each(function()
    require("codediff").setup({ explorer = { flatten_dirs = false, auto_open_on_cursor = false } })
    lifecycle.cleanup_all()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
    repo.cleanup()
  end)

  local function eventually(predicate)
    assert.is_true(vim.wait(10000, predicate, 25), "repository and popup should settle")
  end

  local function open(filename)
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path(filename)))
    require("codediff.commands").vscode_diff({ fargs = {} })
    local session
    eventually(function()
      session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.panel and session.panel.view and session.panel.view.panes and session.stored_diff_result
    end)
    return session, session.panel.view
  end

  local function invoke(win, description)
    vim.api.nvim_set_current_win(win)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), "n")) do
      if mapping.desc == description then
        assert.is_function(mapping.callback)
        mapping.callback()
        return
      end
    end
    error("Missing action: " .. description)
  end

  local function node_at(pane, pathname, kind)
    for line = 1, vim.api.nvim_buf_line_count(pane.bufnr) do
      local node = pane.tree:get_node(line)
      if node and node.data.type == kind and (node.data.dir_path or node.data.path) == pathname then
        return node, line
      end
    end
  end

  local function cursor(pane, pathname, kind)
    local node, line = node_at(pane, pathname, kind)
    assert.is_not_nil(node, pathname .. " should be selectable in " .. pane.group)
    vim.api.nvim_set_current_win(pane.winid)
    vim.api.nvim_win_set_cursor(pane.winid, { line, 0 })
    return node
  end

  local function preview(session, pane, pathname, before, after)
    cursor(pane, pathname)
    invoke(pane.winid, "Select/toggle entry")
    eventually(function()
      local original, modified = lifecycle.get_buffers(session.tabpage or vim.api.nvim_get_current_tabpage())
      return original and modified
        and session.modified_revision == (pane.group == "staged" and ":0" or nil)
        and h.get_buffer_content(original) == before and h.get_buffer_content(modified) == after
    end)
  end

  it("keeps partial staging in both trees and stages/unstages only the selected hunk", function()
    local original = {}
    for i = 1, 25 do original[i] = "line " .. i end
    repo.write_file("src/mixed.txt", original)
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    local indexed = vim.deepcopy(original)
    indexed[1] = "already staged"
    repo.write_file("src/mixed.txt", indexed)
    repo.git({ "add", "." }, 0)
    local working = vim.deepcopy(indexed)
    working[10], working[23] = "accept this hunk", "leave this unstaged"
    repo.write_file("src/mixed.txt", working)

    local session, root = open("src/mixed.txt")
    local top, bottom = root.panes[1], root.panes[2]
    for _, pane in ipairs(root.panes) do
      local files = tree.get_all_files(pane.tree)
      assert.equals(1, #files)
      assert.equals(pane.group, files[1].data.group)
    end
    preview(session, top, "src/mixed.txt", table.concat(indexed, "\n"), table.concat(working, "\n"))
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 10, 0 })
    invoke(session.modified_win, "Stage hunk under cursor")
    indexed[10] = working[10]
    eventually(function() return repo.git({ "show", ":src/mixed.txt" }) == table.concat(indexed, "\n") .. "\n" end)
    eventually(function() return node_at(top, "src/mixed.txt") and node_at(bottom, "src/mixed.txt") end)
    assert.same(working, vim.fn.readfile(repo.path("src/mixed.txt")))

    preview(session, bottom, "src/mixed.txt", table.concat(original, "\n"), table.concat(indexed, "\n"))
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 10, 0 })
    invoke(session.modified_win, "Unstage hunk under cursor")
    indexed[10] = original[10]
    eventually(function() return repo.git({ "show", ":src/mixed.txt" }) == table.concat(indexed, "\n") .. "\n" end)
    assert.same(working, vim.fn.readfile(repo.path("src/mixed.txt")))
    eventually(function() return root.data == bottom.data and node_at(top, "src/mixed.txt") and node_at(bottom, "src/mixed.txt") end)

    preview(session, top, "src/mixed.txt", table.concat(indexed, "\n"), table.concat(working, "\n"))
    cursor(bottom, "src", "directory"):collapse()
    bottom.tree:render()
    vim.api.nvim_set_current_win(top.winid)
    actions.toggle_staged_view(root)
    assert.equals(bottom.winid, vim.api.nvim_get_current_win())
    assert.equals("staged", root.data.current_file_group)
    actions.navigate_prev(root)
    assert.equals("unstaged", root.data.current_file_group)
    assert.equals(top.winid, vim.api.nvim_get_current_win())
  end)

  it("stages collapsed literal folders including nested renames and deletes without touching siblings", function()
    for _, name in ipairs({ "[box]/edit.txt", "[box]/delete.txt", "[box]/old.txt", "b/outside.txt", "kept.txt" }) do
      repo.write_file(name, { "original " .. name })
    end
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("[box]/edit.txt", { "inside" })
    vim.fn.delete(repo.path("[box]/delete.txt"))
    vim.fn.mkdir(repo.path("[box]/nested"), "p")
    repo.git({ "mv", "--", "[box]/old.txt", "[box]/nested/new.txt" }, 0)
    repo.git({ "reset" }, 0)
    repo.write_file("b/outside.txt", { "outside unstaged" })
    repo.write_file("kept.txt", { "outside staged" })
    repo.git({ "add", "kept.txt" }, 0)
    local _, root = open("[box]/edit.txt")
    local top, bottom = root.panes[1], root.panes[2]
    local folder = cursor(top, "[box]", "directory")
    folder:collapse()
    top.tree:render()
    invoke(top.winid, "Toggle stage/unstage")
    eventually(function()
      return repo.git({ "show", ":[box]/edit.txt" }) == "inside\n" and node_at(bottom, "[box]", "directory") ~= nil
    end)
    assert.equals("", repo.git({ "--literal-pathspecs", "ls-files", "--", "[box]/delete.txt" }))
    assert.equals("", repo.git({ "--literal-pathspecs", "ls-files", "--", "[box]/old.txt" }))
    assert.equals("original [box]/old.txt\n", repo.git({ "show", ":[box]/nested/new.txt" }))
    assert.equals("original b/outside.txt\n", repo.git({ "show", ":b/outside.txt" }))
    assert.equals("outside staged\n", repo.git({ "show", ":kept.txt" }))

    cursor(bottom, "[box]", "directory"):collapse()
    bottom.tree:render()
    invoke(bottom.winid, "Toggle stage/unstage")
    eventually(function()
      return repo.git({ "show", ":[box]/edit.txt" }) == "original [box]/edit.txt\n"
        and node_at(top, "[box]", "directory") ~= nil and not node_at(bottom, "[box]", "directory")
    end)
    assert.equals("original [box]/delete.txt\n", repo.git({ "show", ":[box]/delete.txt" }))
    assert.equals("original [box]/old.txt\n", repo.git({ "show", ":[box]/old.txt" }))
    assert.equals("outside staged\n", repo.git({ "show", ":kept.txt" }))
    assert.equals("outside unstaged", vim.fn.readfile(repo.path("b/outside.txt"))[1])
  end)

  it("cycles all four floats in both directions without changing the underlying window", function()
    repo.write_file("file.txt", { "before" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("file.txt", { "after" })
    local underlying = vim.api.nvim_get_current_win()
    local session, root = open("file.txt")
    local windows = { root.winid, root.panes[2].winid, session.original_win, session.modified_win }
    for index, win in ipairs(windows) do
      invoke(win, "Focus next CodeDiff pane")
      assert.equals(windows[index % 4 + 1], vim.api.nvim_get_current_win())
      invoke(vim.api.nvim_get_current_win(), "Focus previous CodeDiff pane")
      assert.equals(win, vim.api.nvim_get_current_win())
    end
    assert.is_true(vim.api.nvim_win_is_valid(underlying))
    actions.toggle_visibility(root)
    assert.is_nil(root.winid)
    assert.is_nil(root.panes[2].winid)
    actions.toggle_visibility(root)
    assert.is_true(vim.api.nvim_win_is_valid(root.winid))
    assert.is_true(vim.api.nvim_win_is_valid(root.panes[2].winid))
  end)

  it("unstages both ends of an exact renamed file", function()
    repo.write_file("old.txt", { "content" })
    repo.write_file("outside.txt", { "outside" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.git({ "mv", "old.txt", "new.txt" }, 0)
    repo.write_file("new.txt", { "content", "x" })
    repo.write_file("outside.txt", { "staged outside" })
    repo.git({ "add", "outside.txt" }, 0)
    local _, root = open("new.txt")
    cursor(root, "new.txt")
    invoke(root.winid, "Toggle stage/unstage")
    eventually(function() return repo.git({ "show", ":new.txt" }) == "content\nx\n" and not node_at(root, "new.txt") end)
    local bottom = root.panes[2]
    cursor(bottom, "new.txt")
    invoke(bottom.winid, "Toggle stage/unstage")
    eventually(function() return repo.git({ "show", ":old.txt" }) == "content\n" end)
    assert.equals("", repo.git({ "ls-files", "--", "new.txt" }))
    assert.equals("staged outside\n", repo.git({ "show", ":outside.txt" }))
    assert.same({ "content", "x" }, vim.fn.readfile(repo.path("new.txt")))
  end)

  for _, deleted in ipairs({ false, true }) do
    it("stages and unstages a " .. (deleted and "deleted" or "new") .. " file hunk with both diff panes visible", function()
      repo.write_file("anchor.txt", { "unchanged" })
      if deleted then
        repo.write_file("boundary.txt", { "boundary content" })
      end
      repo.git({ "add", "." }, 0)
      repo.git({ "commit", "-m", "initial" }, 0)
      if deleted then
        vim.fn.delete(repo.path("boundary.txt"))
      else
        repo.write_file("boundary.txt", { "boundary content" })
      end
      local session, root = open("anchor.txt")
      local before, after = deleted and "boundary content" or "", deleted and "" or "boundary content"
      preview(session, root, "boundary.txt", before, after)
      assert.is_true(vim.api.nvim_win_is_valid(session.original_win))
      assert.is_true(vim.api.nvim_win_is_valid(session.modified_win))
      local win = deleted and session.original_win or session.modified_win
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      invoke(win, "Stage hunk under cursor")
      eventually(function()
        local indexed = repo.git({ "ls-files", "--", "boundary.txt" }) ~= ""
        return indexed ~= deleted and node_at(root.panes[2], "boundary.txt") ~= nil
      end)
      if not deleted then
        assert.equals("boundary content\n", repo.git({ "show", ":boundary.txt" }))
      end
      preview(session, root.panes[2], "boundary.txt", before, after)
      win = deleted and session.original_win or session.modified_win
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      invoke(win, "Unstage hunk under cursor")
      eventually(function()
        local indexed = repo.git({ "ls-files", "--", "boundary.txt" }) ~= ""
        return indexed == deleted and node_at(root, "boundary.txt") ~= nil
      end)
      if deleted then
        assert.equals("boundary content\n", repo.git({ "show", ":boundary.txt" }))
        assert.equals(0, vim.fn.filereadable(repo.path("boundary.txt")))
      else
        assert.equals("boundary content", vim.fn.readfile(repo.path("boundary.txt"))[1])
      end
    end)
  end

  it("preserves independent directory folds and selections when both trees refresh", function()
    repo.write_file("src/file.txt", { "original" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("src/file.txt", { "staged" })
    repo.git({ "add", "." }, 0)
    repo.write_file("src/file.txt", { "unstaged" })
    local _, root = open("src/file.txt")
    local top, bottom = root.panes[1], root.panes[2]
    cursor(top, "src", "directory"):collapse()
    top.tree:render()
    cursor(bottom, "src/file.txt")
    repo.write_file("another.txt", { "new" })
    require("codediff.ui.refresh").request(root.tabpage, { full = true })
    eventually(function() return node_at(top, "another.txt") ~= nil end)
    assert.is_false(node_at(top, "src", "directory"):is_expanded())
    assert.is_true(node_at(bottom, "src", "directory"):is_expanded())
    assert.equals("src/file.txt", bottom.tree:get_node(vim.api.nvim_win_get_cursor(bottom.winid)[1]).data.path)
    assert.equals("src", top.tree:get_node(vim.api.nvim_win_get_cursor(top.winid)[1]).data.dir_path)
  end)

  it("stages and unstages all files from either tree without modifying the worktree", function()
    repo.write_file("a.txt", { "before" })
    repo.git({ "add", "." }, 0)
    repo.git({ "commit", "-m", "initial" }, 0)
    repo.write_file("a.txt", { "after" })
    repo.write_file("nested/new.txt", { "new" })
    local _, root = open("a.txt")
    invoke(root.panes[2].winid, "Stage all files")
    eventually(function()
      return repo.git({ "show", ":a.txt" }) == "after\n" and #root.data.status_result.unstaged == 0
    end)
    assert.equals("new\n", repo.git({ "show", ":nested/new.txt" }))
    invoke(root.winid, "Unstage all files")
    eventually(function()
      return repo.git({ "diff", "--cached", "--name-only" }) == "" and #root.data.status_result.staged == 0
    end)
    assert.equals("after", vim.fn.readfile(repo.path("a.txt"))[1])
    assert.equals("new", vim.fn.readfile(repo.path("nested/new.txt"))[1])
  end)

  it("treats pathspec magic literally and unstages an unborn index", function()
    repo.write_file(":(glob)*/new.txt", { "literal" })
    repo.write_file("outside/new.txt", { "outside" })
    local git = require("codediff.core.git")
    local completed, failure
    git.stage_file(repo.dir, ":(glob)*", function(err) completed, failure = true, err end)
    eventually(function() return completed end)
    assert.is_nil(failure)
    assert.equals(":(glob)*/new.txt\n", repo.git({ "ls-files" }))
    completed = false
    git.unstage_file(repo.dir, ":(glob)*", function(err) completed, failure = true, err end)
    eventually(function() return completed end)
    assert.is_nil(failure)
    assert.equals("", repo.git({ "ls-files" }))
    assert.equals("literal", vim.fn.readfile(repo.path(":(glob)*/new.txt"))[1])
    assert.equals("outside", vim.fn.readfile(repo.path("outside/new.txt"))[1])
  end)
end)
