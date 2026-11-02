# frozen_string_literal: true

require "digest/sha2"
require "json"
require "tempfile"

module SessionMemory
  class SessionState
    COVERAGE_NOTE = "Transcript review incomplete; unreviewed character ranges: "

    attr_reader :digest_path

    def initialize(store:, digest_path:)
      @store = store
      @digest_path = digest_path
      key = self.class.revision(File.expand_path(digest_path))[0, 24]
      @path = File.join(store.sessions_dir, ".session-#{key}.json")
    end

    def self.revision(text)
      ::Digest::SHA256.hexdigest(text)
    end

    def self.log_header(path)
      return {} unless File.file?(path)

      lines = File.open(path) { |file| Array.new(4) { file.gets.to_s } }
      return {} unless lines.first.start_with?("# Session log:")

      source = lines[3].delete_prefix("Transcript: ").strip
      { source: source.empty? || source == "unavailable" ? nil : source }
    end

    def self.log_body(path)
      return "" unless File.file?(path)

      text = File.binread(path).force_encoding("UTF-8").scrub
      return "" unless text.start_with?("# Session log:")

      body = text.split("\n\n", 2)[1].to_s.strip
      return "" if body.match?(/\A(?:Cursor|Codex|Claude) transcript was unavailable for this hook run\.\z/)

      body
    end

    def self.activity_at(store, path)
      state = new(store: store, digest_path: path).read
      source = state["source_path"] || log_header(store.log_path(path))[:source]
      captured = state["activity_at"] || mtime(store.log_path(path)) || mtime(path) || 0
      [captured, source && mtime(source)].compact.max
    rescue SystemCallError
      mtime(path) || 0
    end

    def self.mtime(path)
      File.mtime(path).to_f if path && File.file?(path)
    rescue SystemCallError
      nil
    end

    def read
      state = File.file?(@path) ? JSON.parse(File.read(@path)) : {}
      state.is_a?(Hash) ? state : {}
    rescue JSON::ParserError
      {} # Derived receipts can be rebuilt; never infer coverage from corrupt data.
    end

    def capture!(body:, source: nil, now: Time.now.to_f)
      text = body.to_s.strip
      return if text.empty?

      revision = self.class.revision(text)
      update do |state|
        if state["capture_revision"] != revision
          state["capture_revision"] = revision
          state["activity_at"] = self.class.mtime(source) || now
        end
        state["source_path"] = source if source && !source.empty?
      end
    end

    def snapshot
      digest = File.binread(digest_path).force_encoding("UTF-8").scrub
      metadata = Digest.metadata(digest)
      log = @store.log_path(digest_path)
      source = read["source_path"] || self.class.log_header(log)[:source]
      text = ""
      if source && Transcripts::RENDERERS.key?(metadata[:tool])
        begin
          text = Transcripts.render(metadata[:tool], source).strip
        rescue StandardError
          text = ""
        end
      end
      provenance = "native transcript"
      if text.empty?
        text = self.class.log_body(log)
        provenance = "captured log"
      end
      {
        digest: digest, id: metadata[:id], tool: metadata[:tool], text: text,
        revision: text.empty? ? nil : self.class.revision(text),
        digest_revision: self.class.revision(digest),
        source: provenance == "native transcript" ? source : log,
        provenance: provenance, available: !text.empty?,
        notice: provenance == "captured log" && !text.empty? ? "Only the last captured log is available; later uncaptured activity cannot be verified." : nil,
        activity_at: self.class.activity_at(@store, digest_path),
      }
    end

    def current?(snapshot)
      state = read
      snapshot[:available] && Digest.complete?(snapshot[:digest]) &&
        state["checkpoint_revision"] == snapshot[:revision] &&
        state["checkpoint_digest_revision"] == snapshot[:digest_revision]
    end

    def extends_checkpoint?(snapshot, state = read)
      count = state["checkpoint_characters"]
      count.is_a?(Integer) && count <= snapshot[:text].length &&
        self.class.revision(snapshot[:text][0, count]) == state["checkpoint_revision"]
    end

    def uncovered_start(snapshot)
      state = read
      if Digest.complete?(snapshot[:digest]) && extends_checkpoint?(snapshot, state) && state["checkpoint_revision"] != snapshot[:revision]
        state["checkpoint_characters"]
      else
        0
      end
    end

    def reviewed_after(snapshot, reviewed)
      state = read
      previous = extends_checkpoint?(snapshot, state) ? state.fetch("reviewed", []) : []
      merge_ranges(previous + reviewed)
    end

    def gaps(length, reviewed)
      cursor = 0
      result = []
      merge_ranges(reviewed).each do |start, finish|
        result << [cursor, start] if start > cursor
        cursor = [cursor, finish].max
      end
      result << [cursor, length] if cursor < length
      result
    end

    def coverage_note(length, reviewed)
      missing = gaps(length, reviewed)
      return if missing.empty?

      "#{COVERAGE_NOTE}#{missing.first(8).map { |range| range.join(':') }.join(', ')}#{missing.length > 8 ? ', …' : ''}."
    end

    def checkpoint!(snapshot:, digest:, reviewed:)
      update do |state|
        state["activity_at"] ||= snapshot[:activity_at]
        state["checkpoint_revision"] = snapshot[:revision]
        state["checkpoint_characters"] = snapshot[:text].length
        state["checkpoint_digest_revision"] = self.class.revision(digest)
        state["reviewed"] = reviewed
      end
    end

    private

    def merge_ranges(ranges)
      ranges.sort.each_with_object([]) do |(start, finish), merged|
        if merged.any? && start <= merged.last[1]
          merged.last[1] = [finish, merged.last[1]].max
        else
          merged << [start, finish]
        end
      end
    end

    def update
      @store.ensure!
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        state = read
        original = state.dup
        yield state
        next if state == original

        Tempfile.create([".session-state-", ".tmp"], File.dirname(@path)) do |file|
          file.write(JSON.generate(state))
          file.flush
          file.fsync
          file.close
          File.rename(file.path, @path)
        end
      end
    end
  end
end
