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
      when "handoff" then handoff
      when "transcript" then transcript
      when "search" then search
      when "reindex" then reindex
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
      session_id = nil
      section = nil
      max_chars = nil
      all_branches = false
      OptionParser.new do |opts|
        opts.on("--session ID") { |id| session_id = id }
        opts.on("--section NAME") { |name| section = name }
        opts.on("--max-chars N", Integer) { |n| max_chars = n }
        opts.on("--all-branches") { all_branches = true }
      end.parse!(@argv)
      max_chars ||= 4000 if section
      if max_chars && !(128..20_000).cover?(max_chars)
        raise Index::Error, "max-chars must be between 128 and 20000"
      end
      repo_root = @argv.shift || Dir.pwd
      raise Index::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      store = Store.new(repo_root: repo_root)
      abort("not a git repo: #{repo_root}") unless store.in_git_repo?

      path = session_id ? store.session_digest(session_id, all_branches: all_branches) : store.latest_digest
      abort("no digest for #{store.repo_name}/#{store.current_branch}") unless path
      text = File.read(path)
      if section
        heading = Checkpoint::SECTIONS.fetch(section, section)
        match = Digest.sections(text).find { |name, _| name.casecmp?(heading) }
        raise Index::Error, "no section named #{section}" unless match
        text = "## #{match[0]}\n#{match[1]}\n"
      end
      text = "#{text.rstrip}\n"
      if max_chars && text.length > max_chars
        suffix = "\n[truncated; request a more specific section]\n"
        text = "#{text[0, max_chars - suffix.length]}#{suffix}"
      end
      print(text)
    rescue Index::Error, OptionParser::ParseError, SystemCallError => e
      abort("show: #{e.message}")
    end

    def search
      limit = 5
      offset = 0
      max_chars = 6000
      all_branches = false
      OptionParser.new do |opts|
        opts.banner = 'Usage: session-memory search "keywords" [options] [repo_root]'
        opts.on("--all-branches", "Search every branch of this repo") { all_branches = true }
        opts.on("--limit N", Integer, "Return 1-20 section matches (default: 5)") { |n| limit = n }
        opts.on("--offset N", Integer, "Skip matches for pagination") { |n| offset = n }
        opts.on("--max-chars N", Integer, "Total output budget, 512-20000 (default: 6000)") { |n| max_chars = n }
      end.parse!(@argv)
      query = @argv.shift.to_s
      repo_root = @argv.shift || Dir.pwd
      raise Index::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      raise Index::Error, "max-chars must be between 512 and 20000" unless (512..20_000).cover?(max_chars)
      store = Store.new(repo_root: repo_root)
      raise Index::Error, "not a git repo: #{repo_root}" unless store.in_git_repo?

      result = Index.new(store: store).search(query: query, all_branches: all_branches, limit: limit, offset: offset)
      output = +"Session memory search — saved history; current instructions take precedence.\n\n"
      shown = 0
      result[:hits].each do |hit|
        entry = "#{offset + shown + 1}. Session #{display(hit['session_id'])} | #{display(hit['branch'])} | #{display(hit['tool'])} | #{display(hit['started_at'])}\n" \
                "Section: #{display(hit['heading'])}\nSource: #{display(hit['path'])}\n#{display(hit['excerpt'])}\n\n"
        break if output.length + entry.length + 128 > max_chars
        output << entry
        shown += 1
      end
      if shown.zero?
        output << (result[:hits].empty? ? "No matches.\n" : "Matches exceed the output budget; increase --max-chars.\n")
      end
      if shown.positive? && (result[:more] || shown < result[:hits].size)
        output << "More matches available; continue with --offset #{offset + shown}.\n"
      end
      print(output)
    rescue Index::Error, OptionParser::ParseError, SQLite3::Exception, SystemCallError => e
      abort("search: #{e.message}. If the index is damaged, run session-memory reindex.")
    end

    def handoff
      source = nil
      current = ENV["CODEX_THREAD_ID"]
      OptionParser.new do |opts|
        opts.on("--from ID", "Prepare this source session on the current branch") { |id| source = id }
        opts.on("--current ID", "Exclude the receiving conversation") { |id| current = id }
      end.parse!(@argv)
      repo_root = @argv.shift || Dir.pwd
      raise Handoff::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      store = Store.new(repo_root: repo_root)
      raise Handoff::Error, "not a git repo: #{repo_root}" unless store.in_git_repo?
      text = Handoff.new(store: store).prepare(current_session_id: current, from: source)
      puts(text || "No previous session available on this repo/branch.")
    rescue Handoff::Error, OptionParser::ParseError, SystemCallError => e
      abort("handoff: #{e.message}")
    end

    def transcript
      session_id = nil
      revision = nil
      offset = nil
      max_chars = Handoff::TRANSCRIPT_LIMIT
      OptionParser.new do |opts|
        opts.on("--session ID") { |id| session_id = id }
        opts.on("--revision HASH", "Read only if the source snapshot still matches") { |hash| revision = hash }
        opts.on("--offset N", Integer, "Character offset in the rendered transcript") { |n| offset = n }
        opts.on("--max-chars N", Integer, "Total output budget, 1000-20000 (default: 6000)") { |n| max_chars = n }
      end.parse!(@argv)
      raise Handoff::Error, "provide --session ID" unless session_id && !session_id.empty?
      repo_root = @argv.shift || Dir.pwd
      raise Handoff::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      store = Store.new(repo_root: repo_root)
      raise Handoff::Error, "not a git repo: #{repo_root}" unless store.in_git_repo?
      print(Handoff.new(store: store).transcript(session_id: session_id, revision: revision, offset: offset, max_chars: max_chars))
    rescue Handoff::Error, OptionParser::ParseError, SystemCallError => e
      abort("transcript: #{e.message}")
    end

    def reindex
      repo_root = @argv.shift || Dir.pwd
      raise Index::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
      store = Store.new(repo_root: repo_root)
      raise Index::Error, "not a git repo: #{repo_root}" unless store.in_git_repo?
      index = Index.new(store: store)
      count = index.rebuild!
      puts("Indexed #{count} digest(s): #{index.path}")
    rescue Index::Error, SQLite3::Exception, SystemCallError => e
      abort("reindex: #{e.message}")
    end

    def display(text)
      text.to_s.gsub(/[[:cntrl:]]/, " ").gsub(/\s+/, " ").strip
    end

    def checkpoint
      input_path = nil
      session_id = ENV["CODEX_THREAD_ID"]
      transcript_revision = nil
      expected_digest = nil
      reviewed = []
      OptionParser.new do |opts|
        opts.banner = "Usage: session-memory checkpoint [--session ID] [--input FILE] [repo_root]"
        opts.on("--session ID", "Update this session instead of the latest digest") { |id| session_id = id }
        opts.on("--input FILE", "Read checkpoint JSON from a file (default: stdin)") { |path| input_path = path }
        opts.on("--transcript-revision HASH", "Source transcript snapshot for a handoff checkpoint") { |hash| transcript_revision = hash }
        opts.on("--expected-digest HASH", "Refuse to replace a digest that changed during preparation") { |hash| expected_digest = hash }
        opts.on("--reviewed START:END", "Reviewed transcript range; repeat for additional chunks") do |range|
          raise Checkpoint::Error, "reviewed range must be START:END" unless range.match?(/\A\d+:\d+\z/)
          reviewed << range.split(":").map(&:to_i)
        end
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
        transcript_revision: transcript_revision, expected_digest: expected_digest, reviewed: reviewed,
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
          session-memory show [--session ID] [--section NAME] [--max-chars N] [--all-branches] [repo_root]
          session-memory checkpoint [--session ID] [--input FILE] [repo_root]
          session-memory handoff [--from ID] [--current ID] [repo_root]
          session-memory transcript --session ID [--revision HASH] [--offset N] [--max-chars N] [repo_root]
          session-memory search "keywords" [--all-branches] [--limit N] [--offset N] [--max-chars N] [repo_root]
          session-memory reindex [repo_root]
          session-memory prune [--days N]
          session-memory version
          session-memory help

        Sessions are stored privately under ~/.session-memory/sessions/<repo>/.
      HELP
    end
  end
end
