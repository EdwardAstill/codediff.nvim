local tracking = require("codediff.ui.conflict.tracking")
local diff = require("codediff.core.diff")
local support = require("tests.support")

describe("persistent merge Result binding", function()
  local path, bufnr, base, inputs, session
  local markers = { "prefix", "<<<<<<< HEAD", "current", "=======", "incoming", ">>>>>>> branch", "suffix" }

  local function load(lines)
    vim.fn.writefile(lines, path)
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    session = { result_bufnr = bufnr, merge_input_identity = "stages-one" }
  end

  local function lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  before_each(function()
    support.ensure_plugin_loaded()
    path = vim.fn.tempname()
    base = { "prefix", "base", "suffix" }
    local incoming, current = { "prefix", "incoming", "suffix" }, { "prefix", "current", "suffix" }
    local options = { max_computation_time_ms = 2000, ignore_trim_whitespace = false, compute_moves = false }
    inputs = {
      original_lines = incoming,
      modified_lines = current,
      base_to_original_diff = diff.compute_diff(base, incoming, options),
      base_to_modified_diff = diff.compute_diff(base, current, options),
    }
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    vim.fn.delete(path)
  end)

  it("seeds only a complete fresh Git conflict file with Base", function()
    load(markers)
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.same(base, lines())
    assert.equals(1, tracking.unresolved_count(session))
    assert.is_true(vim.bo[bufnr].modified)
    assert.equals("stages-one", tracking.get_state(path).merge_input_identity)
  end)

  it("preserves saved manual content without cached metadata", function()
    load({ "prefix", "manual resolution", "suffix" })
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.same({ "prefix", "manual resolution", "suffix" }, lines())
    assert.equals(1, tracking.unresolved_count(session))
    assert.is_not_nil(tracking.stage_error(path))
  end)

  it("does not reseed a partially edited marker file", function()
    local partial = vim.deepcopy(markers)
    partial[3] = "manual current"
    load(partial)
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.same(partial, lines())
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("retains unsaved manual content, tracked ranges and approvals across reopen", function()
    load(markers)
    assert.is_true(tracking.bind_result(session, base, inputs))
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { "manual", "extra" })
    local block = session.conflict_blocks[1]
    assert.is_true(tracking.apply(session, { { block = block, resolved = true, accepted = "manual" } }))
    local reopened = { result_bufnr = bufnr, merge_input_identity = "stages-one" }
    assert.is_true(tracking.bind_result(reopened, base, inputs))
    assert.same({ "prefix", "manual", "extra", "suffix" }, lines())
    assert.equals(block, reopened.conflict_blocks[1])
    assert.equals(0, tracking.unresolved_count(reopened))
    assert.is_not_nil(tracking.stage_error(path))
  end)

  it("preserves saved Use Base approval across reopen and blocks stale inputs", function()
    load(markers)
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.is_true(tracking.apply(session, { { block = session.conflict_blocks[1], lines = { "base" }, resolved = true, accepted = "base" } }))
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("write!") end)
    assert.is_true(tracking.has_work(session))
    assert.is_nil(tracking.stage_error(path))
    local reopened = { result_bufnr = bufnr, merge_input_identity = "stages-one" }
    assert.is_true(tracking.bind_result(reopened, base, inputs))
    assert.equals(0, tracking.unresolved_count(reopened))
    reopened.merge_input_identity = "different-stages"
    assert.is_false(tracking.bind_result(reopened, base, inputs))
    assert.same(base, lines())
    assert.equals("stages-one", tracking.get_state(path).merge_input_identity)
  end)

  it("refuses destructive replacement when a manual edit spans outside the conflict", function()
    load({ "whole file manually rewritten" })
    assert.is_true(tracking.bind_result(session, base, inputs))
    local block = session.conflict_blocks[1]
    assert.is_true(block.ambiguous)
    assert.is_false(tracking.apply(session, { { block = block, lines = { "incoming" }, resolved = true, accepted = "incoming" } }))
    assert.same({ "whole file manually rewritten" }, lines())
    assert.is_true(tracking.apply(session, { { block = block, resolved = true, accepted = "manual" } }))
  end)

  it("forgets approvals only on deliberate discard or buffer wipe", function()
    load(markers)
    assert.is_true(tracking.bind_result(session, base, inputs))
    tracking.forget_result(path)
    assert.is_nil(tracking.get_state(path))
    assert.is_not_nil(tracking.stage_error(path))
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.equals(1, tracking.unresolved_count(session))
  end)

  it("refreshes changed immutable inputs only while Result is untouched", function()
    load(markers)
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.is_false(tracking.has_work(session))
    inputs.modified_lines = { "prefix", "updated current", "suffix", "automatic addition" }
    inputs.base_to_modified_diff = diff.compute_diff(base, inputs.modified_lines, {
      max_computation_time_ms = 2000, ignore_trim_whitespace = false, compute_moves = false,
    })
    session.merge_input_identity = "stages-two"
    assert.is_true(tracking.bind_result(session, base, inputs))
    assert.same({ "prefix", "base", "suffix", "automatic addition" }, lines())
    assert.equals("stages-two", tracking.get_state(path).merge_input_identity)
    assert.equals(1, tracking.unresolved_count(session))
    assert.is_true(vim.api.nvim_buf_call(bufnr, function() return vim.fn.undotree().seq_last > 0 end))
  end)
end)
