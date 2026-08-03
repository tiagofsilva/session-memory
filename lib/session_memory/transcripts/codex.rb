# frozen_string_literal: true

require "json"

module SessionMemory
  module Transcripts
    module Codex
      module_function

      def content_text(content)
        Array(content).map { |item| item["text"] || item["input_text"] || item["output_text"] }.compact.join("\n").strip
      end

      def find_transcript(session_id)
        return unless session_id

        codex_home = ENV.fetch("CODEX_HOME", File.expand_path("~/.codex"))
        Dir.glob(File.join(codex_home, "sessions", "**", "*#{session_id}.jsonl")).first
      end

      def render(path)
        return "" unless path && File.file?(path)

        blocks = []
        File.foreach(path) do |raw|
          record =
            begin
              JSON.parse(raw)
            rescue StandardError
              next
            end

          timestamp = record["timestamp"]
          timestamp_suffix = timestamp ? " -- #{timestamp}" : nil
          payload = record["payload"]
          next unless payload.is_a?(Hash)

          case record["type"]
          when "event_msg"
            next unless payload["type"] == "user_message"

            text = payload["message"].to_s.strip
            blocks << "### User#{timestamp_suffix}\n\n#{text}\n" unless text.empty?
          when "response_item"
            case payload["type"]
            when "message"
              next unless payload["role"] == "assistant"

              text = content_text(payload["content"])
              blocks << "### Assistant#{timestamp_suffix}\n\n#{text}\n" unless text.empty?
            when "function_call"
              name = payload["name"].to_s.strip
              blocks << "### Assistant#{timestamp_suffix}\n\n_[tool: #{name}]_\n" unless name.empty?
            end
          end
        end
        blocks.join("\n")
      end
    end
  end
end
