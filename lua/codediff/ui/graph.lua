local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local dialog = require("codediff.ui.dialog")
local revision = require("codediff.core.git.revision")
local runner = require("codediff.core.git.runner")
local actions = require("codediff.ui.view.actions.repository")

local PAGE_SIZE = 200
local graph_ns = vim.api.nvim_create_namespace("codediff-graph")

-- Replace ASCII graph characters with cleaner Unicode box-drawing equivalents.
-- Every replacement is 1 column wide so column alignment stays correct.
local GRAPH_CHAR = setmetatable({ ["|"] = "│", ["*"] = "●", ["/"] = "╱", ["\\"] = "╲", ["_"] = "─", ["."] = "·" },
  { __index = function(_, c) return c end })
local GRAPH_PATTERN = "[" .. ("|*_./\\"):gsub(".", function(c) return "%" .. c end) .. "]"

local function enhance_edges(s)
  return s:gsub(GRAPH_PATTERN, GRAPH_CHAR)
end

function M.open(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  local popup = session and session.popup
  if not session or not session.git_root or not popup or popup.closing then
    vim.notify("Repository graph requires a Git review popup", vim.log.levels.WARN)
    return
  end
  if popup.repository_busy then
    vim.notify("A repository action is still running", vim.log.levels.WARN)
    return
  end
  local handle = dialog.open(ctx, {
    title = "Git graph: reading HEAD", lines = { "Loading..." }, filetype = "codediff-graph",
    footer = "m merge   r rebase   c continue   a abort   R refresh   L more   q close",
  })
  vim.wo[handle.winid].wrap = false
  local rows, displayed_head, operation, more = {}, nil, nil, false
  local limit, generation = PAGE_SIZE, 0
  local function alive()
    return lifecycle.get_session(ctx.tabpage) == session and session.popup == popup and not popup.closing
      and popup.dialog == handle and vim.api.nvim_win_is_valid(handle.winid) and vim.api.nvim_buf_is_valid(handle.bufnr)
  end
  local function set_lines(lines)
    vim.bo[handle.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, lines)
    vim.bo[handle.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(handle.bufnr, graph_ns, 0, -1)
    for i, line in ipairs(lines) do
      local first_char = line:find("[^ │●╱╲─·|%*/\\_%.%-]")
      if first_char then
        vim.api.nvim_buf_set_extmark(handle.bufnr, graph_ns, i - 1, 0, { end_col = first_char - 1, hl_group = "Comment" })
      end
    end
    local config = vim.api.nvim_win_get_config(handle.winid)
    config.height = math.max(1, math.min(math.max(4, #lines), vim.o.lines - vim.o.cmdheight - 4))
    config.row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - config.height - 2) / 2))
    vim.api.nvim_win_set_config(handle.winid, config)
  end
  local function reload()
    if not alive() or popup.repository_busy then return end
    generation = generation + 1
    local request = generation
    local selected = rows[vim.api.nvim_win_get_cursor(handle.winid)[1]]
    rows, displayed_head, operation, more = {}, nil, nil, false
    set_lines({ "Loading..." })
    local function current() return alive() and generation == request end
    local function failed(err)
      if not current() then return end
      set_lines({ "Could not read repository graph:", vim.fn.strtrans(err), "", "R refresh   q close" })
      vim.notify(err, vim.log.levels.ERROR)
    end
    revision.get_head(session.git_root, function(head_err, head)
      if not current() then return end
      if head_err then failed(head_err); return end
      vim.api.nvim_win_set_config(handle.winid, { title = " Git graph: " .. vim.fn.strtrans(head.label) .. " " })
      actions.operation_state(session.git_root, function(state_err, state)
        if not current() then return end
        if state_err then failed(state_err); return end
        local args = {
          "log", "--graph", "--all", "--topo-order", "--decorate=short", "--no-color", "--no-show-signature",
          "--max-count=" .. (limit + 1), "--format=%x00%H%x00%h%x00%d%x00%s%x00",
        }
        -- Include detached HEAD even when no branch or tag reaches it.
        if head.oid then args[#args + 1] = head.oid end
        args[#args + 1] = "--"
        runner.run_async(args, { cwd = session.git_root, no_optional_locks = true }, vim.schedule_wrap(function(err, output)
          if not current() then return end
          if err then failed(err); return end
          local identity = head.ref and head.ref:gsub("^refs/heads/", "") or "detached HEAD"
          local lines = { "HEAD: " .. vim.fn.strtrans(identity) .. " @ " .. (head.oid or "unborn") }
          if state then
            lines[#lines + 1] = "In progress: " .. vim.fn.strtrans(state.kind .. (state.branch and " (" .. state.branch .. ")" or ""))
              .. ((state.kind == "merge" or state.kind == "rebase") and " — c continue / a abort" or "")
          end
          lines[#lines + 1] = ""
          local entries, count, selected_row = {}, 0, nil
          for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
            local edges, oid, short, decoration, subject = line:match("^(.-)%z(%x+)%z([^%z]*)%z([^%z]*)%z([^%z]*)%z$")
            if oid and (#oid == 40 or #oid == 64) then
              count = count + 1
              if count > limit then more = true; break end
              local name = short .. decoration .. " " .. subject
              lines[#lines + 1] = enhance_edges(edges) .. vim.fn.strtrans(name)
              entries[#lines] = { oid = oid, name = name }
              if selected and selected.oid == oid then selected_row = #lines end
            elseif not line:find("\0", 1, true) then
              lines[#lines + 1] = enhance_edges(line)
            end
          end
          if count == 0 then lines[#lines + 1] = "No commits yet (unborn history)." end
          if more then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "L: load " .. PAGE_SIZE .. " more commits"
          end
          rows, displayed_head, operation = entries, head, state
          set_lines(lines)
          if selected_row then vim.api.nvim_win_set_cursor(handle.winid, { selected_row, 0 }) end
        end))
      end)
    end)
  end
  local function integrate(kind)
    if not alive() or popup.repository_busy or not displayed_head then return end
    local entry = rows[vim.api.nvim_win_get_cursor(handle.winid)[1]]
    if entry then actions.integrate(ctx, displayed_head, entry, kind) end
  end
  local function resume(action)
    if not alive() or popup.repository_busy or not displayed_head or not operation then return end
    if operation.kind == "merge" or operation.kind == "rebase" then actions.resume(ctx, displayed_head, operation, action) end
  end
  local function map(key, callback, desc)
    vim.keymap.set("n", key, callback, { buffer = handle.bufnr, silent = true, nowait = true, desc = desc })
  end
  map("m", function() integrate("merge") end, "Merge selected commit")
  map("r", function() integrate("rebase") end, "Rebase onto selected commit")
  map("c", function() resume("continue") end, "Continue repository operation")
  map("a", function() resume("abort") end, "Abort repository operation")
  map("R", reload, "Refresh repository graph")
  map("L", function()
    if more then limit = limit + PAGE_SIZE; reload() end
  end, "Load more history")
  reload()
  return handle
end

return M
