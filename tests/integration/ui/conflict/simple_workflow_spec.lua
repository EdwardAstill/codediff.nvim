local h = require('tests.support')
local repos = require('tests.support.repository')
local lifecycle = require('codediff.ui.lifecycle')
local tracking = require('codediff.ui.conflict.tracking')
h.ensure_plugin_loaded()
local function eventually(fn) assert.is_true(vim.wait(10000, fn, 20)) end
local function invoke(buf, key)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == key then map.callback(); return end
  end
  error('missing key ' .. key)
end
describe('Popup resolve before staging', function()
  local repo, session, notify
  before_each(function()
    lifecycle.cleanup_all()
    require('codediff').setup({explorer={auto_refresh=false,auto_open_on_cursor=false}})
    notify=vim.notify;vim.notify=function()end
    repo=repos.new({key='simple-resolver',build=function(r)
      r.write_file('file.txt',{'base'});return {base=r.commit('base')}
    end})
    repo.command({'checkout','-b','topic'});repo.write_file('file.txt',{'incoming'});repo.commit('topic')
    repo.command({'checkout','main'});repo.write_file('file.txt',{'current'});repo.commit('main')
    repo.command({'merge','--no-edit','topic'},1)
    vim.cmd('edit '..vim.fn.fnameescape(repo.path('file.txt')))
    vim.cmd('CodeDiff')
    eventually(function()
      session=lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      return session and session.result_bufnr and session.conflict_blocks and #session.conflict_blocks>0
        and session.refresh and not session.refresh.loading and not session.refresh.running
    end)
  end)
  after_each(function()
    lifecycle.cleanup_all();vim.notify=notify
    for _,buf in ipairs(vim.api.nvim_list_bufs())do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1,#repo.root)==repo.root then vim.api.nvim_buf_delete(buf,{force=true})end
    end
    h.close_extra_tabs();repo.cleanup()
  end)
  local function row(group)
    local pane=session.panel.view.panes[1]
    for line=1,vim.api.nvim_buf_line_count(pane.bufnr)do
      local node=pane.tree:get_node(line)
      if node and node.data.path=='file.txt' and node.data.group==group then
        vim.api.nvim_set_current_win(pane.winid);vim.api.nvim_win_set_cursor(pane.winid,{line,0});return pane
      end
    end
    error('missing file in '..group)
  end
  local function accept()
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win,{1,0})
    require('codediff.ui.conflict.resolution').accept_incoming(session.tabpage)
  end
  it('refuses r before every block is accepted without changing the index',function()
    local before=repo.command({'ls-files','--unmerged'})
    local pane=row('conflicts');invoke(pane.bufnr,'r')
    assert.equals(before,repo.command({'ls-files','--unmerged'}))
    assert.equals(1,#session.panel.data.status_result.conflicts)
    assert.equals(1,tracking.unresolved_count(session))
  end)
  it('saves accepted content into Changes while retaining unmerged stages until s',function()
    local before=repo.command({'ls-files','--unmerged'})
    accept();local pane=row('conflicts');invoke(pane.bufnr,'r')
    eventually(function()return #session.panel.data.status_result.conflicts==0 and #session.panel.data.status_result.unstaged==1 and not session.refresh.loading and not session.refresh.running end)
    assert.same({'incoming'},repo.read_file('file.txt'))
    assert.equals(before,repo.command({'ls-files','--unmerged'}))
    assert.equals(0,#session.panel.data.status_result.staged)
    pane=row('unstaged');invoke(pane.bufnr,'s')
    eventually(function()return repo.command({'ls-files','--unmerged'})=='' end)
    assert.equals('incoming\n',repo.blob(':0','file.txt'))
    assert.equals(1,vim.fn.filereadable(repo.git_path('MERGE_HEAD')))
  end)
  it('returns an edited resolution to Merge Changes rather than treating it as approved',function()
    accept();invoke(row('conflicts').bufnr,'r')
    eventually(function()return #session.panel.data.status_result.unstaged==1 and not session.refresh.loading end)
    local buf=vim.fn.bufnr(repo.path('file.txt'))
    vim.api.nvim_buf_set_lines(buf,0,-1,false,{'new manual edit'})
    require('codediff.ui.refresh').request(session.tabpage,{full=true})
    eventually(function()return #session.panel.data.status_result.conflicts==1 end)
    assert.is_not.equals('',repo.command({'ls-files','--unmerged'}))
    assert.same({'incoming'},repo.read_file('file.txt'))
  end)
end)
