# frozen_string_literal: true

module SessionMemory
  module Digest
    module_function

    def write(path:, short_id:, tool:, model:, goal:, log_path:, git_sha:)
      File.write(path, <<~DIGEST)
        # Session digest: #{short_id}
        Date: #{Time.now.strftime("%Y-%m-%d")} · Git: #{git_sha} · Tool: #{tool} · Model: #{model}
        Log: #{File.basename(log_path)}

        > Handoff: to resume, read this digest. Treat Requirements and Decisions as
        > binding and continue from Next step. The full transcript lives in the Log
        > file if you need more detail.

        ## Goal
        #{goal.to_s.strip.empty? ? "<fill in>" : goal.lines.first.strip}

        ## Requirements / constraints
        -\s

        ## Decisions
        -\s

        ## Corrections
        -\s

        ## Current state
        -\s

        ## Next step
        -\s
      DIGEST
    end

    def write_log(path:, tool:, short_id:, source:, body:, placeholder:)
      text = body.to_s.strip
      text = placeholder if text.empty?

      File.write(path, <<~LOG)
        # Session log: #{short_id}
        Auto-generated from #{tool}'s transcript when available. Do not edit by hand.
        Updated: #{Time.now.iso8601}
        Transcript: #{source || "unavailable"}

        #{text}
      LOG
    end

    def injection_context(digest_path)
      return nil unless digest_path && File.file?(digest_path)

      <<~CTX.strip
        Session handoff digest for this repo/branch (from session-memory):

        #{File.read(digest_path).strip}

        Treat Requirements and Decisions as binding and continue from Next step.
        Full transcript is in the matching Log file next to this digest.
      CTX
    end
  end
end
