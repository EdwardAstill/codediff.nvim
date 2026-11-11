-- Floating help window showing available keymaps (g?)
local config = require("codediff.config")
local normalize = require("codediff.keymap.normalize")
local resolve = require("codediff.keymap.resolve")
local lifecycle = require("codediff.ui.lifecycle")

local M = {}

local ns = vim.api.nvim_create_namespace("codediff-help")

-- Key column width (right-aligned keys sit in this space)
local KEY_COL = 14
-- Double click, bound by the explorer and history panels. Not configurable.
local MOUSE_SELECT = "<2-LeftMouse>"
-- Inter-column gap for two-column layout. Plain whitespace — no divider glyph.
local COL_SEP = "    "

-- Setup highlight groups for the help window
local function setup_highlights()
  vim.api.nvim_set_hl(0, "CodeDiffHelpHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffHelpSection", { link = "Statement", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffHelpKey", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffHelpSep", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffHelpDesc", { link = "Normal", default = true })
end

--- Entry = { key, desc } or nil (skipped)
--- Section = { title, entries[] }

-- Collect a section of keymap entries, keeping only keys the session actually
-- has mapped. `is_bound` is what stops this list from drifting: an entry that
-- is disabled in config, or not applicable to the current session shape, is
-- simply not installed and therefore not advertised.
--
-- An action can answer to several keys, so every key really bound is listed.
local function section(title, entries, is_bound)
  local items = {}
  for _, e in ipairs(entries) do
    local bound = vim.tbl_filter(is_bound, normalize.key_list(e[1]))
    if #bound > 0 then
      table.insert(items, { table.concat(bound, " / "), e[2] })
    end
  end
  if #items == 0 then
    return nil
  end
  return { title = title, items = items }
end

-- Build sections for the current session.
--
-- Section inclusion follows the session shape (a standalone diff has no
-- explorer panel). Entry inclusion follows what is actually installed, so a
-- key that is disabled in config, or not applicable to the current view, is
-- never advertised. `is_bound` is what keeps this list from drifting.
local function build_sections(keymaps, is_bound, shape)
  local sections = {}
  local km = keymaps.view

  table.insert(
    sections,
    section("VIEW", {
      { km.quit, "Close diff workspace" },
      { "<Tab>", "Focus next popup pane" },
      { "<S-Tab>", "Focus previous popup pane" },
      { km.next_hunk, "Next hunk" },
      { km.prev_hunk, "Previous hunk" },
      { km.diff_get, "Get change from other buffer" },
      { km.diff_put, "Put change to other buffer" },
      { km.open_in_prev_tab, "Open file outside diff" },
      { km.next_file, "Next file" },
      { km.prev_file, "Previous file" },
      { km.toggle_explorer, "Toggle explorer" },
      { km.focus_explorer, "Focus explorer" },
      { km.toggle_stage, "Stage/unstage file or folder" },
      { km.toggle_staged_view, "Toggle staged/unstaged view for current file" },
      { km.stage_hunk, "Stage hunk under cursor" },
      { km.unstage_hunk, "Unstage hunk under cursor" },
      { km.revert_hunk, "Revert hunk to comparison baseline" },
      { "o", "Send hunk to OMP draft" },
      { km.toggle_layout, "Toggle inline/side-by-side layout" },
      { km.align_move, "Align moved code block" },
      { km.toggle_compact, "Toggle compact mode (fold unchanged)" },
      { km.hunk_textobject, "Hunk textobject (visual/operator)" },
      { km.show_help, "Toggle this help" },
    }, is_bound)
  )

  if shape.explorer then
    local ekm = keymaps.explorer
    table.insert(
      sections,
      section("EXPLORER", {
        { ekm.select, "Select / toggle expand" },
        { MOUSE_SELECT, "Select file (double click)" },
        { "j", "Move down / auto-open file" },
        { "k", "Move up / auto-open file" },
        { "<Down>", "Move down / auto-open file" },
        { "<Up>", "Move up / auto-open file" },
        { ekm.hover, "Show full path" },
        { ekm.refresh, "Refresh explorer" },
        { ekm.toggle_view_mode, "Toggle list/tree view" },
        { ekm.stage_all, "Stage all files" },
        { ekm.unstage_all, "Unstage all files" },
        { ekm.restore, "Discard changes to file" },
        { ekm.toggle_changes, "Toggle Changes visibility" },
        { ekm.toggle_staged, "Toggle Staged visibility" },
        { ekm.fold_open, "Open fold" },
        { ekm.fold_open_recursive, "Open fold recursively" },
        { ekm.fold_close, "Close fold" },
        { ekm.fold_close_recursive, "Close fold recursively" },
        { ekm.fold_toggle, "Toggle fold" },
        { ekm.fold_toggle_recursive, "Toggle fold recursively" },
        { ekm.fold_open_all, "Open all folds" },
        { ekm.fold_close_all, "Close all folds" },
      }, is_bound)
    )
  end

  if shape.history then
    local hkm = keymaps.history
    table.insert(
      sections,
      section("HISTORY", {
        { hkm.select, "Select commit/file or toggle" },
        { MOUSE_SELECT, "Select commit/file (double click)" },
        { hkm.toggle_view_mode, "Toggle list/tree view" },
        { hkm.refresh, "Refresh history" },
        { hkm.fold_open, "Open fold" },
        { hkm.fold_open_recursive, "Open fold recursively" },
        { hkm.fold_close, "Close fold" },
        { hkm.fold_close_recursive, "Close fold recursively" },
        { hkm.fold_toggle, "Toggle fold" },
        { hkm.fold_toggle_recursive, "Toggle fold recursively" },
        { hkm.fold_open_all, "Open all folds" },
        { hkm.fold_close_all, "Close all folds" },
      }, is_bound)
    )
  end

  if shape.conflict then
    local ckm = keymaps.conflict
    table.insert(
      sections,
      section("CONFLICT", {
        { ckm.accept_incoming, "Accept incoming (theirs)" },
        { ckm.accept_current, "Accept current (ours)" },
        { ckm.accept_both, "Accept both changes" },
        { ckm.discard, "Discard both (keep base)" },
        { ckm.accept_all_incoming, "Accept ALL incoming" },
        { ckm.accept_all_current, "Accept ALL current" },
        { ckm.accept_all_both, "Accept ALL both" },
        { ckm.discard_all, "Discard ALL (reset to base)" },
        { ckm.next_conflict, "Next conflict" },
        { ckm.prev_conflict, "Previous conflict" },
        { ckm.diffget_incoming, "Get hunk from incoming" },
        { ckm.diffget_current, "Get hunk from current" },
      }, is_bound)
    )
  end

  return sections
end

-- Compute the required column width for one group of sections
local function group_width(sections)
  local max_desc, key_width = 0, KEY_COL
  for _, sec in ipairs(sections) do
    for _, item in ipairs(sec.items) do
      max_desc = math.max(max_desc, vim.fn.strdisplaywidth(item[2]))
      key_width = math.max(key_width, vim.fn.strdisplaywidth(item[1]))
    end
  end
  -- Keys + separator + descriptions + padding.
  return math.max(key_width + 3 + max_desc + 3, 40), key_width
end

-- Compute the required window width from sections (single-column layout)
local function compute_width(sections)
  return group_width(sections)
end

-- Render one group of sections into vertical lines (no column composition).
-- Returns lines (string[]) and hls ({ line, col_start, col_end, hl_group }[]),
-- with all offsets in bytes so nvim_buf_add_highlight can consume them directly.
local function render_group(sections, col_width, key_width)
  local lines = {}
  local hls = {}

  for sec_idx, sec in ipairs(sections) do
    if sec_idx > 1 then
      table.insert(lines, "")
    end

    -- Section heading (centered)
    local pad = math.max(0, math.floor((col_width - #sec.title) / 2))
    local heading = string.rep(" ", pad) .. sec.title
    table.insert(lines, heading)
    table.insert(hls, { #lines - 1, pad, pad + #sec.title, "CodeDiffHelpSection" })

    -- Column header
    local col_hdr = string.format("%" .. key_width .. "s    %s", "KEYS", "ACTION")
    table.insert(lines, col_hdr)
    table.insert(hls, { #lines - 1, 0, #col_hdr, "CodeDiffHelpSep" })

    -- Entries
    for _, item in ipairs(sec.items) do
      local key, desc = item[1], item[2]
      local key_str = string.rep(" ", key_width - vim.fn.strdisplaywidth(key)) .. key
      local line = key_str .. " → " .. desc
      table.insert(lines, line)
      local row = #lines - 1
      local desc_start = #key_str + #" → "
      table.insert(hls, { row, 0, #key_str, "CodeDiffHelpKey" })
      table.insert(hls, { row, #key_str, desc_start, "CodeDiffHelpSep" })
      table.insert(hls, { row, desc_start, #line, "CodeDiffHelpDesc" })
    end
  end

  return lines, hls
end

-- Split sections into two column groups (heuristic: first section left, rest right).
-- In practice we ever have at most 2 sections (VIEW + one of EXPLORER/HISTORY/CONFLICT),
-- so this maps to VIEW on the left and the mode-specific section on the right.
local function split_two_col(sections)
  local left = { sections[1] }
  local right = {}
  for i = 2, #sections do
    table.insert(right, sections[i])
  end
  return left, right
end

-- Compose two rendered column groups into a single (lines, hls, total_width) tuple.
-- Both column widths are per-group; horizontal padding on the left column and
-- byte-offset shifting on the right column keep highlights aligned.
local function compose_two_col(left_sections, right_sections)
  local left_w, left_key_width = group_width(left_sections)
  local right_w, right_key_width = group_width(right_sections)
  local left_lines, left_hls = render_group(left_sections, left_w, left_key_width)
  local right_lines, right_hls = render_group(right_sections, right_w, right_key_width)

  local n = math.max(#left_lines, #right_lines)
  local sep_bytes = #COL_SEP
  local sep_display = vim.fn.strdisplaywidth(COL_SEP)

  local lines = {}
  -- Precompute the byte offset where each row's right column starts, so we
  -- can shift right-column highlights into the merged coordinate space.
  local right_col_byte_offset = {}
  for i = 1, n do
    local L = left_lines[i] or ""
    local R = right_lines[i] or ""
    local L_display = vim.fn.strdisplaywidth(L)
    local pad = math.max(0, left_w - L_display)
    local padded_L = L .. string.rep(" ", pad)
    lines[i] = padded_L .. COL_SEP .. R
    right_col_byte_offset[i] = #padded_L + sep_bytes
  end

  local hls = {}
  -- Left column highlights: byte offsets already correct for the merged line.
  for _, hl in ipairs(left_hls) do
    table.insert(hls, hl)
  end
  -- Right column highlights: shift col offsets by that row's right start.
  for _, hl in ipairs(right_hls) do
    local off = right_col_byte_offset[hl[1] + 1] or 0
    table.insert(hls, { hl[1], hl[2] + off, hl[3] + off, hl[4] })
  end

  local total_width = left_w + sep_display + right_w
  return lines, hls, total_width
end

local review_help

local function toggle_review_help(tabpage, session)
  local handle = session and session.popup.dialog or (not session and review_help)
  if handle and vim.api.nvim_win_is_valid(handle.winid) and vim.bo[handle.bufnr].filetype == "codediff-help" then
    handle.close()
    review_help = nil
    return
  end
  local sections = {
    { title = "REVIEW WORKSPACE", items = {
      { "q / <C-q>", "Close review" },
      { "<Tab> / <S-Tab>", "Next / previous pane" },
      { "i / k", "Move up / down" },
      { "[ / ]", "Previous / next hunk" },
      { "c", "Commit staged changes (edit message)" },
      { "z", "Stash tracked changes (confirmation)" },
      { "b / w", "List local branches / worktrees" },
      { "h / <C-s> / <C-S-s>", "Help (:CodeDiff help also works)" },
    } },
    { title = "CHANGE TREES", items = {
      { "<Up> / <Down>", "Move up / down (same as i / k)" },
      { "<CR> / <2-LeftMouse>", "Select file / toggle folder" },
      { "j / l", "Collapse / expand folder or select file" },
      { "s", "Stage / unstage selected file or folder" },
      { "S / U", "Stage / unstage all files" },
    } },
    { title = "DIFF PANES", items = {
      { "j / l", "Move left / right" },
      { "s", "Stage / unstage hunk under cursor" },
      { "r", "Revert hunk to left baseline (y confirms)" },
      { "o", "Send hunk to OMP draft (optional message)" },
    } },
  }
  local width, key_width = compute_width(sections)
  local lines, hls = render_group(sections, math.min(width, 88), key_width)
  vim.list_extend(lines, {
    "",
    " Revert restores the file; unstage changes only Git's index.",
    " Revert/stash refuse unsaved files. Save outside review first.",
    " OMP: Ctrl-s adds hunk + message to draft; Ctrl-q cancels.",
  })
  setup_highlights()
  handle = require("codediff.ui.dialog").open({ tabpage = tabpage }, {
    title = "Review help", lines = lines, filetype = "codediff-help",
    footer = "h/q/Esc/Ctrl-q close",
  })
  review_help = handle
  vim.keymap.set("n", "h", handle.close, { buffer = handle.bufnr, nowait = true })
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(handle.bufnr, ns, hl[4], hl[1], hl[2], hl[3])
  end
end

--- Show or toggle the keymap help floating window
function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or session.popup then
    toggle_review_help(tabpage, session)
    return
  end

  -- Close existing help window if open
  if session and session._help_win and vim.api.nvim_win_is_valid(session._help_win) then
    vim.api.nvim_win_close(session._help_win, true)
    session._help_win = nil
    return
  end

  setup_highlights()

  local keymaps = resolve.all_keymaps()
  local function is_bound(key)
    return lifecycle.owns_keymap(tabpage, key)
  end

  local shape = {
    explorer = session and session.panel ~= nil and session.panel.name == "explorer" or false,
    history = session and session.panel ~= nil and session.panel.name == "history" or false,
    conflict = session and session.merge == true or false,
  }

  local sections = build_sections(keymaps, is_bound, shape)

  -- Prefer a two-column layout when there are 2+ sections and it fits on screen.
  -- Falls back to a single column when the terminal is too narrow.
  local lines, hls, win_width
  local max_editor_width = math.max(vim.o.columns - 4, 40)
  if #sections >= 2 then
    local left, right = split_two_col(sections)
    local two_lines, two_hls, two_w = compose_two_col(left, right)
    if two_w <= max_editor_width then
      lines, hls, win_width = two_lines, two_hls, two_w
    end
  end
  if not lines then
    local key_width
    win_width, key_width = compute_width(sections)
    lines, hls = render_group(sections, win_width, key_width)
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codediff-help"

  -- Apply highlights
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl[4], hl[1], hl[2], hl[3])
  end

  -- Open centered floating window
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - win_width) / 2),
    width = win_width,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 90,
    title = " Keymaps ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat"

  -- Track window in session for toggle
  if session then
    session._help_win = win
  end

  -- The popup takes focus, so it carries its own close keys: q, Esc, and
  -- whatever opened it, so that key toggles it shut again.
  local close_keys = vim.list_extend({ "h", "q", "<Esc>", "<C-q>" }, normalize.key_list(keymaps.view.show_help))
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if session then
        session._help_win = nil
      end
    end, { buffer = buf, nowait = true })
  end
end

return M
