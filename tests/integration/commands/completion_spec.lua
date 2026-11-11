-- Completion queries use a deterministic fixture, not the checkout's refs.
local git = require("codediff.core.git")
local fixture = require("tests.fixtures.refresh_repo")
local h = require("tests.support")

describe("Command Completion", function()
  local repo, non_repo

  before_each(function()
    repo = fixture.new("history")
    repo.command({ "update-ref", "refs/remotes/origin/main", repo.second })
    non_repo = h.create_temp_dir()
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
    if non_repo then
      vim.fn.delete(non_repo, "rf")
    end
  end)

  describe("git.get_git_root_sync", function()
    it("Returns git root for valid directory", function()
      assert.equals(repo.dir, git.get_git_root_sync(repo.dir))
    end)

    it("Returns nil for non-git directory", function()
      assert.is_nil(git.get_git_root_sync(non_repo))
    end)

    it("Handles file path input", function()
      assert.equals(repo.dir, git.get_git_root_sync(repo.path("a.txt")))
    end)
  end)

  describe("git.get_rev_candidates", function()
    it("Returns empty table for nil git_root", function()
      assert.same({}, git.get_rev_candidates(nil))
    end)

    it("Returns HEAD refs for valid git repo", function()
      local candidates = git.get_rev_candidates(repo.dir)
      assert.is_true(vim.tbl_contains(candidates, "HEAD"))
      assert.is_true(vim.tbl_contains(candidates, "HEAD~1"))
    end)

    it("Returns branches for valid git repo", function()
      local candidates = git.get_rev_candidates(repo.dir)
      for _, branch in ipairs({ "main", "review/left", "review/right" }) do
        assert.is_true(vim.tbl_contains(candidates, branch), "missing fixture branch " .. branch)
      end
    end)

    it("Returns tags for valid git repo", function()
      local candidates = git.get_rev_candidates(repo.dir)
      for _, tag in ipairs({ "fixture/base", "fixture/one", "fixture/two" }) do
        assert.is_true(vim.tbl_contains(candidates, tag), "missing fixture tag " .. tag)
      end
    end)

    it("Returns remotes for valid git repo", function()
      assert.is_true(vim.tbl_contains(git.get_rev_candidates(repo.dir), "origin/main"))
    end)
  end)

end)
