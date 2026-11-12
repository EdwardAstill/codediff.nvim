-- Keymap setup for conflict resolution
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local resolve = require("codediff.keymap.resolve")
local tracking = require("codediff.ui.conflict.tracking")
local resolution = require("codediff.ui.conflict.resolution")
local navigation = require("codediff.ui.conflict.navigation")

-- Dot-repeatable actions are expr mappings (see conflict.tracking).
local REPEATABLE_ACTIONS = {
  { key = "accept_incoming", fn = resolution.accept_incoming, desc = "Accept incoming change" },
  { key = "accept_current", fn = resolution.accept_current, desc = "Accept current change" },
  { key = "accept_both", fn = resolution.accept_both, desc = "Take Current then Incoming" },
  { key = "accept_both_reverse", fn = resolution.accept_both_reverse, desc = "Take Incoming then Current" },
  { key = "accept_base", fn = resolution.accept_base, desc = "Use Base (resolve conflict)" },
  { key = "mark_resolved", fn = resolution.mark_resolved, desc = "Mark manual edit resolved" },
  { key = "discard", fn = resolution.discard, desc = "Reset conflict (unresolved)" },
}

local PLAIN_ACTIONS = {
  { key = "accept_all_incoming", fn = resolution.accept_all_incoming, desc = "Accept ALL incoming changes" },
  { key = "accept_all_current", fn = resolution.accept_all_current, desc = "Accept ALL current changes" },
  { key = "accept_all_both", fn = resolution.accept_all_both, desc = "Take ALL Current then Incoming" },
  { key = "discard_all", fn = resolution.discard_all, desc = "Reset ALL conflicts (unresolved)" },
  { key = "next_conflict", fn = navigation.navigate_next_conflict, desc = "Next conflict" },
  { key = "prev_conflict", fn = navigation.navigate_prev_conflict, desc = "Previous conflict" },
  { key = "toggle_scroll_sync", fn = function(tabpage) require("codediff.ui.conflict.view.result").toggle_scroll_sync(tabpage) end, desc = "Toggle linked vertical scrolling" },
  { key = "toggle_maximize", fn = function(tabpage) require("codediff.ui.conflict.view.result").toggle_maximize(tabpage) end, desc = "Toggle pane maximize" },
}

-- Vimdiff-style numbered diffget, only meaningful on the result buffer.
local RESULT_ONLY_ACTIONS = {
  { key = "diffget_incoming", fn = resolution.diffget_incoming, desc = "Get hunk from incoming (2do)" },
  { key = "diffget_current", fn = resolution.diffget_current, desc = "Get hunk from current (3do)" },
}

--- Setup conflict keymaps for a session
---
--- Ordinary do/dp are not deleted here. The view layer skips claiming them
--- while a result pane exists, so any mapping the user already had on those
--- keys stays intact for the duration of the merge instead of being destroyed.
--- @param tabpage number
function M.setup_keymaps(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  lifecycle.begin_keymap_scope(tabpage, "conflict")

  local keymaps = resolve.keymaps_for("conflict")

  local buffers = { session.original_bufnr, session.modified_bufnr, session.result_bufnr, session.base_bufnr }

  local base_opts = { noremap = true, silent = true, nowait = true }

  local function bind(bufnr, action, opts)
    if not keymaps[action.key] then
      return
    end
    lifecycle.set_buf_keymap(tabpage, bufnr, "n", keymaps[action.key], opts.rhs, vim.tbl_extend("force", base_opts, opts.extra or {}))
  end

  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, action in ipairs(REPEATABLE_ACTIONS) do
        bind(bufnr, action, {
          rhs = tracking.make_repeatable(function()
            action.fn(tabpage)
          end),
          extra = { desc = action.desc, expr = true },
        })
      end

      for _, action in ipairs(PLAIN_ACTIONS) do
        bind(bufnr, action, {
          rhs = function()
            action.fn(tabpage)
          end,
          extra = { desc = action.desc },
        })
      end

      if bufnr == session.result_bufnr then
        for _, action in ipairs(RESULT_ONLY_ACTIONS) do
          bind(bufnr, action, {
            rhs = tracking.make_repeatable(function()
              action.fn(tabpage)
            end),
            extra = { desc = action.desc, expr = true },
          })
        end
      else
        for _, undo in ipairs({ { "u", "u", "Undo Result" }, { "<C-r>", "\18", "Redo Result" } }) do
          lifecycle.set_buf_keymap(tabpage, bufnr, "n", undo[1], function()
            if vim.api.nvim_buf_is_valid(session.result_bufnr) then
              local count = vim.v.count1
              vim.api.nvim_buf_call(session.result_bufnr, function()
                vim.cmd.normal({ args = { tostring(count) .. undo[2] }, bang = true })
              end)
              tracking.sync(session)
              require("codediff.ui.refresh").refresh_result_now(session.result_bufnr)
            end
          end, vim.tbl_extend("force", base_opts, { desc = undo[3] }))
        end
      end
    end
  end

  lifecycle.end_keymap_scope(tabpage, "conflict")
end

return M
