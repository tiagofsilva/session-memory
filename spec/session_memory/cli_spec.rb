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

  it "searches saved checkpoint sections and reads a selected section" do
    run_cli("checkpoint", input: JSON.generate(data.merge("decisions" => ["Use SQLite for searchable memory."])))

    stdout, stderr, status = run_cli("search", "SQLite")
    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("Session session1", "Section: Decisions", "Source: #{@digest}", "[SQLite]")

    stdout, stderr, status = run_cli("show", "--session", "session1", "--section", "decisions")
    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to eq("## Decisions\n- Use SQLite for searchable memory.\n")
  end

  it "caps all search output including metadata and provides pagination" do
    8.times do |n|
      id = "extra#{n}"
      path = @store.digest_path(id)
      File.write(path, File.read(@digest).sub("Session digest: session1", "Session digest: #{id}"))
    end

    stdout, stderr, status = run_cli("search", "Original", "--limit", "8", "--max-chars", "1000")
    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout.length).to be <= 1000
    expect(stdout).to include("More matches available; continue with --offset")

    offset = stdout[/continue with --offset (\d+)/, 1]
    next_page, _, status = run_cli("search", "Original", "--offset", offset, "--max-chars", "1000")
    expect(status).to be_success
    first_ids = stdout.scan(/Session (\w+) \|/).flatten
    next_ids = next_page.scan(/Session (\w+) \|/).flatten
    expect(first_ids & next_ids).to be_empty
  end

  it "caps a large selected section and reports truncation" do
    File.write(@digest, File.read(@digest).sub("## Decisions\n- ", "## Decisions\n- #{'a' * 10_000}"))

    stdout, _, status = run_cli("show", "--session", "session1", "--section", "decisions", "--max-chars", "256")
    expect(status).to be_success
    expect(stdout.length).to be <= 256
    expect(stdout).to include("[truncated;")
  end

  it "can search and read another branch explicitly" do
    other = File.join(@store.sessions_dir, "2020-01-01-0000-#{@store.repo_name}-other-other123.digest.md")
    File.write(other, File.read(@digest).sub("Session digest: session1", "Session digest: other123").sub("Original goal", "branchonlyneedle"))

    stdout, _, status = run_cli("search", "branchonlyneedle")
    expect(status).to be_success
    expect(stdout).to include("No matches.")
    stdout, _, status = run_cli("search", "branchonlyneedle", "--all-branches")
    expect(status).to be_success
    expect(stdout).to include("Session other123", "| other |")

    stdout, _, status = run_cli("show", "--session", "other123", "--all-branches", "--section", "goal")
    expect(status).to be_success
    expect(stdout).to include("branchonlyneedle")
  end

  it "reindexes a broken database and retains the original digest" do
    original = File.read(@digest)
    File.write(File.join(@home, "search.sqlite3"), "broken database")
    stdout, stderr, status = run_cli("reindex")

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("Indexed 1 digest(s):")
    expect(File.read(@digest)).to eq(original)
    stdout, _, status = run_cli("search", "Original")
    expect(status).to be_success
    expect(stdout).to include("Session session1")
  end

  it "runs with its own dependencies inside another project's active bundle" do
    foreign_gemfile = File.join(@repo, "Gemfile")
    File.write(foreign_gemfile, "source 'https://rubygems.org'\n")
    application_lock = File.join(SessionMemory.tool_root, "Gemfile.lock")
    original_lock = File.read(application_lock)

    stdout, stderr, status = run_cli("search", "Original", env: {
      "BUNDLE_GEMFILE" => foreign_gemfile, "BUNDLE_LOCKFILE" => "#{foreign_gemfile}.lock", "RUBYOPT" => "-rbundler/setup",
    })
    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("Session session1")
    expect(File.read(foreign_gemfile)).to eq("source 'https://rubygems.org'\n")
    expect(File.read(application_lock)).to eq(original_lock)
  end

  it "loads the application bundle when launched directly without bundle exec" do
    stdout, stderr, status = run_cli("search", "Original", env: { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil })

    expect(status).to be_success
    expect(stderr).to eq("")
    expect(stdout).to include("Session session1")
  end

  it "lets hooks exit quietly when dependencies have not been installed" do
    stdout, stderr, status = run_cli("hook", "codex", env: {
      "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "BUNDLE_PATH" => File.join(@repo, "missing-gems"),
    })

    expect(status).to be_success
    expect(stdout).to eq("{}\n")
    expect(stderr).to include("dependencies unavailable", "bundle install")
  end

  it "rejects invalid search limits, budgets and empty queries" do
    [["--limit", "0"], ["--offset", "-1"], ["--max-chars", "100"], ["--limit", "21"]].each do |options|
      _, stderr, status = run_cli("search", "Original", *options)
      expect(status).not_to be_success
      expect(stderr).to include("search:")
    end
    _, stderr, status = run_cli("search", "!!!")
    expect(status).not_to be_success
    expect(stderr).to include("at least one search keyword")
  end
end
