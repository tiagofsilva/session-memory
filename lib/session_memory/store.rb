# frozen_string_literal: true

require "shellwords"
require "fileutils"
require "securerandom"

module SessionMemory
  class Store
    BRANCH_LENGTH = SessionMemory::BRANCH_LENGTH

    attr_reader :root, :repo_root

    def initialize(repo_root:, root: SessionMemory.store_root)
      @root = root
      @repo_root = File.expand_path(repo_root)
    end

    def ensure!
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.chmod(0o700, @root)
      FileUtils.mkdir_p(sessions_dir, mode: 0o700)
      sessions_dir
    end

    def sessions_dir
      File.join(@root, "sessions", repo_name)
    end

    def repo_name
      @repo_name ||= begin
        common = git("rev-parse", "--git-common-dir")
        if common.empty?
          "norepo"
        else
          common_path = File.expand_path(common, @repo_root)
          main_root =
            if File.basename(common_path) == ".git"
              File.dirname(common_path)
            else
              toplevel = git("rev-parse", "--show-toplevel")
              toplevel.empty? ? @repo_root : toplevel
            end
          File.basename(main_root)
        end
      end
    end

    def in_git_repo?
      git("rev-parse", "--is-inside-work-tree") == "true"
    end

    def current_branch
      branch_slug(git("rev-parse", "--abbrev-ref", "HEAD"))
    end

    def short_sha
      git("rev-parse", "--short", "HEAD")
    end

    def branch_slug(branch)
      slug = branch.to_s.gsub(/[^a-zA-Z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, BRANCH_LENGTH].to_s.sub(/-+\z/, "")
      slug.empty? ? "nobranch" : slug
    end

    def short_id(session_id)
      session_id.to_s[0, 8]
    end

    def random_short_id
      SecureRandom.hex(4)
    end

    def digest_path(short_id, time: Time.now)
      ensure!
      existing = Dir.glob(File.join(sessions_dir, "*-#{short_id}.digest.md")).first
      return existing if existing

      stamp = time.strftime("%Y-%m-%d-%H%M")
      File.join(sessions_dir, "#{stamp}-#{repo_name}-#{current_branch}-#{short_id}.digest.md")
    end

    def log_path(digest_path)
      digest_path.sub(/\.digest\.md\z/, ".log.md")
    end

    def latest_digest(excluding_session_id: nil)
      paths = branch_digests
      if excluding_session_id
        suffix = "-#{short_id(excluding_session_id)}.digest.md"
        paths.reject! { |path| path.end_with?(suffix) }
      end
      paths.max
    end

    def session_digest(session_id, all_branches: false)
      suffix = "-#{short_id(session_id)}.digest.md"
      paths = all_branches ? Dir.glob(File.join(sessions_dir, "*.digest.md")) : branch_digests
      paths.find { |path| path.end_with?(suffix) && (all_branches || path.end_with?("-#{repo_name}-#{current_branch}#{suffix}")) }
    end

    def latest_active_digest(excluding_session_id: nil)
      paths = branch_digests
      paths.reject! { |path| path.end_with?("-#{short_id(excluding_session_id)}.digest.md") } if excluding_session_id
      paths.max_by { |path| [SessionState.activity_at(self, path), File.basename(path)] }
    end

    def inject_marker_path(session_id)
      ensure!
      File.join(sessions_dir, ".injected-#{short_id(session_id)}")
    end

    def prune!(older_than_days:)
      ensure!
      cutoff = Time.now - (older_than_days * 24 * 60 * 60)
      removed = []
      Dir.glob(File.join(@root, "sessions", "*", "*.{digest,log}.md")).each do |path|
        next if File.mtime(path) >= cutoff

        File.delete(path)
        removed << path
      end
      removed
    end

    private

    def branch_digests
      branch = current_branch
      Dir.glob(File.join(sessions_dir, "*.digest.md")).select do |path|
        first_line = File.open(path, &:gets).to_s.scrub
        id = Digest.metadata(first_line)[:id] || File.basename(path)[/-([^-]+)\.digest\.md\z/, 1]
        id && path.end_with?("-#{repo_name}-#{branch}-#{id}.digest.md")
      rescue Errno::ENOENT
        false
      end
    end

    def git(*args)
      return "" unless File.directory?(@repo_root)

      command = ["git", "-C", @repo_root, *args]
      `#{command.map { |a| Shellwords.escape(a) }.join(" ")} 2>/dev/null`.strip
    end
  end
end
