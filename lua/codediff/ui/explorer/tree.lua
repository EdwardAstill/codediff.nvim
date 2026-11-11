-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local line_stats = require("codediff.ui.explorer.line_stats")
local nodes = require("codediff.ui.explorer.nodes")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

local function create_group_node(label, name, files, children)
  return Tree.Node({
    text = string.format("%s (%d)", label, #files),
    data = {
      type = "group",
      name = name,
      label = label,
      file_count = #files,
      stats = line_stats.sum(files),
      files = files,
    },
  }, children)
end

-- Create tree data structure from git status result
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups, view_mode)
  local explorer_config = config.options.explorer or {}
  view_mode = view_mode or explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged")
  local staged_nodes = create_nodes(staged, git_root, "staged")
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes.
    -- `get_diff_revision(s)` and `dir.diff_directories` populate `unstaged`;
    -- `get_diff_staged` (--staged, #352) populates `staged`. Pick whichever
    -- has entries — no need for extra flags.
    if #staged > 0 then
      return {
        create_group_node("Staged Changes", "staged", staged, staged_nodes),
      }
    end
    return {
      create_group_node("Changes", "unstaged", unstaged, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 and visible_groups.conflicts ~= false then
      table.insert(tree_nodes, create_group_node("Merge Changes", "conflicts", conflicts, conflict_nodes))
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      table.insert(tree_nodes, create_group_node("Changes", "unstaged", unstaged, unstaged_nodes))
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      table.insert(tree_nodes, create_group_node("Staged Changes", "staged", staged, staged_nodes))
    end

    return tree_nodes
  end
end

function M.pane_data(explorer)
  local data = explorer.data
  local groups = explorer.visible_groups
  if explorer.group then
    groups = {
      unstaged = explorer.group == "unstaged" and groups.unstaged ~= false,
      staged = explorer.group == "staged" and groups.staged ~= false,
      conflicts = explorer.group == "unstaged" and groups.conflicts ~= false,
    }
  end
  return M.create_tree_data(data.status_result, data.git_root, data.base_revision, not data.git_root, groups, explorer.view_mode)
end

local function walk_collapsible(tree, visit)
  local function walk(node)
    if not node.data or node.data.type ~= "group" and node.data.type ~= "directory" then
      return
    end
    local key = (node.data.group or "") .. ":" .. (node.data.dir_path or node.data.path or node.data.name or "")
    if key then
      visit(node, key)
    end
    for _, id in ipairs(node:get_child_ids() or {}) do
      local child = tree:get_node(id)
      if child then
        walk(child)
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    walk(node)
  end
end

-- Rebuild from supplied data, retaining the user's tree presentation state.
function M.rebuild(explorer)
  local root = explorer.root or explorer
  for _, pane in ipairs(root.panes or { root }) do
    local data, tree = pane.data, pane.tree
    if data.status_result then
      local cursor = pane.winid and vim.api.nvim_win_is_valid(pane.winid) and vim.api.nvim_win_get_cursor(pane.winid)
      local selected = cursor and tree:get_node(cursor[1])
      selected = selected and selected.data
      local collapsed = {}
      walk_collapsible(tree, function(node, key)
        collapsed[key] = not node:is_expanded()
      end)
      tree:set_nodes(M.pane_data(pane))
      walk_collapsible(tree, function(node, key)
        if collapsed[key] then
          node:collapse()
        else
          node:expand()
        end
      end)
      if not root.is_hidden then
        tree:render()
        if selected and cursor then
          for line = 1, vim.api.nvim_buf_line_count(pane.bufnr) do
            local node = tree:get_node(line)
            local entry = node and node.data
            if entry and entry.type == selected.type and entry.group == selected.group
              and (entry.dir_path or entry.path or entry.name) == (selected.dir_path or selected.path or selected.name) then
              vim.api.nvim_win_set_cursor(pane.winid, { line, 0 })
              break
            end
          end
        end
      end
    end
  end
end

function M.get_all_files(tree)
  local files = {}
  local function collect(parent)
    if not parent:is_expanded() then
      return
    end
    for _, id in ipairs(parent:get_child_ids() or {}) do
      local node = tree:get_node(id)
      if node and node.data then
        if node.data.type == "directory" then
          collect(node)
        elseif not node.data.type then
          files[#files + 1] = { node = node, data = node.data }
        end
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    collect(node)
  end
  return files
end

function M.get_pane_files(explorer)
  local root = explorer.root or explorer
  local files = {}
  for _, pane in ipairs(root.panes or { root }) do
    for _, file in ipairs(M.get_all_files(pane.tree)) do
      file.pane = pane
      files[#files + 1] = file
    end
  end
  return files
end

return M
