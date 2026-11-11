local lifecycle = require("codediff.ui.lifecycle")
local sessions = require("codediff.ui.lifecycle.session").get_active_diffs()
local action = require("codediff.ui.view.actions.omp")

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function submit(dialog)
  vim.api.nvim_set_current_win(dialog.winid)
  local mapping = vim.fn.maparg("<C-s>", "i", false, true)
  assert.equals("function", type(mapping.callback))
  mapping.callback()
end

describe("Selected hunk OMP composer", function()
  local session, ctx, buffers, windows, origin, old_omp, old_preload, old_notify, notices, received

  local function buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local function float(buf, col)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 1, col = col, width = 20, height = 6, zindex = 60,
    })
    windows[#windows + 1] = win
    return win
  end

  local function focus(side, line)
    vim.api.nvim_set_current_win(session[side .. "_win"])
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end

  local function tick()
    session.changedtick = {
      original = vim.api.nvim_buf_get_changedtick(session.original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(session.modified_bufnr),
    }
  end

  before_each(function()
    buffers, windows, notices, received = {}, {}, {}, {}
    origin = vim.api.nvim_get_current_win()
    old_omp, old_preload, old_notify = package.loaded.omp, package.preload.omp, vim.notify
    vim.notify = function(message) notices[#notices + 1] = message end
    local original = buffer({ "private before", "keep 1", "keep 2", "chosen before", "keep 3", "private last before" })
    local modified = buffer({ "private after 1", "private after 2", "keep 1", "keep 2", "chosen after", "keep 3", "private last after" })
    session = {
      tabpage = vim.api.nvim_get_current_tabpage(), git_root = "/repo",
      original = { absolute = "/repo/old.txt", relative = "old.txt" },
      modified = { absolute = "/repo/new.txt", relative = "new.txt" },
      original_revision = "0123456789abcdef", modified_revision = ":0",
      source_revisions = { original = "HEAD" },
      original_bufnr = original, modified_bufnr = modified,
      original_win = float(original, 1), modified_win = float(modified, 23),
      popup = {},
      stored_diff_result = { changes = {
        { original = { start_line = 1, end_line = 2 }, modified = { start_line = 1, end_line = 3 } },
        { original = { start_line = 4, end_line = 5 }, modified = { start_line = 5, end_line = 6 } },
        { original = { start_line = 6, end_line = 7 }, modified = { start_line = 7, end_line = 8 } },
      } },
    }
    tick()
    sessions[session.tabpage] = session
    ctx = { tabpage = session.tabpage, original_bufnr = original, modified_bufnr = modified }
    package.loaded.omp = { send = function(text)
      received[#received + 1] = text
      local win = float(buffer({ "OMP draft" }), 2)
      vim.api.nvim_win_set_config(win, { zindex = 50 })
      vim.api.nvim_set_current_win(win)
      return true
    end }
  end)

  after_each(function()
    vim.cmd("stopinsert")
    if session.popup and session.popup.dialog then session.popup.dialog.close() end
    sessions[session.tabpage] = nil
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    package.loaded.omp, package.preload.omp, vim.notify = old_omp, old_preload, old_notify
  end)

  local expected = table.concat({
    'Repository: "/repo"',
    'Before (left): "0123456789abcdef" (requested "HEAD")',
    'Before (left) file: "/repo/old.txt"',
    'After (right): ":0"',
    'After (right) file: "/repo/new.txt"',
    '', '--- "a/old.txt"', '+++ "b/new.txt"', '@@ -4,1 +5,1 @@',
    '-chosen before', '+chosen after', '',
  }, "\n")

  for _, side in ipairs({ "original", "modified" }) do
    it("captures only the selected hunk from the " .. side .. " pane with a blank message", function()
      focus(side, side == "original" and 4 or 5)
      local dialog = action.send_hunk(ctx)
      submit(dialog)
      assert.same({ expected }, received)
      assert.is_false(vim.api.nvim_buf_is_valid(dialog.bufnr))
      assert.is_true(vim.api.nvim_win_get_config(0).zindex > vim.api.nvim_win_get_config(session.modified_win).zindex)
      assert.equals(session, lifecycle.get_session(ctx.tabpage))
      assert.is_true(vim.api.nvim_win_is_valid(session.original_win))
      assert.is_true(vim.api.nvim_win_is_valid(session.modified_win))
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
      assert.is_true(vim.wait(1000, function() return vim.api.nvim_get_current_win() == session[side .. "_win"] end))
    end)
  end

  it("composes in a native diff session without popup ownership", function()
    session.popup = nil
    focus("modified", 5)
    local dialog = action.send_hunk(ctx)
    submit(dialog)
    assert.same({ expected }, received)
    assert.is_false(vim.api.nvim_buf_is_valid(dialog.bufnr))
  end)

  it("returns to the retained composer when OMP opens but rejects the draft", function()
    local omp_win
    package.loaded.omp = {
      send = function()
        omp_win = float(buffer({ "Disconnected OMP" }), 2)
        vim.api.nvim_win_set_config(omp_win, { zindex = 100 })
        vim.api.nvim_set_current_win(omp_win)
        return false
      end,
      hide = function() vim.api.nvim_win_close(omp_win, true) end,
    }
    focus("modified", 5)
    local dialog = action.send_hunk(ctx)
    vim.api.nvim_buf_set_lines(dialog.bufnr, 0, -1, false, { "Keep this draft" })
    submit(dialog)
    assert.equals(dialog.winid, vim.api.nvim_get_current_win())
    assert.same({ "Keep this draft" }, vim.api.nvim_buf_get_lines(dialog.bufnr, 0, -1, false))
    assert.is_false(vim.api.nvim_win_is_valid(omp_win))
  end)

  it("preserves the captured hunk and paths when the view changes during composition", function()
    focus("modified", 5)
    local dialog = action.send_hunk(ctx)
    vim.api.nvim_buf_set_lines(dialog.bufnr, 0, -1, false, { "Explain this change", "without editing it" })
    session.modified = { absolute = "/repo/another.txt", relative = "another.txt" }
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 4, 5, false, { "a later edit" })
    submit(dialog)
    assert.same({ "Explain this change\nwithout editing it\n\n" .. expected }, received)
  end)

  for _, deletion in ipairs({ false, true }) do
    it("uses zero-length unified ranges for a pure " .. (deletion and "deletion" or "addition"), function()
      local empty = deletion and "modified" or "original"
      local content = deletion and "original" or "modified"
      session[empty] = { absolute = "", relative = "" }
      session.original_revision, session.modified_revision = ":0", nil
      session.source_revisions = nil
      session.stored_diff_result.changes = { {
        original = { start_line = 1, end_line = deletion and 2 or 1 },
        modified = { start_line = 1, end_line = deletion and 1 or 2 },
      } }
      vim.api.nvim_buf_set_lines(session[content .. "_bufnr"], 0, -1, false, { "only selected line" })
      tick()
      focus(empty, 1)
      local dialog = action.send_hunk(ctx)
      submit(dialog)
      local text = received[1]
      assert.is_truthy(text:find('After (right): "WORKTREE"', 1, true))
      assert.is_truthy(text:find(deletion and "+++ /dev/null" or "--- /dev/null", 1, true))
      assert.is_truthy(text:find(deletion and "@@ -1,1 +0,0 @@\n-only selected line\n" or "@@ -0,0 +1,1 @@\n+only selected line\n", 1, true))
      assert.is_nil(text:find("private", 1, true))
    end)
  end

  it("cancels without loading OMP or sending anything", function()
    package.loaded.omp = nil
    package.preload.omp = function() error("OMP must not load on cancel") end
    focus("modified", 5)
    local dialog = action.send_hunk(ctx)
    vim.api.nvim_buf_set_lines(dialog.bufnr, 0, -1, false, { "Do not send" })
    press("<C-q>")
    assert.is_false(vim.api.nvim_buf_is_valid(dialog.bufnr))
    assert.same({}, received)
    assert.same({}, notices)
  end)

  for _, failure in ipairs({ "missing", "rejected", "exception" }) do
    it("retains the message and original hunk after OMP is " .. failure, function()
      local transport = package.loaded.omp
      if failure == "missing" then
        package.loaded.omp = nil
        package.preload.omp = function() error("not installed") end
      else
        package.loaded.omp = { send = function()
          if failure == "exception" then error("connection failure") end
          return false
        end }
      end
      focus("modified", 5)
      local dialog = action.send_hunk(ctx)
      vim.api.nvim_buf_set_lines(dialog.bufnr, 0, -1, false, { "Keep my message" })
      submit(dialog)
      assert.is_true(vim.api.nvim_buf_is_valid(dialog.bufnr))
      assert.same({ "Keep my message" }, vim.api.nvim_buf_get_lines(dialog.bufnr, 0, -1, false))
      package.loaded.omp = transport
      session.original_revision = "a different revision"
      submit(dialog)
      assert.same({ "Keep my message\n\n" .. expected }, received)
    end)
  end

  it("does not capture scratch text or outdated diff ranges", function()
    focus("modified", 5)
    local dialog = action.send_hunk(ctx)
    assert.is_nil(action.send_hunk(ctx))
    dialog.close()
    focus("modified", 5)
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, 0, false, { "new unsaved line" })
    assert.is_nil(action.send_hunk(ctx))
    assert.same({}, received)
  end)
end)
