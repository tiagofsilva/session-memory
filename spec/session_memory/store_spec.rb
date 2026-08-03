# frozen_string_literal: true

require "spec_helper"
require "fileutils"

RSpec.describe SessionMemory::Store do
  around do |example|
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |repo|
        @home = home
        @repo = repo
        ENV["SESSION_MEMORY_HOME"] = home
        system("git", "init", "-b", "feature/foo", repo, out: File::NULL, err: File::NULL)
        system("git", "-C", repo, "config", "user.email", "t@example.com", out: File::NULL)
        system("git", "-C", repo, "config", "user.name", "t", out: File::NULL)
        File.write(File.join(repo, "README"), "x")
        system("git", "-C", repo, "add", "README", out: File::NULL)
        system("git", "-C", repo, "commit", "-m", "init", out: File::NULL, err: File::NULL)
        example.run
      ensure
        ENV.delete("SESSION_MEMORY_HOME")
      end
    end
  end

  def store
    SessionMemory::Store.new(repo_root: @repo, root: @home)
  end

  describe "#branch_slug" do
    it "sanitizes separators and truncates" do
      expect(store.branch_slug("feature/foo_bar baz!")).to eq("feature-foo-bar-baz")
      expect(store.branch_slug("")).to eq("nobranch")
      expect(store.branch_slug("z" * 50).length).to eq(40)
    end
  end

  describe "#repo_name" do
    it "uses the toplevel basename" do
      expect(store.repo_name).to eq(File.basename(@repo))
    end
  end

  describe "#digest_path" do
    it "builds a dated repo-branch tagged path" do
      path = store.digest_path("abcd1234", time: Time.new(2020, 1, 2, 3, 4))
      expect(path).to eq(
        File.join(@home, "sessions", File.basename(@repo), "2020-01-02-0304-#{File.basename(@repo)}-feature-foo-abcd1234.digest.md"),
      )
    end

    it "reuses an existing session file matched by short id" do
      existing = store.digest_path("abcd1234", time: Time.new(2019, 5, 5, 9, 0))
      File.write(existing, "x")
      expect(store.digest_path("abcd1234", time: Time.new(2020, 1, 2))).to eq(existing)
    end
  end

  describe "#latest_digest" do
    it "returns the newest digest for the current repo and branch" do
      older = store.digest_path("aaaa1111", time: Time.new(2020, 1, 1))
      newer = store.digest_path("bbbb2222", time: Time.new(2020, 6, 1, 12))
      File.write(older, "x")
      File.write(newer, "x")
      other_dir = File.join(@home, "sessions", "otherrepo")
      FileUtils.mkdir_p(other_dir)
      File.write(File.join(other_dir, "2099-01-01-0000-otherrepo-feature-foo-cccc3333.digest.md"), "x")

      expect(store.latest_digest).to eq(newer)
    end
  end

  describe "#in_git_repo?" do
    it "is true inside a work tree and false otherwise" do
      expect(store.in_git_repo?).to be(true)
      expect(SessionMemory::Store.new(repo_root: @home, root: @home).in_git_repo?).to be(false)
    end
  end
end
