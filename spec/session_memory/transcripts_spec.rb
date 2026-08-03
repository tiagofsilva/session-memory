# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe SessionMemory::Transcripts do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  describe "Cursor" do
    it "renders user and assistant turns" do
      user_text = "<timestamp>Mon</timestamp>\n<user_query>\nHello there\n</user_query>"
      assistant_content = [{ "type" => "text", "text" => "General Kenobi" }, { "type" => "tool_use", "name" => "Shell" }]
      records = [
        { "role" => "user", "message" => { "content" => [{ "type" => "text", "text" => user_text }] } },
        { "role" => "assistant", "message" => { "content" => assistant_content } },
      ]
      path = File.join(@dir, "t.jsonl")
      File.write(path, records.map(&:to_json).join("\n"))

      body = SessionMemory::Transcripts.render("cursor", path)
      expect(body).to include("### User — Mon", "Hello there", "General Kenobi", "_[tool: Shell]_")
    end
  end

  describe "Codex" do
    it "renders user messages and assistant output" do
      records = [
        { "type" => "event_msg", "timestamp" => "T1", "payload" => { "type" => "user_message", "message" => "Hello codex" } },
        { "type" => "response_item", "payload" => { "type" => "message", "role" => "assistant", "content" => [{ "type" => "output_text", "text" => "Hi from codex" }] } },
        { "type" => "response_item", "payload" => { "type" => "function_call", "name" => "shell" } },
      ]
      path = File.join(@dir, "t.jsonl")
      File.write(path, records.map(&:to_json).join("\n"))

      body = SessionMemory::Transcripts.render("codex", path)
      expect(body).to include("### User -- T1", "Hello codex", "Hi from codex", "_[tool: shell]_")
    end
  end

  describe "Claude" do
    it "renders text and tool_use, ignoring tool_result" do
      assistant_content = [{ "type" => "text", "text" => "Hi from Claude" }, { "type" => "tool_use", "name" => "Bash" }]
      records = [
        { "type" => "user", "message" => { "role" => "user", "content" => "Hello Claude" }, "timestamp" => "T1" },
        { "type" => "assistant", "message" => { "role" => "assistant", "content" => assistant_content }, "timestamp" => "T2" },
        { "type" => "user", "message" => { "role" => "user", "content" => [{ "type" => "tool_result", "content" => "ignored" }] }, "timestamp" => "T3" },
      ]
      path = File.join(@dir, "t.jsonl")
      File.write(path, records.map(&:to_json).join("\n"))

      body = SessionMemory::Transcripts.render("claude", path)
      expect(body).to include("### User -- T1", "Hello Claude", "### Assistant -- T2", "Hi from Claude", "_[tool: Bash]_")
      expect(body).not_to include("ignored")
    end
  end
end
