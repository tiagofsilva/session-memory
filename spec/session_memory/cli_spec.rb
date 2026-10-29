# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe SessionMemory::CLI do
  around do |example|
    Dir.mktmpdir do |tmp|
      @repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(@repo)
      system("git", "init", "-b", "main", @repo, out: File::NULL, err: File::NULL)
      @home = File.join(tmp, "memory")
      @store = SessionMemory::Store.new(repo_root: @repo, root: @home)
      @digest = @store.digest_path("session1", time: Time.new(2020, 1, 1))
      SessionMemory::Digest.write(
        path: @digest, short_id: "session1", tool: "cursor", model: "m",
        goal: "Original goal", log_path: @store.log_path(@digest), git_sha: "abc",
      )
      example.run
    end
  end

  let(:data) do
    { "decisions" => [], "current_state" => ["Tests pass."], "open_questions" => [], "next_step" => "Commit changes." }
  end

  def run_cli(*args, input: JSON.generate(data), env: {})
    Open3.capture3(
      { "SESSION_MEMORY_HOME" => @home, "CODEX_THREAD_ID" => nil }.merge(env),
      RbConfig.ruby, SessionMemory.bin_path, *args,
      stdin_data: input, chdir: @repo,
    )
  end

  it "checkpoints from stdin in the current repo and reports the saved paths" do
    stdout, stderr, status = run_cli("checkpoint")

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("Checkpoint saved: #{@digest}", "Previous version:")
    expect(File.read(@digest)).to include("Tests pass.", "Commit changes.")
  end

  it "reads JSON from an input file and accepts an explicit repo root" do
    input_path = File.join(@repo, "checkpoint.json")
    File.write(input_path, JSON.generate(data))

    _, stderr, status = run_cli("checkpoint", "--input", input_path, @repo, input: "")

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(File.read(@digest)).to include("Commit changes.")
  end

  it "passes a checkpoint from a captured Cursor session into a new Codex session" do
    _, _, status = run_cli("hook", "cursor", input: JSON.generate({
      hook_event_name: "beforeSubmitPrompt", conversation_id: "cursor-session",
      prompt: "Build checkpoints", workspace_roots: [@repo],
    }), env: { "CURSOR_PROJECT_DIR" => @repo })
    expect(status).to be_success

    _, stderr, status = run_cli("checkpoint", "--session", "cursor-session", input: JSON.generate(data.merge(
      "decisions" => ["Keep checkpoint history."],
    )))
    expect(status).to be_success
    expect(stderr).to eq("")

    stdout, _, status = run_cli("hook", "codex", input: JSON.generate({
      hook_event_name: "SessionStart", session_id: "codex-new-session", cwd: @repo,
    }))
    expect(status).to be_success
    context = JSON.parse(stdout).dig("hookSpecificOutput", "additionalContext")
    expect(context).to include("Keep checkpoint history.", "Tests pass.", "Commit changes.", "Tool: cursor")
  end

  it "uses CODEX_THREAD_ID to avoid updating another session" do
    newer = @store.digest_path("session2", time: Time.new(2099, 1, 1))
    original = File.read(@digest)
    File.write(newer, original)

    _, stderr, status = run_cli("checkpoint", env: { "CODEX_THREAD_ID" => "session1-full-id" })

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(File.read(@digest)).to include("Commit changes.")
    expect(File.read(newer)).to eq(original)
  end

  it "lets an explicit session override the environment" do
    _, stderr, status = run_cli("checkpoint", "--session", "session1-full-id", env: { "CODEX_THREAD_ID" => "unknown-session" })

    expect(status).to be_success
    expect(stderr).to eq("")
  end

  it "reports invalid JSON without a stack trace or digest changes" do
    original = File.read(@digest)
    stdout, stderr, status = run_cli("checkpoint", input: "{")

    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include("checkpoint: invalid JSON")
    expect(stderr).not_to include("cli.rb:")
    expect(File.read(@digest)).to eq(original)
  end

  it "explains missing fields without changing the digest" do
    original = File.read(@digest)
    _, stderr, status = run_cli("checkpoint", input: "{}")

    expect(status).not_to be_success
    expect(stderr).to include("missing checkpoint fields", "current_state", "next_step")
    expect(File.read(@digest)).to eq(original)
  end

  it "reports a missing input file" do
    _, stderr, status = run_cli("checkpoint", "--input", File.join(@repo, "missing.json"))

    expect(status).not_to be_success
    expect(stderr).to include("checkpoint:", "missing.json")
  end

  it "reports an unknown session instead of falling back to the latest digest" do
    original = File.read(@digest)
    _, stderr, status = run_cli("checkpoint", "--session", "unknown-session")

    expect(status).not_to be_success
    expect(stderr).to include("no digest", "unknown-session")
    expect(File.read(@digest)).to eq(original)
  end

  it "reports a missing digest and explains how to create one" do
    _, stderr, status = run_cli("checkpoint", env: { "SESSION_MEMORY_HOME" => File.join(@home, "empty") })

    expect(status).not_to be_success
    expect(stderr).to include("no digest", "start a session with hooks")
  end

  it "rejects a directory outside git" do
    _, stderr, status = run_cli("checkpoint", File.dirname(@repo))

    expect(status).not_to be_success
    expect(stderr).to include("not a git repo")
  end

  it "lists the command and its input options in help" do
    stdout, _, status = run_cli("help", input: "")

    expect(status).to be_success
    expect(stdout).to include("checkpoint [--session ID] [--input FILE]")
  end
end
