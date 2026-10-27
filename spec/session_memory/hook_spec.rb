# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "fileutils"

RSpec.describe SessionMemory::Hook do
  around do |example|
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |repo|
        @home = home
        @repo = repo
        ENV["SESSION_MEMORY_HOME"] = home
        system("git", "init", "-b", "main", repo, out: File::NULL, err: File::NULL)
        system("git", "-C", repo, "config", "user.email", "t@example.com", out: File::NULL)
        system("git", "-C", repo, "config", "user.name", "t", out: File::NULL)
        File.write(File.join(repo, "README"), "x")
        system("git", "-C", repo, "add", "README", out: File::NULL)
        system("git", "-C", repo, "commit", "-m", "init", out: File::NULL, err: File::NULL)
        example.run
      ensure
        ENV.delete("SESSION_MEMORY_HOME")
        ENV.delete("CURSOR_PROJECT_DIR")
      end
    end
  end

  def run_hook(tool, payload, env: {})
    bin = SessionMemory.bin_path
    Open3.capture2(
      env.merge("SESSION_MEMORY_HOME" => @home),
      RbConfig.ruby,
      bin,
      "hook",
      tool,
      stdin_data: payload.to_json,
    )
  end

  def write_digest(id:, goal:, tool: "cursor", time: Time.new(2020, 1, 1))
    store = SessionMemory::Store.new(repo_root: @repo, root: @home)
    path = store.digest_path(id, time: time)
    SessionMemory::Digest.write(
      path: path,
      short_id: id,
      tool: tool,
      model: "m",
      goal: goal,
      log_path: store.log_path(path),
      git_sha: "abc",
    )
    path
  end

  it "seeds a cursor digest using CURSOR_PROJECT_DIR and renders the transcript" do
    user_text = "<timestamp>Mon</timestamp>\n<user_query>\nHello there\n</user_query>"
    records = [
      { role: "user", message: { content: [{ type: "text", text: user_text }] } },
      { role: "assistant", message: { content: [{ type: "text", text: "General Kenobi" }] } },
    ]
    transcript = File.join(@repo, "transcript.jsonl")
    File.write(transcript, records.map(&:to_json).join("\n"))

    payload = {
      hook_event_name: "beforeSubmitPrompt",
      conversation_id: "abcd1234wxyz",
      prompt: "Build the thing",
      model: "m1",
      transcript_path: transcript,
      workspace_roots: [@repo],
    }
    stdout, status = run_hook("cursor", payload, env: { "CURSOR_PROJECT_DIR" => @repo })

    expect(status).to be_success
    expect(stdout.strip).to eq("{}")

    digest = Dir.glob(File.join(@home, "sessions", File.basename(@repo), "*-abcd1234.digest.md")).first
    log = Dir.glob(File.join(@home, "sessions", File.basename(@repo), "*-abcd1234.log.md")).first
    expect(File.read(digest)).to include("Tool: cursor", "## Goal\nBuild the thing")
    expect(File.read(log)).to include("Hello there", "General Kenobi")
  end

  it "injects additional_context on cursor sessionStart from the latest digest" do
    store = SessionMemory::Store.new(repo_root: @repo, root: @home)
    digest = store.digest_path("deadbeef", time: Time.new(2020, 1, 1))
    SessionMemory::Digest.write(
      path: digest,
      short_id: "deadbeef",
      tool: "cursor",
      model: "m",
      goal: "Prior work",
      log_path: store.log_path(digest),
      git_sha: "abc",
    )

    payload = {
      hook_event_name: "sessionStart",
      session_id: "newsession",
      conversation_id: "newsession",
      workspace_roots: [@repo],
    }
    stdout, status = run_hook("cursor", payload, env: { "CURSOR_PROJECT_DIR" => @repo })
    expect(status).to be_success
    parsed = JSON.parse(stdout)
    expect(parsed["additional_context"]).to include("Prior work")
  end

  it "exits quietly outside a git repo" do
    payload = {
      hook_event_name: "beforeSubmitPrompt",
      conversation_id: "abcd1234wxyz",
      prompt: "x",
      workspace_roots: [@home],
    }
    stdout, status = run_hook("cursor", payload, env: { "CURSOR_PROJECT_DIR" => @home })
    expect(status).to be_success
    expect(stdout.strip).to eq("{}")
    expect(Dir.glob(File.join(@home, "sessions", "**", "*"))).to be_empty
  end

  it "returns codex additionalContext on SessionStart" do
    store = SessionMemory::Store.new(repo_root: @repo, root: @home)
    digest = store.digest_path("c0dexxxx", time: Time.new(2020, 1, 1))
    SessionMemory::Digest.write(
      path: digest,
      short_id: "c0dexxxx",
      tool: "codex",
      model: "m",
      goal: "Codex prior",
      log_path: store.log_path(digest),
      git_sha: "abc",
    )

    payload = { hook_event_name: "SessionStart", session_id: "s1", cwd: @repo }
    stdout, status = run_hook("codex", payload)
    expect(status).to be_success
    parsed = JSON.parse(stdout)
    expect(parsed.dig("hookSpecificOutput", "additionalContext")).to include("Codex prior")
  end

  it "prints claude injection once per session then stays silent" do
    write_digest(id: "previous", goal: "Prior work")
    payload = {
      hook_event_name: "UserPromptSubmit",
      session_id: "claude99deadbeef",
      prompt: "Test Claude",
      model: "claude-x",
      cwd: @repo,
    }
    stdout1, status1 = run_hook("claude", payload)
    expect(status1).to be_success
    expect(stdout1).to include("Prior work", "Tool: cursor")
    expect(stdout1).not_to include("Test Claude")

    stdout2, status2 = run_hook("claude", payload)
    expect(status2).to be_success
    expect(stdout2).to eq("")
  end

  %w[cursor codex claude].each do |tool|
    context_from = lambda do |stdout|
      case tool
      when "cursor" then JSON.parse(stdout)["additional_context"]
      when "codex" then JSON.parse(stdout).dig("hookSpecificOutput", "additionalContext")
      when "claude" then stdout.empty? ? nil : stdout
      end
    end

    it "delivers another tool's handoff once to #{tool}, excluding its existing digest" do
      sender = tool == "cursor" ? "claude" : "cursor"
      write_digest(id: "previous", goal: "Keep the previous decision", tool: sender)
      write_digest(id: "receiver", goal: "Receiving session's empty note", tool: tool, time: Time.new(2021, 1, 1))
      payload = {
        hook_event_name: "SessionStart",
        session_id: "receiver-session",
        conversation_id: "receiver-session",
        cwd: @repo,
        workspace_roots: [@repo],
      }

      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      context = context_from.call(stdout)
      expect(context).to include("Keep the previous decision", "Tool: #{sender}")
      expect(context).not_to include("Receiving session's empty note")

      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil

      event = tool == "cursor" ? "beforeSubmitPrompt" : "UserPromptSubmit"
      stdout, status = run_hook(tool, payload.merge(hook_event_name: event, prompt: "Continue"))
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil
    end
  end

  %w[codex claude].each do |tool|
    context_from = lambda do |stdout|
      tool == "codex" ? JSON.parse(stdout).dig("hookSpecificOutput", "additionalContext") : (stdout.empty? ? nil : stdout)
    end

    it "delivers the prior handoff on #{tool}'s first prompt when startup did not run" do
      write_digest(id: "previous", goal: "Prior work")
      payload = { hook_event_name: "UserPromptSubmit", session_id: "receiver-session", prompt: "Continue", cwd: @repo }

      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      expect(context_from.call(stdout)).to include("Prior work", "Tool: cursor")

      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil
    end

    it "does not inject #{tool}'s own template when no prior session exists" do
      payload = { hook_event_name: "SessionStart", session_id: "receiver-session", cwd: @repo }
      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil

      stdout, status = run_hook(tool, payload.merge(hook_event_name: "UserPromptSubmit", prompt: "First task"))
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil

      store = SessionMemory::Store.new(repo_root: @repo, root: @home)
      expect(File.read(store.digest_path("receiver"))).to include("## Goal\nFirst task")
      expect(File.exist?(store.inject_marker_path("receiver-session"))).to be(false)
    end

    it "retries #{tool}'s handoff at the first prompt if none was available at startup" do
      payload = { hook_event_name: "SessionStart", session_id: "receiver-session", cwd: @repo }
      stdout, status = run_hook(tool, payload)
      expect(status).to be_success
      expect(context_from.call(stdout)).to be_nil

      write_digest(id: "previous", goal: "Newly available handoff")
      stdout, status = run_hook(tool, payload.merge(hook_event_name: "UserPromptSubmit", prompt: "Continue"))
      expect(status).to be_success
      expect(context_from.call(stdout)).to include("Newly available handoff")
    end
  end
end
