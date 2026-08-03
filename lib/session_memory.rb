# frozen_string_literal: true

module SessionMemory
  VERSION = "0.1.0"
  DEFAULT_STORE_ROOT = File.expand_path("~/.session-memory")
  BRANCH_LENGTH = 40
  MARKER_BEGIN = "<!-- session-memory:begin -->"
  MARKER_END = "<!-- session-memory:end -->"
  COMMAND_MARKER = "session-memory hook"

  module_function

  def store_root
    ENV.fetch("SESSION_MEMORY_HOME", DEFAULT_STORE_ROOT)
  end

  def tool_root
    File.expand_path("..", __dir__)
  end

  def bin_path
    File.join(tool_root, "bin", "session-memory")
  end
end

require_relative "session_memory/store"
require_relative "session_memory/digest"
require_relative "session_memory/transcripts"
require_relative "session_memory/hook"
require_relative "session_memory/installer"
require_relative "session_memory/cli"
