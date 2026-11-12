-- Coordinate conflict gutter computation and its Neovim renderers.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")
local filler = require("codediff.ui.filler")
local compute = require("codediff.ui.conflict.gutter.compute")
local signcolumn = require("codediff.ui.conflict.gutter.signcolumn")
local statuscolumn = require("codediff.ui.conflict.gutter.statuscolumn")

local function normalize_range(bufnr, range)
  if not bufnr or not range or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return nil
  end

  local start_line = math.max(1, math.min(range.start_line, line_count + 1))
  local end_line = math.max(1, math.min(range.end_line, line_count + 1))
  if end_line < start_line then
    return nil
  end

  return { start_line = start_line, end_line = end_line }
end

local function compute_projection(bufnr, range, filler_counts, highlight)
  local normalized = normalize_range(bufnr, range)
  if not normalized then
    return nil
  end

  local positions = compute.visual_positions(normalized, filler_counts)
  if #positions == 0 and normalized.start_line == normalized.end_line then
    positions = { { line = math.min(normalized.start_line, vim.api.nvim_buf_line_count(bufnr)), offset = 0 } }
  end
  if #positions == 0 then
    return nil
  end

  return {
    markers = compute.compute_markers(positions),
    highlight = highlight,
  }
end

local function accepted_highlights(session, block)
  if tracking.is_block_active(session, block) then
    return "CodeDiffConflictSign", "CodeDiffConflictSign", "CodeDiffConflictSign"
  end

  local accepted = tracking.get_accepted_side(session, block)
  if accepted == "incoming" then
    return "CodeDiffConflictSignAccepted", "CodeDiffConflictSignRejected", "CodeDiffConflictSignResolved"
  elseif accepted == "current" then
    return "CodeDiffConflictSignRejected", "CodeDiffConflictSignAccepted", "CodeDiffConflictSignResolved"
  elseif accepted == "both" then
    return "CodeDiffConflictSignAccepted", "CodeDiffConflictSignAccepted", "CodeDiffConflictSignResolved"
  end
  return "CodeDiffConflictSignResolved", "CodeDiffConflictSignResolved", "CodeDiffConflictSignResolved"
end


local function clear_markers(session, namespace)
  for _, bufnr in ipairs({ session.original_bufnr, session.modified_bufnr, session.base_bufnr }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    end
  end
  if session.result_bufnr and vim.api.nvim_buf_is_valid(session.result_bufnr) then
    vim.api.nvim_buf_clear_namespace(session.result_bufnr, tracking.result_signs_ns, 0, -1)
  end
end

--- Recompute all conflict marker maps and render them in every buffer.
function M.refresh(session)
  if not session or not session.conflict_blocks then
    return
  end

  local highlights = require("codediff.ui.highlights")
  local ns_conflict = highlights.ns_conflict

  tracking.sync(session)

  clear_markers(session, ns_conflict)

  local original_counts = filler.get_virt_line_counts(session.original_bufnr)
  local modified_counts = filler.get_virt_line_counts(session.modified_bufnr)
  local result_counts = filler.get_virt_line_counts(session.result_bufnr)
  local base_counts = session.base_bufnr and filler.get_virt_line_counts(session.base_bufnr) or {}
  local original_projections = {}
  local modified_projections = {}
  local result_projections = {}
  local base_projections = {}

  for _, block in ipairs(session.conflict_blocks) do
    local left_highlight, right_highlight, result_highlight = accepted_highlights(session, block)

    local original = compute_projection(session.original_bufnr, block.output1_range, original_counts, left_highlight)
    if original then
      original_projections[#original_projections + 1] = original
    end

    local modified = compute_projection(session.modified_bufnr, block.output2_range, modified_counts, right_highlight)
    if modified then
      modified_projections[#modified_projections + 1] = modified
    end
    local base_highlight = tracking.is_block_active(session, block) and "CodeDiffConflictSign"
      or tracking.get_accepted_side(session, block) == "base" and "CodeDiffConflictSignAccepted"
      or "CodeDiffConflictSignResolved"
    local base = compute_projection(session.base_bufnr, block.base_range, base_counts, base_highlight)
    if base then
      base_projections[#base_projections + 1] = base
    end

    if session.result_bufnr and vim.api.nvim_buf_is_valid(session.result_bufnr) and block.extmark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking.tracking_ns, block.extmark_id, { details = true })
      if mark and #mark >= 3 and mark[3].end_row then
        local result = compute_projection(session.result_bufnr, { start_line = mark[1] + 1, end_line = mark[3].end_row + 1 }, result_counts, result_highlight)
        if result then
          result_projections[#result_projections + 1] = result
        end
      end
    end
  end

  signcolumn.render(session.original_bufnr, original_projections, ns_conflict)
  signcolumn.render(session.modified_bufnr, modified_projections, ns_conflict)
  signcolumn.render(session.result_bufnr, result_projections, tracking.result_signs_ns)
  signcolumn.render(session.base_bufnr, base_projections, ns_conflict)
  statuscolumn.update(session.original_win, original_projections, original_counts)
  statuscolumn.update(session.modified_win, modified_projections, modified_counts)
  statuscolumn.update(session.base_win, base_projections, base_counts)
  statuscolumn.update(session.result_win, result_projections, result_counts)
  require("codediff.ui.conflict.view.result").update_labels(session)
end

--- Attach gutter rendering to every merge pane.
function M.attach(original_win, modified_win, base_win, result_win)
  statuscolumn.attach(original_win)
  statuscolumn.attach(modified_win)
  statuscolumn.attach(base_win)
  statuscolumn.attach(result_win)
end

--- Detach gutter rendering from one conflict input window.
function M.detach(win)
  statuscolumn.detach(win)
end

--- Release all gutter resources before a conflict view is retargeted or closed.
function M.teardown(tabpage)
  local session = lifecycle.get_session(tabpage)
  if session then
    clear_markers(session, require("codediff.ui.highlights").ns_conflict)
    M.detach(session.original_win)
    M.detach(session.modified_win)
    M.detach(session.base_win)
    M.detach(session.result_win)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "CodeDiffConflictGutter_" .. tabpage)
end

--- Setup an autocmd to refresh gutter markers when the result changes.
function M.setup_refresh_autocmd(tabpage, result_bufnr)
  if not result_bufnr or not vim.api.nvim_buf_is_valid(result_bufnr) then
    return
  end

  local group = vim.api.nvim_create_augroup("CodeDiffConflictGutter_" .. tabpage, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = result_bufnr,
    callback = function()
      local session = lifecycle.get_session(tabpage)
      if session and not session.suspended and session.result_bufnr == result_bufnr then
        M.refresh(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffConflictChanged",
    callback = function(args)
      local session = lifecycle.get_session(tabpage)
      if session and not session.suspended and session.result_bufnr == result_bufnr and args.data.bufnr == result_bufnr then
        M.refresh(session)
      end
    end,
  })
end

return M
