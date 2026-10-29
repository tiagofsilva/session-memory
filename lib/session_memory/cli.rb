# frozen_string_literal: true

require "optparse"
require "json"

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
      when "checkpoint" then checkpoint
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

    def checkpoint
      input_path = nil
      session_id = ENV["CODEX_THREAD_ID"]
      OptionParser.new do |opts|
        opts.banner = "Usage: session-memory checkpoint [--session ID] [--input FILE] [repo_root]"
        opts.on("--session ID", "Update this session instead of the latest digest") { |id| session_id = id }
        opts.on("--input FILE", "Read checkpoint JSON from a file (default: stdin)") { |path| input_path = path }
      end.parse!(@argv)
      repo_root = @argv.shift || Dir.pwd
      raise Checkpoint::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      raise Checkpoint::Error, "session ID must not be empty" if session_id && session_id.strip.empty?

      raw =
        if input_path && input_path != "-"
          File.read(input_path)
        else
          raise Checkpoint::Error, "provide checkpoint JSON on stdin or with --input FILE" if $stdin.tty?
          $stdin.read
        end
      result = Checkpoint.new(store: Store.new(repo_root: repo_root)).write!(
        data: JSON.parse(raw),
        session_id: session_id,
      )
      puts("Checkpoint saved: #{result[:digest]}")
      puts("Previous version: #{result[:previous_version]}")
    rescue JSON::ParserError => e
      abort("checkpoint: invalid JSON: #{e.message}")
    rescue Checkpoint::Error, OptionParser::ParseError, SystemCallError => e
      abort("checkpoint: #{e.message}")
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
          session-memory checkpoint [--session ID] [--input FILE] [repo_root]
          session-memory prune [--days N]
          session-memory version
          session-memory help

        Sessions are stored privately under ~/.session-memory/sessions/<repo>/.
      HELP
    end
  end
end
