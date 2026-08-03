# frozen_string_literal: true

require "json"

module SessionMemory
  module Transcripts
    module Cursor
      module_function

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
          role = record["role"]
          next unless role == "user" || role == "assistant"
          message = record["message"]
          next unless message.is_a?(Hash)

          parts =
            Array(message["content"])
              .map do |block|
                case block["type"]
                when "text"
                  block["text"].to_s
                when "tool_use"
                  "_[tool: #{block["name"]}]_"
                end
              end
              .compact
          text = parts.join("\n").strip
          next if text.empty?

          label = role == "user" ? "User" : "Assistant"
          if role == "user"
            query = text[%r{<user_query>(.+?)</user_query>}m, 1]
            if query
              timestamp = text[%r{<timestamp>(.+?)</timestamp>}m, 1]
              text = query.strip
              label = timestamp ? "User — #{timestamp}" : "User"
            end
          end

          blocks << "### #{label}\n\n#{text}\n"
        end
        blocks.join("\n")
      end
    end
  end
end
