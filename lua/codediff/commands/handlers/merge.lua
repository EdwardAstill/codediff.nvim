-- :CodeDiff merge <file> -- validated four-pane merge review.
local M = {}

local git = require("codediff.core.git")
local view = require("codediff.ui.view")
local path = require("codediff.core.path")

function M.run(opts, global_opts)
  global_opts = global_opts or {}
  local function fail(message)
    vim.notify(message, vim.log.levels.ERROR)
    if global_opts.exit_on_close then
      vim.cmd("cquit")
    end
  end
  local args = opts.fargs
  if #args == 0 then
    fail("Usage: :CodeDiff merge <filename>")
    return
  end

  local filename = args[1]
  -- Strip surrounding quotes if present (from shell escaping in git mergetool)
  filename = filename:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")

  -- Resolve to absolute path
  local full_path = vim.fn.fnamemodify(filename, ":p")

  if vim.fn.filereadable(full_path) == 0 then
    fail("Cannot read working file " .. filename .. "; resolve missing/deleted paths with Git outside CodeDiff")
    return
  end

  -- Ensure all required modules are loaded before we start vim.wait
  -- This prevents issues with lazy-loading during the wait loop

  -- For synchronous execution (required by git mergetool), we need to block
  -- until the view is ready. Use vim.wait which processes the event loop.
  local view_ready = false
  local error_msg = nil

  git.get_git_root(full_path, function(err_root, git_root)
    if err_root then
      error_msg = "Not a git repository: " .. err_root
      view_ready = true
      return
    end

    local relative_path = git.get_relative_path(full_path, git_root)

    git.get_status_with_line_stats(git_root, function(status_err, status)
      if status_err then
        error_msg = "Cannot read merge status: " .. status_err
        view_ready = true
        return
      end
      git.get_merge_inputs(git_root, relative_path, function(input_err, inputs)
        vim.schedule(function()
          if view_ready then
            return
          end
          if input_err then
            error_msg = input_err
            view_ready = true
            return
          end
          local filetype = vim.filetype.match({ filename = full_path }) or ""
          ---@type SessionConfig
          local session_config = {
            panel = {
              name = "explorer",
              data = { status_result = status, focus_file = relative_path, pathspec = { relative_path } },
            },
            git_root = git_root,
            original = path.make_ref(relative_path, git_root),
            modified = path.make_ref(relative_path, git_root),
            original_revision = ":3",
            modified_revision = ":2",
            conflict = true,
            merge_inputs = inputs,
            exit_on_close = global_opts.exit_on_close,
          }
          view.create(session_config, filetype, function(_, err)
            error_msg, view_ready = err, true
          end)
        end)
      end)
    end, { relative_path })
  end)

  -- Block until view is ready - this allows event loop to process callbacks
  vim.wait(10000, function()
    return view_ready
  end, 10)
  if not view_ready then
    view_ready = true
    error_msg = "Timed out loading merge inputs; check Git and retry :CodeDiff merge"
  end

  -- Force screen redraw after vim.wait to ensure all windows are visible
  vim.cmd("redraw!")

  if error_msg then
    fail(error_msg)
  end
end

-- ── Command tree (argparse) ────────────────────────────────────────────────
-- The :CodeDiff grammar is declared once as an argparse Command tree. The
-- handlers reproduce the previous dispatch exactly; revision/file/dir and
-- triple-dot detection stays in the handlers because it touches the filesystem.

-- Translate global flags into the { layout, exit_on_close } table handlers expect.

return M
