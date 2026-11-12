local conflict = require("codediff.ui.conflict")
local lifecycle = require("codediff.ui.lifecycle")

describe("conflict navigation", function()
  local original_get_session
  local tabpage
  local session
  local buffers

  local function new_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    buffers[#buffers + 1] = bufnr
    return bufnr
  end

  before_each(function()
    original_get_session = lifecycle.get_session
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    buffers = {}

    local lines = { "one", "two", "three", "four", "five" }
    local blocks = {
      {
        base_range = { start_line = 1, end_line = 2 },
        result_range = { start_line = 1, end_line = 2 },
        output1_range = { start_line = 1, end_line = 2 },
        output2_range = { start_line = 1, end_line = 2 },
      },
      {
        base_range = { start_line = 4, end_line = 5 },
        result_range = { start_line = 4, end_line = 5 },
        output1_range = { start_line = 4, end_line = 5 },
        output2_range = { start_line = 4, end_line = 5 },
      },
    }
    session = {
      result_bufnr = new_buffer(vim.deepcopy(lines)),
      original_bufnr = new_buffer(vim.deepcopy(lines)),
      modified_bufnr = new_buffer(vim.deepcopy(lines)),
      base_bufnr = new_buffer(vim.deepcopy(lines)),
      result_base_lines = vim.deepcopy(lines),
      conflict_blocks = blocks,
    }
    session.original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(session.original_win, session.original_bufnr)
    session.modified_win = vim.api.nvim_open_win(session.modified_bufnr, false, { split = "right", win = session.original_win })
    session.base_win = vim.api.nvim_open_win(session.base_bufnr, false, { split = "below", win = session.original_win })
    session.result_win = vim.api.nvim_open_win(session.result_bufnr, false, { split = "below", win = session.modified_win })
    lifecycle.get_session = function(candidate)
      return candidate == tabpage and session or nil
    end
    conflict.initialize_tracking(session.result_bufnr, blocks)
  end)

  after_each(function()
    lifecycle.get_session = original_get_session
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.cmd("tabclose!")
  end)

  it("moves forward, wraps, and moves backward across active blocks", function()
    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    conflict.navigate_next_conflict(tabpage)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    for _, side in ipairs({ "modified", "base", "result" }) do
      assert.equals(4, vim.api.nvim_win_get_cursor(session[side .. "_win"])[1])
    end

    conflict.navigate_next_conflict(tabpage)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])

    conflict.navigate_prev_conflict(tabpage)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("navigates from Base and Result, including a single unresolved block", function()
    for _, side in ipairs({ "base", "result" }) do
      vim.api.nvim_set_current_win(session[side .. "_win"])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      conflict.navigate_next_conflict(tabpage)
      assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    end
    session.conflict_blocks = { session.conflict_blocks[2] }
    conflict.navigate_next_conflict(tabpage)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("links visual rows without copying horizontal offsets or moving the editing cursor", function()
    local result_view = require("codediff.ui.conflict.view.result")
    local lines = {}
    for line = 1, 100 do lines[line] = string.rep("x", 160) end
    for _, buf in ipairs(buffers) do vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
    session.merge_fillers = { {}, {}, { { after_line = 0, count = 2 } }, {} }
    require("codediff.ui.filler").place(session.base_bufnr, -1, 2)
    for index, side in ipairs({ "original", "modified", "base", "result" }) do
      local win = session[side .. "_win"]
      vim.wo[win].wrap = false
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ lnum = 45, col = 60, topline = 40, leftcol = index * 10 })
      end)
    end
    vim.api.nvim_set_current_win(session.original_win)
    vim.fn.winrestview({ lnum = 45, col = 60, topline = 42, leftcol = 40 })
    local cursor = vim.api.nvim_win_get_cursor(0)
    local offsets = {}
    for _, side in ipairs({ "modified", "base", "result" }) do
      offsets[side] = vim.api.nvim_win_call(session[side .. "_win"], vim.fn.winsaveview).leftcol
    end
    result_view.sync_scroll(session, session.original_win)
    assert.equals(40, vim.api.nvim_win_call(session.base_win, vim.fn.winsaveview).topline)
    assert.equals(42, vim.api.nvim_win_call(session.result_win, vim.fn.winsaveview).topline)
    assert.same(cursor, vim.api.nvim_win_get_cursor(0))
    for side, offset in pairs(offsets) do
      assert.equals(offset, vim.api.nvim_win_call(session[side .. "_win"], vim.fn.winsaveview).leftcol)
    end
    session.merge_scroll_sync = false
    vim.fn.winrestview({ topline = 43 })
    result_view.sync_scroll(session, session.original_win)
    assert.equals(42, vim.api.nvim_win_call(session.result_win, vim.fn.winsaveview).topline)
  end)
end)
