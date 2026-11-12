-- Unmerged index validation shared by merge views and index mutations.
local M = {}

local runner = require("codediff.core.git.runner")
local path = require("codediff.core.path")

local function parse_entries(output)
  local files = {}
  for record in output:gmatch("[^%z]+") do
    local mode, oid, stage, name = record:match("^(%d+) (%x+) ([123])\t(.+)$")
    if not name then
      return nil, "Cannot parse unmerged index entries; refresh the repository and retry"
    end
    files[name] = files[name] or { stages = {} }
    files[name].stages[tonumber(stage)] = { mode = mode, oid = oid }
  end
  for _, file in pairs(files) do
    local identity = {}
    for stage = 1, 3 do
      local entry = file.stages[stage]
      identity[stage] = entry and (entry.mode .. " " .. entry.oid) or "-"
    end
    file.identity = table.concat(identity, ":")
  end
  return files
end

local function unmerged_args(paths)
  local args = { "--literal-pathspecs", "ls-files", "--unmerged", "-z", "--" }
  vim.list_extend(args, type(paths) == "string" and { paths } or paths or {})
  return args
end

local function read_unmerged_now(git_root, paths)
  local ok, result = pcall(function()
    local args = vim.list_extend({ "git", "--no-optional-locks" }, unmerged_args(paths))
    return vim.system(args, { cwd = git_root, text = false }):wait()
  end)
  if not ok or result.code ~= 0 then
    return nil, "Cannot read unmerged index: " .. (ok and result.stderr or tostring(result))
  end
  return parse_entries(result.stdout or "")
end

function M.get_unmerged(git_root, paths, callback)
  runner.run_async(unmerged_args(paths), { cwd = git_root, no_optional_locks = true }, function(err, output)
    if err then
      callback("Cannot read unmerged index: " .. err)
      return
    end
    local files, parse_err = parse_entries(output)
    callback(parse_err, files)
  end)
end

-- Re-read Git at the asynchronous mutation boundary, not the explorer's cached group.
function M.before_mutation(git_root, paths, allow_resolved, callback)
  vim.schedule(function()
    local files, err = read_unmerged_now(git_root, paths)
    if err then
      callback(err)
      return
    end
    local tracking = require("codediff.ui.conflict.tracking")
    for name, file in pairs(files) do
      local absolute = path.make_ref(name, git_root).absolute
      local state_err = tracking.stage_error(absolute)
      if state_err then
        callback(name .. ": " .. state_err)
        return
      end
      local state = tracking.get_state(absolute)
      if not state or state.merge_input_identity ~= file.identity then
        callback(name .. ": merge inputs changed; reopen the merge view and review the current conflict before staging")
        return
      end
      if not allow_resolved then
        callback(name .. ": unmerged files cannot be patched or reset; save and stage the explicitly resolved whole file")
        return
      end
    end
    callback(nil)
  end)
end

function M.get_merge_inputs(git_root, relative_path, callback)
  M.get_unmerged(git_root, relative_path, function(err, files)
    if err then
      callback(err)
      return
    end
    local file = files[relative_path]
    if not file then
      callback(relative_path .. " is not an unmerged file; use :CodeDiff file for an ordinary diff")
      return
    end
    require("codediff.core.git.changes").get_status(git_root, function(status_err, status)
      if status_err then
        callback("Cannot read merge status: " .. status_err)
        return
      end
      local kind
      for _, entry in ipairs(status.conflicts) do
        if entry.path == relative_path then
          kind = entry.conflict_type
          break
        end
      end
      local stages = file.stages
      if (kind ~= "UU" and kind ~= "AA") or not stages[2] or not stages[3] or (not stages[1] and kind ~= "AA") then
        callback("Unsupported rename/delete conflict for " .. relative_path .. "; resolve its paths with Git outside CodeDiff")
        return
      end
      for _, entry in pairs(stages) do
        if entry.mode ~= "100644" and entry.mode ~= "100755" then
          callback("Unsupported symlink/submodule conflict for " .. relative_path .. "; resolve it with Git outside CodeDiff")
          return
        end
      end
      if stages[2].mode ~= stages[3].mode then
        callback("Unsupported file-mode conflict for " .. relative_path .. "; resolve its permissions with Git outside CodeDiff")
        return
      end
      local inputs = { identity = file.identity }
      local keys = { "base_lines", "current_lines", "incoming_lines" }
      local function load(stage)
        if stage == 4 then
          vim.schedule(function()
            local current, check_err = read_unmerged_now(git_root, relative_path)
            if check_err then
              callback(check_err)
            elseif not current[relative_path] or current[relative_path].identity ~= inputs.identity then
              callback("Merge inputs changed while loading " .. relative_path .. "; retry :CodeDiff merge")
            else
              local absolute = path.make_ref(relative_path, git_root).absolute
              local stat = (vim.uv or vim.loop).fs_lstat(absolute)
              local working = stat and stat.type == "file" and io.open(absolute, "rb") or nil
              if not working then
                callback("Cannot read regular working file " .. relative_path .. "; resolve missing/deleted paths with Git outside CodeDiff")
                return
              end
              local bytes = working:read("*a")
              working:close()
              if not bytes then
                callback("Cannot read working file " .. relative_path)
              elseif bytes:find("\0", 1, true) then
                callback("Unsupported binary conflict for " .. relative_path .. "; use a binary merge tool")
              else
                callback(nil, inputs)
              end
            end
          end)
          return
        end
        if not stages[stage] then
          -- An add/add conflict has no ancestor; an actual read failure is never empty Base.
          inputs[keys[stage]] = {}
          load(stage + 1)
          return
        end
        runner.run_async({ "cat-file", "blob", stages[stage].oid }, { cwd = git_root }, function(read_err, output)
          if read_err then
            callback("Cannot read merge stage " .. stage .. " for " .. relative_path .. ": " .. read_err)
            return
          end
          if output:find("\0", 1, true) then
            callback("Unsupported binary conflict for " .. relative_path .. "; use a binary merge tool")
            return
          end
          local lines = vim.split(output, "\n", { plain = true })
          if lines[#lines] == "" then
            table.remove(lines)
          end
          inputs[keys[stage]] = lines
          load(stage + 1)
        end)
      end
      load(1)
    end)
  end)
end

return M
