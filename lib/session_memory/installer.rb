# frozen_string_literal: true

require "json"
require "fileutils"
require "rbconfig"
require "shellwords"

module SessionMemory
  class Installer
    attr_reader :dry_run, :ruby_path, :changes, :home

    def initialize(dry_run: false, ruby_path: nil, home: File.expand_path("~"))
      @dry_run = dry_run
      @home = home
      @ruby_path = ruby_path || resolve_ruby!
      @changes = []
    end

    def cursor_hooks_path = File.join(@home, ".cursor", "hooks.json")
    def codex_hooks_path = File.join(@home, ".codex", "hooks.json")
    def claude_settings_path = File.join(@home, ".claude", "settings.json")
    def codex_config_path = File.join(@home, ".codex", "config.toml")
    def codex_agents_path = File.join(@home, ".codex", "AGENTS.md")
    def claude_md_path = File.join(@home, ".claude", "CLAUDE.md")
    def cursor_skill_path = File.join(@home, ".cursor", "skills", "session-handoff")

    def install!
      resolve_ruby!
      ensure_store!
      install_cursor_hooks!
      install_codex_hooks!
      install_claude_hooks!
      install_instructions!
      install_cursor_skill!
      print_codex_feature_flag_hint!
      changes
    end

    def uninstall!
      remove_cursor_hooks!
      remove_codex_hooks!
      remove_claude_hooks!
      remove_instructions!
      remove_cursor_skill!
      changes
    end

    def doctor
      results = []
      results << check_ruby
      results << check_store
      results << check_cursor
      results << check_codex
      results << check_claude
      results << check_instructions
      results
    end

    def hook_command(tool)
      "#{Shellwords.escape(@ruby_path)} #{Shellwords.escape(SessionMemory.bin_path)} hook #{tool}"
    end

    private

    def resolve_ruby!
      candidates = []
      mise = `mise which ruby 2>/dev/null`.strip
      candidates << mise unless mise.empty?
      which = `command -v ruby 2>/dev/null`.strip
      candidates << which unless which.empty?
      candidates << RbConfig.ruby

      path = candidates.find { |p| File.executable?(p) }
      raise "No usable Ruby found (need 3.0+)" unless path

      version = `#{Shellwords.escape(path)} -e 'print RUBY_VERSION'`.strip
      major, = version.split(".").map(&:to_i)
      raise "Ruby #{version} at #{path} is too old (need 3.0+)" if major < 3

      @ruby_path = path
    end

    def ensure_store!
      root = SessionMemory.store_root
      if dry_run
        note("would create store at #{root} (mode 700)")
      else
        FileUtils.mkdir_p(root, mode: 0o700)
        File.chmod(0o700, root)
        FileUtils.mkdir_p(File.join(root, "sessions"), mode: 0o700)
        note("ensured store at #{root}")
      end
    end

    def backup!(path)
      return unless File.exist?(path)
      return if dry_run

      stamp = Time.now.strftime("%Y%m%d%H%M%S")
      backup = "#{path}.session-memory-bak.#{stamp}"
      FileUtils.cp(path, backup)
      note("backed up #{path} -> #{backup}")
    end

    def our_command?(command)
      command.to_s.include?(SessionMemory::COMMAND_MARKER) ||
        command.to_s.include?(SessionMemory.bin_path)
    end

    def install_cursor_hooks!
      path = cursor_hooks_path
      data = read_json(path) || { "version" => 1, "hooks" => {} }
      data["version"] ||= 1
      data["hooks"] ||= {}

      cmd = hook_command("cursor")
      desired = {
        "sessionStart" => [{ "command" => cmd }],
        "beforeSubmitPrompt" => [{ "command" => cmd }],
        "stop" => [{ "command" => cmd }],
      }

      changed = false
      desired.each do |event, entries|
        existing = Array(data["hooks"][event])
        without_ours = existing.reject { |e| our_command?(e["command"]) }
        merged = without_ours + entries
        if merged != existing
          data["hooks"][event] = merged
          changed = true
        end
      end

      if changed
        write_json!(path, data)
        note("updated #{path}")
      else
        note("ok #{path}")
      end
    end

    def remove_cursor_hooks!
      path = cursor_hooks_path
      return note("missing #{path}") unless File.exist?(path)

      data = read_json(path) || {}
      data["hooks"] ||= {}
      changed = false
      data["hooks"].each do |event, entries|
        filtered = Array(entries).reject { |e| our_command?(e["command"]) }
        if filtered.size != Array(entries).size
          data["hooks"][event] = filtered
          changed = true
        end
      end
      write_json!(path, data) if changed
      note(changed ? "cleaned #{path}" : "ok #{path}")
    end

    def install_codex_hooks!
      path = codex_hooks_path
      data = read_json(path) || { "description" => "User-level session-memory hooks.", "hooks" => {} }
      data["hooks"] ||= {}
      cmd = hook_command("codex")

      desired = {
        "SessionStart" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => cmd,
                "statusMessage" => "Loading session handoff",
                "additionalContextLimit" => 5000,
              },
            ],
          },
        ],
        "UserPromptSubmit" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => cmd,
                "statusMessage" => "Updating session handoff",
                "additionalContextLimit" => 5000,
              },
            ],
          },
        ],
        "Stop" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => cmd,
                "statusMessage" => "Refreshing session handoff log",
              },
            ],
          },
        ],
      }

      changed = false
      desired.each do |event, groups|
        existing = Array(data["hooks"][event])
        without_ours =
          existing.reject do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        merged = without_ours + groups
        if merged != existing
          data["hooks"][event] = merged
          changed = true
        end
      end

      if changed
        write_json!(path, data)
        note("updated #{path}")
      else
        note("ok #{path}")
      end
    end

    def remove_codex_hooks!
      path = codex_hooks_path
      return note("missing #{path}") unless File.exist?(path)

      data = read_json(path) || {}
      data["hooks"] ||= {}
      changed = false
      data["hooks"].each do |event, groups|
        filtered =
          Array(groups).reject do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        if filtered.size != Array(groups).size
          data["hooks"][event] = filtered
          changed = true
        end
      end
      write_json!(path, data) if changed
      note(changed ? "cleaned #{path}" : "ok #{path}")
    end

    def install_claude_hooks!
      path = claude_settings_path
      data = read_json(path) || { "hooks" => {} }
      data["hooks"] ||= {}
      cmd = hook_command("claude")

      desired = {
        "UserPromptSubmit" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => cmd,
              },
            ],
          },
        ],
        "Stop" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => cmd,
              },
            ],
          },
        ],
      }

      changed = false
      desired.each do |event, groups|
        existing = Array(data["hooks"][event])
        without_ours =
          existing.reject do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        merged = without_ours + groups
        if merged != existing
          data["hooks"][event] = merged
          changed = true
        end
      end

      if changed
        FileUtils.mkdir_p(File.dirname(path)) unless dry_run
        write_json!(path, data)
        note("updated #{path}")
      else
        note("ok #{path}")
      end
    end

    def remove_claude_hooks!
      path = claude_settings_path
      return note("missing #{path}") unless File.exist?(path)

      data = read_json(path) || {}
      data["hooks"] ||= {}
      changed = false
      data["hooks"].each do |event, groups|
        filtered =
          Array(groups).reject do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        if filtered.size != Array(groups).size
          data["hooks"][event] = filtered
          changed = true
        end
      end
      write_json!(path, data) if changed
      note(changed ? "cleaned #{path}" : "ok #{path}")
    end

    def install_instructions!
      snippet = File.read(File.join(SessionMemory.tool_root, "instructions", "agents.md"))
      [codex_agents_path, claude_md_path].each do |path|
        upsert_marked_snippet!(path, snippet)
      end
    end

    def remove_instructions!
      [codex_agents_path, claude_md_path].each do |path|
        remove_marked_snippet!(path)
      end
    end

    def upsert_marked_snippet!(path, snippet)
      body = File.exist?(path) ? File.read(path) : ""
      block = "#{SessionMemory::MARKER_BEGIN}\n#{snippet.strip}\n#{SessionMemory::MARKER_END}\n"
      if body.include?(SessionMemory::MARKER_BEGIN) && body.include?(SessionMemory::MARKER_END)
        new_body = body.sub(
          /#{Regexp.escape(SessionMemory::MARKER_BEGIN)}.*?#{Regexp.escape(SessionMemory::MARKER_END)}\n?/m,
          block,
        )
      else
        new_body = body.empty? ? block : "#{body.rstrip}\n\n#{block}"
      end

      if new_body != body
        write_text!(path, new_body)
        note("updated #{path}")
      else
        note("ok #{path}")
      end
    end

    def remove_marked_snippet!(path)
      return note("missing #{path}") unless File.exist?(path)

      body = File.read(path)
      new_body = body.sub(
        /\n*#{Regexp.escape(SessionMemory::MARKER_BEGIN)}.*?#{Regexp.escape(SessionMemory::MARKER_END)}\n*/m,
        "\n",
      )
      if new_body != body
        write_text!(path, new_body.strip.empty? ? "" : "#{new_body.rstrip}\n")
        note("cleaned #{path}")
      else
        note("ok #{path}")
      end
    end

    def install_cursor_skill!
      source = File.join(SessionMemory.tool_root, "skills", "session-handoff")
      if dry_run
        note("would symlink #{cursor_skill_path} -> #{source}")
        return
      end

      FileUtils.mkdir_p(File.dirname(cursor_skill_path))
      if File.symlink?(cursor_skill_path) || File.exist?(cursor_skill_path)
        FileUtils.rm_rf(cursor_skill_path)
      end
      File.symlink(source, cursor_skill_path)
      note("symlinked #{cursor_skill_path} -> #{source}")
    end

    def remove_cursor_skill!
      if File.symlink?(cursor_skill_path) || File.exist?(cursor_skill_path)
        FileUtils.rm_rf(cursor_skill_path) unless dry_run
        note("removed #{cursor_skill_path}")
      else
        note("missing #{cursor_skill_path}")
      end
    end

    def print_codex_feature_flag_hint!
      if codex_hooks_enabled?
        note("Codex feature flag codex_hooks already enabled")
      else
        hint = <<~HINT.strip
          Codex hooks are not enabled yet. Add this to #{codex_config_path}:

          [features]
          codex_hooks = true

          Then trust the hook with /hooks in the Codex TUI if prompted.
        HINT
        note(hint)
      end
    end

    def codex_hooks_enabled?
      return false unless File.exist?(codex_config_path)

      text = File.read(codex_config_path)
      text.match?(/^\s*codex_hooks\s*=\s*true\s*$/)
    end

    def check_ruby
      begin
        path = resolve_ruby!
        { name: "ruby", ok: true, detail: "#{path} (#{`#{Shellwords.escape(path)} -e 'print RUBY_VERSION'`.strip})" }
      rescue StandardError => e
        { name: "ruby", ok: false, detail: e.message }
      end
    end

    def check_store
      root = SessionMemory.store_root
      if File.directory?(root)
        mode = File.stat(root).mode & 0o777
        { name: "store", ok: mode == 0o700, detail: "#{root} mode=#{format("%o", mode)}" }
      else
        { name: "store", ok: false, detail: "#{root} missing" }
      end
    end

    def check_cursor
      data = read_json(cursor_hooks_path)
      ok = data && %w[sessionStart beforeSubmitPrompt stop].all? do |event|
        Array(data.dig("hooks", event)).any? { |e| our_command?(e["command"]) }
      end
      { name: "cursor hooks", ok: !!ok, detail: cursor_hooks_path }
    end

    def check_codex
      data = read_json(codex_hooks_path)
      events_ok =
        data && %w[SessionStart UserPromptSubmit Stop].all? do |event|
          Array(data.dig("hooks", event)).any? do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        end
      flag_ok = codex_hooks_enabled?
      { name: "codex hooks", ok: !!events_ok && flag_ok, detail: "hooks=#{!!events_ok} feature_flag=#{flag_ok}" }
    end

    def check_claude
      data = read_json(claude_settings_path)
      ok =
        data && %w[UserPromptSubmit Stop].all? do |event|
          Array(data.dig("hooks", event)).any? do |group|
            Array(group["hooks"]).any? { |h| our_command?(h["command"]) }
          end
        end
      { name: "claude hooks", ok: !!ok, detail: claude_settings_path }
    end

    def check_instructions
      ok =
        [codex_agents_path, claude_md_path].all? { |p| File.exist?(p) && File.read(p).include?(SessionMemory::MARKER_BEGIN) } &&
          File.symlink?(cursor_skill_path)
      { name: "instructions", ok: ok, detail: "agents snippets + cursor skill" }
    end

    def read_json(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write_json!(path, data)
      return if dry_run

      FileUtils.mkdir_p(File.dirname(path))
      backup!(path)
      File.write(path, JSON.pretty_generate(data) + "\n")
    end

    def write_text!(path, body)
      return if dry_run

      FileUtils.mkdir_p(File.dirname(path))
      backup!(path) if File.exist?(path)
      File.write(path, body)
    end

    def note(message)
      @changes << message
      puts(message)
    end
  end
end
