# frozen_string_literal: true

require "json"

module SessionMemory
  class Hook
    TOOLS = %w[cursor codex claude].freeze

    def initialize(tool:, payload:, stdin_event: nil)
      @tool = tool.to_s
      raise ArgumentError, "unknown tool: #{@tool}" unless TOOLS.include?(@tool)

      @payload = payload.is_a?(Hash) ? payload : {}
      @event = (stdin_event || @payload["hook_event_name"] || @payload["event"] || infer_event).to_s
    end

    def self.run!(tool:, stdin: $stdin)
      raw = stdin.read
      payload = raw.to_s.strip.empty? ? {} : JSON.parse(raw)
      new(tool: tool, payload: payload).call
    rescue StandardError => e
      warn "session-memory hook error: #{e.class}: #{e.message}"
      default_output(tool)
    end

    def self.default_output(tool)
      case tool.to_s
      when "cursor" then puts("{}\n")
      when "codex" then puts("{}\n")
        # claude stays silent
      end
    end

    def call
      return silent_ok unless resolve_repo_root
      return silent_ok unless store.in_git_repo?

      case @tool
      when "cursor" then handle_cursor
      when "codex" then handle_codex
      when "claude" then handle_claude
      end
    end

    private

    def infer_event
      return "sessionStart" if @payload.key?("composer_mode") || @payload["is_background_agent"]
      return "beforeSubmitPrompt" if @payload.key?("prompt") && @payload.key?("conversation_id")
      return "UserPromptSubmit" if @payload.key?("prompt") || @payload.key?("user_prompt")
      return "stop" if @payload.key?("status") && @payload.key?("loop_count")
      return "Stop" if @payload.key?("status")

      "UserPromptSubmit"
    end

    def resolve_repo_root
      @repo_root =
        case @tool
        when "cursor"
          from_env = ENV["CURSOR_PROJECT_DIR"].to_s.strip
          if from_env.empty?
            Array(@payload["workspace_roots"]).compact.first
          else
            from_env
          end
        else
          cwd = @payload["cwd"].to_s.strip
          cwd.empty? ? nil : cwd
        end
      @repo_root = File.expand_path(@repo_root) if @repo_root
      @repo_root
    end

    def store
      @store ||= Store.new(repo_root: @repo_root)
    end

    def session_id
      @session_id ||=
        @payload["conversation_id"] ||
          @payload["session_id"] ||
          ENV["CODEX_THREAD_ID"] ||
          store.random_short_id
    end

    def short
      store.short_id(session_id)
    end

    def model
      @payload["model"].to_s
    end

    def prompt_text
      [
        @payload["prompt"],
        @payload["user_prompt"],
        @payload["userPrompt"],
        @payload["input"],
        @payload["message"],
      ].compact.join("\n").strip
    end

    def transcript_path
      path = @payload["transcript_path"]
      return path if path && !path.to_s.empty?
      return Transcripts::Codex.find_transcript(session_id) if @tool == "codex"

      ENV["CURSOR_TRANSCRIPT_PATH"]
    end

    def seed_and_log!
      digest = store.digest_path(short)
      log = store.log_path(digest)

      unless File.exist?(digest)
        Digest.write(
          path: digest,
          short_id: short,
          tool: @tool,
          model: model,
          goal: prompt_text,
          log_path: log,
          git_sha: store.short_sha,
        )
      end

      body = Transcripts.render(@tool, transcript_path)
      Digest.write_log(
        path: log,
        tool: @tool,
        short_id: short,
        source: transcript_path,
        body: body,
        placeholder: "#{@tool.capitalize} transcript was unavailable for this hook run.",
      )
      digest
    end

    def latest_injection
      Digest.injection_context(store.latest_digest)
    end

    def handle_cursor
      case normalize_event(@event)
      when "sessionstart"
        ctx = latest_injection
        out = {}
        out["additional_context"] = ctx if ctx
        puts(JSON.generate(out))
      when "beforesubmitprompt"
        seed_and_log!
        puts("{}")
      when "stop"
        seed_and_log! if session_id
        puts("{}")
      else
        seed_and_log!
        puts("{}")
      end
    end

    def handle_codex
      case normalize_event(@event)
      when "sessionstart"
        ctx = latest_injection
        if ctx
          puts(JSON.generate({
            "hookSpecificOutput" => {
              "hookEventName" => "SessionStart",
              "additionalContext" => ctx,
            },
          }))
        else
          puts("{}")
        end
      when "userpromptsubmit"
        digest = seed_and_log!
        ctx = Digest.injection_context(digest)
        # Only inject on first prompt of a brand-new digest that is empty-ish;
        # prefer latest digest for resume, but still seed this conversation.
        resume = Digest.injection_context(store.latest_digest)
        text = resume || ctx
        if text
          puts(JSON.generate({
            "hookSpecificOutput" => {
              "hookEventName" => "UserPromptSubmit",
              "additionalContext" => text,
            },
          }))
        else
          puts("{}")
        end
      when "stop"
        seed_and_log!
        puts("{}")
      else
        seed_and_log!
        puts("{}")
      end
    end

    def handle_claude
      case normalize_event(@event)
      when "userpromptsubmit", "sessionstart"
        digest = seed_and_log!
        marker = store.inject_marker_path(session_id)
        unless File.exist?(marker)
          ctx = Digest.injection_context(store.latest_digest) || Digest.injection_context(digest)
          if ctx
            File.write(marker, Time.now.iso8601)
            # Claude injects UserPromptSubmit stdout into the prompt
            puts(ctx)
            return
          end
        end
        # stay silent
      when "stop"
        seed_and_log!
      else
        seed_and_log!
      end
    end

    def normalize_event(event)
      event.to_s.downcase.gsub(/[^a-z]/, "")
    end

    def silent_ok
      case @tool
      when "cursor", "codex" then puts("{}")
      end
    end
  end
end
