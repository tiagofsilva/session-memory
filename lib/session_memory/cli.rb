# frozen_string_literal: true

require "optparse"

module SessionMemory
  class CLI
    def self.run!(argv)
      new(argv).run!
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run!
      command = @argv.shift || "help"
      case command
      when "install" then install
      when "uninstall" then uninstall
      when "doctor" then doctor
      when "hook" then hook
      when "latest" then latest
      when "show" then show
      when "prune" then prune
      when "version" then puts(SessionMemory::VERSION)
      when "help", "-h", "--help" then help
      else
        warn("Unknown command: #{command}")
        help
        exit(1)
      end
    end

    private

    def install
      dry_run = false
      OptionParser.new do |opts|
        opts.on("--dry-run") { dry_run = true }
      end.parse!(@argv)

      Installer.new(dry_run: dry_run).install!
    end

    def uninstall
      dry_run = false
      OptionParser.new do |opts|
        opts.on("--dry-run") { dry_run = true }
      end.parse!(@argv)

      Installer.new(dry_run: dry_run).uninstall!
    end

    def doctor
      results = Installer.new.doctor
      results.each do |r|
        status = r[:ok] ? "ok" : "FAIL"
        puts("#{status.ljust(4)} #{r[:name]} — #{r[:detail]}")
      end
      exit(1) unless results.all? { |r| r[:ok] }
    end

    def hook
      tool = @argv.shift
      abort("usage: session-memory hook <cursor|codex|claude>") unless tool
      Hook.run!(tool: tool)
    end

    def latest
      repo_root = @argv.shift || Dir.pwd
      store = Store.new(repo_root: repo_root)
      abort("not a git repo: #{repo_root}") unless store.in_git_repo?

      path = store.latest_digest
      if path
        puts(path)
      else
        warn("no digest for #{store.repo_name}/#{store.current_branch}")
        exit(1)
      end
    end

    def show
      repo_root = @argv.shift || Dir.pwd
      store = Store.new(repo_root: repo_root)
      abort("not a git repo: #{repo_root}") unless store.in_git_repo?

      path = store.latest_digest
      abort("no digest for #{store.repo_name}/#{store.current_branch}") unless path
      puts(File.read(path))
    end

    def prune
      days = 30
      OptionParser.new do |opts|
        opts.on("--days N", Integer) { |n| days = n }
      end.parse!(@argv)

      store = Store.new(repo_root: Dir.pwd)
      removed = store.prune!(older_than_days: days)
      puts("removed #{removed.size} file(s) older than #{days} days")
      removed.each { |p| puts(p) }
    end

    def help
      puts(<<~HELP)
        session-memory #{SessionMemory::VERSION}

        Usage:
          session-memory install [--dry-run]
          session-memory uninstall [--dry-run]
          session-memory doctor
          session-memory hook <cursor|codex|claude>
          session-memory latest [repo_root]
          session-memory show [repo_root]
          session-memory prune [--days N]
          session-memory version
          session-memory help

        Sessions are stored privately under ~/.session-memory/sessions/<repo>/.
      HELP
    end
  end
end
