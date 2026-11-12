local conflict = require("codediff.ui.conflict")
local tracking = require("codediff.ui.conflict.tracking")
local lifecycle = require("codediff.ui.lifecycle")

describe("explicit conflict state", function()
  local buffers, files, session, tabpage, original_get_session

  local function buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    buffers[#buffers + 1] = buf
    return buf
  end

  local function focus(buf, line)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { line or 2, 0 })
  end

  local function result()
    return vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)
  end

  local function save()
    vim.api.nvim_buf_call(session.result_bufnr, function() vim.cmd("write!") end)
  end

  local function undo(command)
    vim.api.nvim_buf_call(session.result_bufnr, function() vim.cmd(command or "undo") end)
    tracking.sync(session)
  end

  local function configure()
    local base = { "head", "base one", "base two", "tail" }
    session = {
      result_bufnr = buffer(base),
      base_bufnr = buffer(base),
      original_bufnr = buffer({ "head", "incoming one", "incoming two", "tail" }),
      modified_bufnr = buffer({ "head", "current one", "current two", "tail" }),
      merge_base_lines = base,
      result_base_lines = base,
      conflict_blocks = {},
    }
    for line = 2, 3 do
      session.conflict_blocks[#session.conflict_blocks + 1] = {
        base_range = { start_line = line, end_line = line + 1 },
        output1_range = { start_line = line, end_line = line + 1 },
        output2_range = { start_line = line, end_line = line + 1 },
      }
    end
    local path = vim.fn.tempname()
    files[#files + 1] = path
    vim.api.nvim_buf_set_name(session.result_bufnr, path)
    vim.bo[session.result_bufnr].buftype = ""
    tracking.initialize_tracking(session.result_bufnr, session.conflict_blocks)
    focus(session.result_bufnr)
    return path
  end

  before_each(function()
    buffers, files = {}, {}
    tabpage = vim.api.nvim_get_current_tabpage()
    original_get_session = lifecycle.get_session
    lifecycle.get_session = function(candidate) return candidate == tabpage and session or nil end
  end)

  after_each(function()
    lifecycle.get_session = original_get_session
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    for _, path in ipairs(files) do vim.fn.delete(path) end
  end)

  it("undoes and redoes Use Base and Reset even without a text change", function()
    configure()
    local before = result()
    assert.is_true(conflict.accept_base(tabpage))
    assert.same(before, result())
    assert.equals(1, tracking.unresolved_count(session))
    undo()
    assert.equals(2, tracking.unresolved_count(session))
    undo("redo")
    assert.equals(1, tracking.unresolved_count(session))
    assert.equals("base", tracking.get_accepted_side(session, session.conflict_blocks[1]))
    assert.is_true(conflict.discard(tabpage))
    assert.equals(2, tracking.unresolved_count(session))
    undo()
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("requires explicit manual approval, saving does not approve", function()
    local path = configure()
    vim.api.nvim_buf_set_lines(session.result_bufnr, 1, 2, true, { "manual" })
    save()
    assert.equals(2, tracking.unresolved_count(session))
    assert.is_not_nil(tracking.stage_error(path))
    assert.is_true(conflict.mark_resolved(tabpage))
    assert.equals(1, tracking.unresolved_count(session))
    undo()
    assert.equals("manual", result()[2])
    assert.equals(2, tracking.unresolved_count(session))
    undo("redo")
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("invalidates only the edited approval across save, undo and redo", function()
    local path = configure()
    assert.is_true(conflict.accept_all_incoming(tabpage))
    save()
    assert.is_nil(tracking.stage_error(path))
    vim.api.nvim_buf_set_lines(session.result_bufnr, 2, 3, true, { "edited second" })
    save()
    assert.equals(1, tracking.unresolved_count(session))
    assert.is_false(tracking.is_block_active(session, session.conflict_blocks[1]))
    assert.is_true(tracking.is_block_active(session, session.conflict_blocks[2]))
    assert.is_not_nil(tracking.stage_error(path))
    undo()
    assert.equals(0, tracking.unresolved_count(session))
    undo("redo")
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("does not invalidate an adjacent block when inserting at its exclusive end", function()
    configure()
    assert.is_true(conflict.accept_all_incoming(tabpage))
    vim.api.nvim_buf_set_lines(session.result_bufnr, 3, 3, true, { "outside both" })
    assert.equals(0, tracking.unresolved_count(session))
    vim.api.nvim_buf_set_lines(session.result_bufnr, 0, 0, true, { "new head" })
    focus(session.result_bufnr, 3)
    assert.is_true(conflict.accept_current(tabpage))
    assert.equals("current one", result()[3])
  end)

  it("finds the next block rather than the previous block at an exclusive boundary", function()
    configure()
    assert.equals(session.conflict_blocks[2], tracking.find_conflict_at_cursor_in_result(session, 3))
  end)

  it("takes either side from all four cursor contexts", function()
    configure()
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr, session.base_bufnr, session.result_bufnr }) do
      focus(buf)
      assert.is_true(conflict.accept_current(tabpage))
      assert.equals("current one", result()[2])
      assert.is_true(conflict.discard(tabpage))
      assert.equals("base one", result()[2])
    end
  end)

  it("uses deterministic Both ordering independent of focus", function()
    configure()
    focus(session.original_bufnr)
    assert.is_true(conflict.accept_both(tabpage))
    assert.same({ "head", "current one", "incoming one", "base two", "tail" }, result())
    focus(session.base_bufnr)
    assert.is_true(conflict.accept_both_reverse(tabpage))
    assert.same({ "head", "incoming one", "current one", "base two", "tail" }, result())
  end)

  it("keeps metadata by path without a visible session and removes it on wipe", function()
    local path = configure()
    assert.is_true(conflict.accept_all_incoming(tabpage))
    assert.is_not_nil(tracking.stage_error(path))
    save()
    local buf = session.result_bufnr
    session = nil
    assert.equals(0, tracking.unresolved_count(tracking.get_state(path)))
    assert.is_nil(tracking.stage_error(path))
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(tracking.get_state(path))
    assert.is_not_nil(tracking.stage_error(path))
  end)

  it("never replaces an untracked range by searching similar text", function()
    configure()
    local before = result()
    vim.api.nvim_buf_del_extmark(session.result_bufnr, tracking.tracking_ns, session.conflict_blocks[1].extmark_id)
    assert.is_false(conflict.accept_incoming(tabpage))
    assert.same(before, result())
  end)

  it("resolves empty Base conflicts at BOF and EOF with native undo", function()
    for _, line in ipairs({ 1, 2 }) do
      local buf = buffer({ "anchor" })
      local block = { base_range = { start_line = line, end_line = line } }
      local current = { result_bufnr = buf, conflict_blocks = { block } }
      tracking.initialize_tracking(buf, current.conflict_blocks)
      assert.equals(block, tracking.find_conflict_at_cursor_in_result(current, 1))
      assert.is_true(tracking.apply(current, { { block = block, lines = {}, resolved = true, accepted = "base" } }))
      assert.equals(0, tracking.unresolved_count(current))
      vim.api.nvim_buf_call(buf, function() vim.cmd("undo") end)
      assert.equals(1, tracking.unresolved_count(current))
      assert.is_true(tracking.apply(current, { { block = block, lines = { "inserted" }, resolved = true, accepted = "incoming" } }))
      assert.equals("inserted", vim.api.nvim_buf_get_lines(buf, line - 1, line, true)[1])
    end
  end)

  it("rejects externally modified disk content after an approved save", function()
    local path = configure()
    assert.is_true(conflict.accept_all_incoming(tabpage))
    save()
    assert.is_nil(tracking.stage_error(path))
    vim.fn.writefile({ "unreviewed external edit" }, path)
    assert.is_false(vim.bo[session.result_bufnr].modified)
    assert.is_not_nil(tracking.stage_error(path))
  end)

  it("Reset retains automatic disjoint edits and is atomic across the file", function()
    configure()
    vim.api.nvim_buf_set_lines(session.result_bufnr, 0, 1, true, { "automatic disjoint change" })
    assert.is_true(conflict.accept_all_current(tabpage))
    assert.is_true(conflict.discard_all(tabpage))
    assert.same({ "automatic disjoint change", "base one", "base two", "tail" }, result())
    assert.equals(2, tracking.unresolved_count(session))
    undo()
    assert.same({ "automatic disjoint change", "current one", "current two", "tail" }, result())
    assert.equals(0, tracking.unresolved_count(session))
  end)

  it("allows a saved empty Result but rejects an external newline-only change", function()
    local path = configure()
    assert.is_true(conflict.accept_all_incoming(tabpage))
    vim.api.nvim_buf_set_lines(session.result_bufnr, 0, -1, true, {})
    for _, block in ipairs(session.conflict_blocks) do
      assert.is_true(tracking.apply(session, { { block = block, resolved = true, accepted = "manual" } }))
    end
    save()
    assert.is_nil(tracking.stage_error(path))
    local file = assert(io.open(path, "rb"))
    local saved = file:read("*a")
    file:close()
    file = assert(io.open(path, "wb"))
    file:write(saved == "" and "\n" or "")
    file:close()
    assert.is_not_nil(tracking.stage_error(path))
  end)
end)
