# frozen_string_literal: true

require "json"

module SessionMemory
  module Transcripts
    module Claude
      module_function

      def content_text(content)
        case content
        when String
          content
        when Array
          content
            .map do |block|
              case block["type"]
              when "text"
                block["text"].to_s
              when "tool_use"
                "_[tool: #{block["name"]}]_"
              end
            end
            .compact
            .join("\n")
        else
          ""
        end
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

          type = record["type"]
          next unless type == "user" || type == "assistant"
          message = record["message"]
          next unless message.is_a?(Hash)

          text = content_text(message["content"]).strip
          next if text.empty?

          timestamp = record["timestamp"]
          suffix = timestamp ? " -- #{timestamp}" : ""
          label = type == "user" ? "User" : "Assistant"
          blocks << "### #{label}#{suffix}\n\n#{text}\n"
        end
        blocks.join("\n")
      end
    end
  end
end
