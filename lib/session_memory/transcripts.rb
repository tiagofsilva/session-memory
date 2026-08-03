# frozen_string_literal: true

require_relative "transcripts/cursor"
require_relative "transcripts/codex"
require_relative "transcripts/claude"

module SessionMemory
  module Transcripts
    RENDERERS = {
      "cursor" => Cursor,
      "codex" => Codex,
      "claude" => Claude,
    }.freeze

    module_function

    def render(tool, path)
      renderer = RENDERERS.fetch(tool) { raise ArgumentError, "unknown tool: #{tool}" }
      renderer.render(path)
    end
  end
end
