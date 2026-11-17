-- Git process execution shared by the Git domain modules.
local M = {}

-- Run a git command asynchronously.
function M.run_async(args, opts, callback)
  opts = opts or {}

  local argv = { "git" }
  if opts.no_optional_locks then
    -- `--no-optional-locks` (git 2.15+) tells git to skip the *optional* index
    -- refresh that read-only queries perform, which takes `.git/index.lock`.
    -- Required locks (e.g. the one `git add` needs) are unaffected.
    --
    -- The explorer's fallback path polls status every 500ms. Without this, a
    -- poll landing while the user stages or discards a hunk owns index.lock
    -- just long enough to
    -- make the staging command fail with
    -- `Unable to create '.../.git/index.lock': File exists`.
    --
    -- `git status` and `git ls-files` honor it; `git diff` refreshes the index
    -- regardless, so it is passed there for intent and forward-compatibility
    -- only. Reads never fail on a contended lock either way — git falls back to
    -- not refreshing.
    table.insert(argv, "--no-optional-locks")
  end
  vim.list_extend(argv, args)

  -- On Windows, vim.system requires that cwd exists before running the command
  -- Validate the directory exists to provide a better error message
  if opts.cwd and vim.fn.isdirectory(opts.cwd) == 0 then
    callback("Directory does not exist: " .. opts.cwd, nil)
    return
  end

  vim.system(argv, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    if result.code == 0 then
      callback(nil, result.stdout or "")
    else
      callback(result.stderr or "Git command failed", nil)
    end
  end)
end

-- Run a git command synchronously.
-- Returns output lines or nil on error.
function M.run_sync(args, opts)
  opts = opts or {}
  local cmd = vim.list_extend({ "git" }, args)

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  return result
end

return M
