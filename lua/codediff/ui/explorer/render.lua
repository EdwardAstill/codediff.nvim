-- Explorer presentation. Repository data and file selection belong to the session.
local M = {}
local Tree = require("codediff.ui.lib.tree")
local Split = require("codediff.ui.lib.split")
local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local nodes_module = require("codediff.ui.explorer.nodes")
local tree_module = require("codediff.ui.explorer.tree")
local keymaps_module = require("codediff.ui.explorer.keymaps")

function M.create(data, tabpage, width)
  local options = config.options.explorer or {}
  local session = lifecycle.get_session(tabpage)
  local popup = session and session.popup
  local position = options.position or "left"
  local size = position == "bottom" and (options.height or 15) or (width or options.width or 40)
  local win_options = {
    number = false, relativenumber = false, cursorline = true, wrap = false,
    signcolumn = "no", foldcolumn = "0", statuscolumn = "", spell = false,
    winfixwidth = true, winfixheight = true, scrollbind = false, cursorbind = false,
  }
  local explorer = {
    data = data,
    tabpage = tabpage,
    is_hidden = options.hidden,
    visible_groups = vim.deepcopy(options.visible_groups or { staged = true, unstaged = true, conflicts = true }),
  }
  explorer.on_file_select = function(file, opts)
    return require("codediff.ui.refresh").select(tabpage, file, opts)
  end
  if popup then
    explorer.group = "unstaged"
    explorer.view_mode = "tree"
    explorer.panes = { explorer, {
      root = explorer, data = data, tabpage = tabpage, group = "staged", view_mode = "tree",
      visible_groups = explorer.visible_groups, on_file_select = explorer.on_file_select,
    } }
  end

  for _, pane in ipairs(explorer.panes or { explorer }) do
    if popup then
      pane.bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[pane.bufnr].bufhidden = "hide"
      vim.bo[pane.bufnr].filetype = "codediff-explorer"
      vim.bo[pane.bufnr].modifiable = false
      vim.bo[pane.bufnr].readonly = true
      if not explorer.is_hidden then
        pane.winid = vim.api.nvim_open_win(pane.bufnr, false, require("codediff.ui.popup").geometry()[pane.group])
        for name, value in pairs(win_options) do
          vim.wo[pane.winid][name] = value
        end
      end
    else
      pane.split = Split({
        relative = "editor", position = position, size = size,
        buf_options = { modifiable = false, readonly = true, filetype = "codediff-explorer" },
        win_options = win_options,
      })
      pane.split:mount()
      if options.hidden then
        pane.split:hide()
      end
      pane.bufnr, pane.winid = pane.split.bufnr, pane.split.winid
    end
    pcall(vim.api.nvim_buf_set_name, pane.bufnr, "CodeDiff Explorer " .. (pane.group or "") .. " [" .. tabpage .. "]")
    local tree_data = tree_module.pane_data(pane)
    pane.tree = Tree({
      bufnr = pane.bufnr,
      nodes = tree_data,
      prepare_node = function(node)
        local current_width = pane.winid and vim.api.nvim_win_is_valid(pane.winid) and vim.api.nvim_win_get_width(pane.winid) or size
        local selected = pane.data.current_selection or {}
        return nodes_module.prepare_node(node, current_width, selected.path, selected.group)
      end,
    })
    for _, node in ipairs(tree_data) do
      if popup or options.view_mode == "tree" then
        node:expand_recursively()
      else
        node:expand()
      end
    end
    pane.tree:render()
    keymaps_module.setup(pane)

    if options.auto_open_on_cursor then
      for _, key in ipairs({ "j", "k", "<Down>", "<Up>" }) do
        lifecycle.set_buf_keymap(tabpage, pane.bufnr, "n", key, function()
          vim.cmd("normal! " .. (key == "<Down>" and "j" or key == "<Up>" and "k" or key))
          local node = pane.tree:get_node()
          if not node or not node.data or node.data.type then
            return
          end
          local selected = pane.data.current_selection or {}
          if selected.path ~= node.data.path or selected.group ~= node.data.group then
            pane.on_file_select(node.data)
          end
        end, { silent = true, desc = "codediff: move and auto-open file" }, { suspendable = false })
      end
    end
  end

  explorer.on_data = function(value, changes)
    for _, pane in ipairs(explorer.panes or { explorer }) do
      pane.data = value
    end
    if changes.list then
      tree_module.rebuild(explorer)
    elseif changes.selection and not explorer.is_hidden then
      for _, pane in ipairs(explorer.panes or { explorer }) do
        pane.tree:render()
      end
    end
  end

  local files = tree_module.get_pane_files(explorer)
  local initial_file = files[1]
  if data.focus_file then
    for _, file in ipairs(files) do
      if file.data.path == data.focus_file then
        initial_file = file
        break
      end
    end
  end
  if initial_file then
    vim.schedule(function()
      if lifecycle.get_panel_view(tabpage) ~= explorer then
        return
      end
      local pane = initial_file.pane
      if pane.winid and vim.api.nvim_win_is_valid(pane.winid) and initial_file.node._line then
        vim.api.nvim_win_set_cursor(pane.winid, { initial_file.node._line, 0 })
      end
      explorer.on_file_select(initial_file.data)
    end)
  end

  vim.api.nvim_create_autocmd("WinResized", {
    group = vim.api.nvim_create_augroup("codediff_lifecycle_tab_" .. tabpage, { clear = false }),
    callback = function()
      for _, pane in ipairs(explorer.panes or { explorer }) do
        if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
          pane.tree:render()
        end
      end
    end,
  })
  return explorer
end

return M
