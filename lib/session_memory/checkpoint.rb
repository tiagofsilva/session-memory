# frozen_string_literal: true

require "tempfile"
require "time"

module SessionMemory
  class Checkpoint
    class Error < StandardError; end

    SECTIONS = {
      "goal" => "Goal",
      "requirements" => "Requirements / constraints",
      "decisions" => "Decisions",
      "corrections" => "Corrections",
      "current_state" => "Current state",
      "open_questions" => "Open questions / blockers",
      "next_step" => "Next step",
    }.freeze
    REQUIRED_FIELDS = %w[decisions current_state open_questions next_step].freeze
    LIST_FIELDS = %w[requirements decisions corrections current_state open_questions].freeze

    def initialize(store:)
      @store = store
    end

    def write!(data:, session_id: nil)
      validate!(data)
      raise Error, "not a git repo: #{@store.repo_root}" unless @store.in_git_repo?

      path = session_id ? @store.session_digest(session_id) : @store.latest_digest
      unless path
        scope = "#{@store.repo_name}/#{@store.current_branch}"
        scope += " (session #{session_id})" if session_id
        raise Error, "no digest for #{scope}; start a session with hooks before checkpointing"
      end

      # Keep the lock separate from the digest: atomic replacement changes its inode.
      lock_path = File.join(File.dirname(path), ".checkpoint-#{File.basename(path)}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        original = File.read(path)
        updated = render(original, data)
        history_dir = File.join(@store.sessions_dir, "history", File.basename(path, ".digest.md"))
        FileUtils.mkdir_p(history_dir, mode: 0o700)
        stamp = Time.now.utc.strftime("%Y-%m-%d-%H%M%S-%6N")
        previous_version = File.join(history_dir, "#{stamp}-#{SecureRandom.hex(4)}.digest.md")

        atomic_write(previous_version, original)
        atomic_write(path, updated)
        { digest: path, previous_version: previous_version }
      end
    end

    private

    def validate!(data)
      raise Error, "checkpoint must be a JSON object" unless data.is_a?(Hash)

      unknown = data.keys - SECTIONS.keys
      raise Error, "unknown checkpoint fields: #{unknown.join(', ')}" unless unknown.empty?

      missing = REQUIRED_FIELDS - data.keys
      raise Error, "missing checkpoint fields: #{missing.join(', ')}" unless missing.empty?

      data.each do |key, value|
        if LIST_FIELDS.include?(key)
          raise Error, "#{key} must be an array of non-empty strings" unless value.is_a?(Array)
          value.each { |entry| validate_text!(key, entry) }
        else
          validate_text!(key, value)
        end
      end
      raise Error, "current_state must contain at least one item" if data["current_state"].empty?
    end

    def validate_text!(key, text)
      unless text.is_a?(String) && !text.strip.empty?
        raise Error, "#{key} must contain non-empty text"
      end
      # These headings delimit digest sections and cannot appear inside a value.
      raise Error, "#{key} must not contain level-two Markdown headings" if text.match?(/^##[ \t]/)
    end

    def section_pattern(heading)
      /^## #{Regexp.escape(heading)}[ \t]*\r?\n.*?(?=^## |\z)/m
    end

    def render(original, data)
      unless original.start_with?("# Session digest: ")
        raise Error, "invalid session digest header"
      end
      SECTIONS.each do |key, heading|
        next if key == "open_questions" # Older digests do not have this section.
        raise Error, "digest is missing section: #{heading}" unless original.match?(section_pattern(heading))
      end

      data.reduce(original) do |body, (key, value)|
        heading = SECTIONS.fetch(key)
        text =
          if LIST_FIELDS.include?(key)
            value.empty? ? "- None." : value.map { |entry| "- #{entry.strip.gsub("\n", "\n  ")}" }.join("\n")
          else
            value.strip
          end
        section = "## #{heading}\n#{text}\n\n"
        if body.match?(section_pattern(heading))
          body.sub(section_pattern(heading)) { section }
        else
          body.sub(/^## Next step[ \t]*\r?\n/) { |match| "#{section}#{match}" }
        end
      end
    end

    def atomic_write(path, text)
      Tempfile.create([".checkpoint-", ".tmp"], File.dirname(path)) do |file|
        file.write(text)
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      end
    end
  end
end
