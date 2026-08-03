# frozen_string_literal: true

require "spec_helper"

RSpec.describe SessionMemory::Digest do
  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  it "seeds the digest with metadata and the first line of the goal" do
    SessionMemory::Digest.write(
      path: "d.digest.md",
      short_id: "abcd1234",
      tool: "cursor",
      model: "gpt-x",
      goal: "First line\nSecond line",
      log_path: "some.log.md",
      git_sha: "abc1234",
    )

    content = File.read("d.digest.md")
    expect(content).to include("# Session digest: abcd1234")
    expect(content).to include("Tool: cursor · Model: gpt-x")
    expect(content).to include("Log: some.log.md")
    expect(content).to include("## Goal\nFirst line\n")
    expect(content).not_to include("Second line")
  end

  it "uses a placeholder goal when none is provided" do
    SessionMemory::Digest.write(
      path: "d.digest.md",
      short_id: "abcd1234",
      tool: "cursor",
      model: "",
      goal: "",
      log_path: "l.log.md",
      git_sha: "",
    )
    expect(File.read("d.digest.md")).to include("## Goal\n<fill in>\n")
  end

  it "writes a log with placeholder when body is empty" do
    SessionMemory::Digest.write_log(
      path: "l.log.md",
      tool: "codex",
      short_id: "abcd1234",
      source: nil,
      body: "   ",
      placeholder: "Nothing captured",
    )
    content = File.read("l.log.md")
    expect(content).to include("Nothing captured")
    expect(content).to include("Transcript: unavailable")
  end
end
