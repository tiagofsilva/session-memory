# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe SessionMemory::Handoff do
  around do |example|
    Dir.mktmpdir do |tmp|
      @repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(@repo)
      system("git", "init", "-b", "main", @repo, out: File::NULL, err: File::NULL)
      system("git", "-C", @repo, "-c", "user.name=Test", "-c", "user.email=t@example.com",
        "commit", "--allow-empty", "-m", "init", out: File::NULL, err: File::NULL)
      @home = File.join(tmp, "memory")
      @store = SessionMemory::Store.new(repo_root: @repo, root: @home)
      example.run
    end
  end

  let(:handoff) { described_class.new(store: @store) }
  let(:data) do
    {
      "decisions" => ["Keep feature A compatible with existing clients."],
      "current_state" => ["Feature A implementation started; saved transcript reports tests pass."],
      "open_questions" => [], "next_step" => "Continue with the user's current request.",
    }
  end

  def native_record(tool, text)
    content = [{ type: "text", text: text }]
    case tool
    when "codex" then { type: "response_item", payload: { type: "message", role: "assistant", content: content } }
    when "claude" then { type: "assistant", message: { content: content } }
    when "cursor" then { role: "assistant", message: { content: content } }
    end
  end

  def source(id: "source01", tool: "codex", branch: "main", text: "Feature A implementation started. Tests pass.", activity: nil)
    @store.ensure!
    path = File.join(@store.sessions_dir, "2020-01-01-0000-#{@store.repo_name}-#{branch}-#{id}.digest.md")
    SessionMemory::Digest.write(path: path, short_id: id, tool: tool, model: "m", goal: "Build feature A",
      log_path: @store.log_path(path), git_sha: "abc")
    transcript = File.join(@repo, "#{id}.jsonl")
    File.write(transcript, native_record(tool, text).to_json + "\n")
    File.utime(activity, activity, transcript) if activity
    body = SessionMemory::Transcripts.render(tool, transcript)
    SessionMemory::Digest.write_log(path: @store.log_path(path), tool: tool, short_id: id,
      source: transcript, body: body, placeholder: "unavailable")
    state = SessionMemory::SessionState.new(store: @store, digest_path: path)
    state.capture!(body: body, source: transcript)
    [path, transcript, state]
  end

  def run_cli(*args, input: "")
    Open3.capture3({ "SESSION_MEMORY_HOME" => @home, "CODEX_THREAD_ID" => nil },
      RbConfig.ruby, SessionMemory.bin_path, *args, stdin_data: input, chdir: @repo)
  end

  def save_review(state, range: nil, questions: [])
    snapshot = state.snapshot
    SessionMemory::Checkpoint.new(store: @store).write!(
      data: data.merge("open_questions" => questions), session_id: snapshot[:id],
      transcript_revision: snapshot[:revision], expected_digest: snapshot[:digest_revision],
      reviewed: range || [[0, snapshot[:text].length]],
    )
  end

  [["codex", "claude"], ["claude", "cursor"], ["cursor", "codex"], ["codex", "codex"]].each do |sender, receiver|
    it "prepares #{sender} history in a new #{receiver} session, saves the source and reuses the result" do
      path, _, state = source(tool: sender)
      snapshot = state.snapshot
      payload = { hook_event_name: "SessionStart", session_id: "receiver-full-id", conversation_id: "receiver-full-id",
        cwd: @repo, workspace_roots: [@repo] }
      stdout, stderr, status = run_cli("hook", receiver, input: payload.to_json)
      expect(status).to be_success
      expect(stderr).to eq("")
      context = case receiver
      when "codex" then JSON.parse(stdout).dig("hookSpecificOutput", "additionalContext")
      when "cursor" then JSON.parse(stdout).fetch("additional_context")
      when "claude" then stdout
      end
      expect(context).to include("Source session: source01 (#{sender})", "stale or incomplete", "transcript --session source01")
      expect(context).to include("--expected-digest #{snapshot[:digest_revision]}", "current user's request")
      expect(context.length).to be <= described_class::CONTEXT_LIMIT + 1

      stdout, _, status = run_cli("hook", receiver, input: payload.to_json)
      expect(status).to be_success
      expect(stdout.strip).to eq(receiver == "claude" ? "" : "{}")

      event = receiver == "cursor" ? "beforeSubmitPrompt" : "UserPromptSubmit"
      run_cli("hook", receiver, input: payload.merge(hook_event_name: event, prompt: "My new request").to_json)
      receiving_path = @store.session_digest("receiver-full-id")
      receiving_digest = File.read(receiving_path)

      stdout, stderr, status = run_cli("transcript", "--session", "source01", "--revision", snapshot[:revision], "--offset", "0")
      expect(status).to be_success
      expect(stderr).to eq("")
      expect(stdout).to include("Feature A implementation started", "Reviewed range: 0:#{snapshot[:text].length}")
      range = stdout[/Reviewed range: (\d+:\d+)/, 1]
      stdout, stderr, status = run_cli("checkpoint", "--session", "source01", "--transcript-revision", snapshot[:revision],
        "--expected-digest", snapshot[:digest_revision], "--reviewed", range, input: data.to_json)
      expect(status).to be_success
      expect(stderr).to eq("")
      expect(stdout).to include("Checkpoint saved: #{path}")
      expect(File.read(path)).to include("Tool: #{sender}", "Keep feature A compatible")
      expect(File.read(receiving_path)).to eq(receiving_digest)
      expect(state.current?(state.snapshot)).to be(true)

      context = handoff.prepare(current_session_id: "receiver-full-id", from: "source01")
      expect(context).to include("latest available transcript activity; reuse it")
      expect(context).not_to include("--transcript-revision")
      expect(SessionMemory::Index.new(store: @store).search(query: "compatible")[:hits].first.fetch("session_id")).to eq("source01")
    end
  end

  it "chooses actual recent activity rather than filename order or checkpoint save time" do
    path, _, state = source(id: "zzzzzzzz", activity: Time.at(1000))
    newest, = source(id: "aaaaaaaa", activity: Time.at(2000))
    save_review(state)

    expect(@store.latest_active_digest).to eq(newest)
    expect(handoff.prepare(current_session_id: "new-session")).to include("Source session: aaaaaaaa")
    expect(File.mtime(path)).to be > Time.at(2000)
  end

  it "does not promote an unchanged log merely because its generated header was rewritten" do
    path, transcript, state = source(activity: Time.at(1000))
    save_review(state)
    initial = state.read.fetch("activity_at")
    body = SessionMemory::Transcripts.render("codex", transcript)
    SessionMemory::Digest.write_log(path: @store.log_path(path), tool: "codex", short_id: "source01",
      source: transcript, body: body, placeholder: "unavailable")
    state.capture!(body: body, source: transcript, now: 9000)

    expect(state.read.fetch("activity_at")).to eq(initial)
    expect(SessionMemory::SessionState.activity_at(@store, path)).to eq(1000)
    expect(state.current?(state.snapshot)).to be(true)
  end

  it "excludes the receiving session and a branch whose name extends the current branch" do
    source
    source(id: "receiver", activity: Time.at(2_000_000_000))
    source(id: "other001", branch: "main-extra", activity: Time.at(2_000_000_001))

    context = handoff.prepare(current_session_id: "receiver-full-id")
    expect(context).to include("Source session: source01")
    expect(context).not_to include("Source session: other001", "Source session: receiver")
  end

  it "detects native work added after the last capture and checkpoint" do
    _, transcript, state = source
    save_review(state)
    covered = state.snapshot[:text].length
    File.open(transcript, "a") { |file| file.puts(native_record("codex", "New work: feature B remains unfinished.").to_json) }

    snapshot = state.snapshot
    expect(state.current?(snapshot)).to be(false)
    expect(state.uncovered_start(snapshot)).to eq(covered)
    output = handoff.transcript(session_id: "source01", revision: snapshot[:revision], offset: covered)
    expect(output).to include("feature B remains unfinished")
    expect(output).not_to include("Feature A implementation started")
    save_review(state, range: [[covered, snapshot[:text].length]])
    expect(state.gaps(snapshot[:text].length, state.read.fetch("reviewed"))).to be_empty
  end

  it "rejects changed source activity and preserves the saved digest" do
    path, transcript, state = source
    original = File.read(path)
    old = state.snapshot
    File.open(transcript, "a") { |file| file.puts(native_record("codex", "New source activity").to_json) }

    expect { handoff.transcript(session_id: "source01", revision: old[:revision]) }.to raise_error(described_class::Error, /changed/)
    expect do
      SessionMemory::Checkpoint.new(store: @store).write!(data: data, session_id: "source01",
        transcript_revision: old[:revision], expected_digest: old[:digest_revision], reviewed: [[0, old[:text].length]])
    end.to raise_error(SessionMemory::Checkpoint::Error, /transcript changed/)
    expect(File.read(path)).to eq(original)
  end

  it "rejects a digest edited by another writer after preparation" do
    path, _, state = source
    old = state.snapshot
    updated = File.read(path).sub("Build feature A", "New user correction")
    File.write(path, updated)

    expect do
      SessionMemory::Checkpoint.new(store: @store).write!(data: data, session_id: "source01",
        transcript_revision: old[:revision], expected_digest: old[:digest_revision], reviewed: [[0, old[:text].length]])
    end.to raise_error(SessionMemory::Checkpoint::Error, /digest changed/)
    expect(File.read(path)).to eq(updated)
  end

  it "bounds transcript output, records review gaps, and retains them until reviewed" do
    _, _, state = source(text: "Earlier decisions: #{'å' * 20_000}\nLatest work: feature A is unfinished.")
    snapshot = state.snapshot
    output = handoff.transcript(session_id: "source01", max_chars: 6000)
    expect(output.length).to be <= 6000
    expect(output).to include("Latest work: feature A is unfinished")
    start, finish = output.match(/Reviewed range: (\d+):(\d+)/).captures.map(&:to_i)
    save_review(state, range: [[start, finish]])

    expect(File.read(state.digest_path)).to include(SessionMemory::SessionState::COVERAGE_NOTE)
    context = handoff.prepare(current_session_id: "new-session")
    expect(context).to include("reuse it", "unreviewed character ranges")
    expect(context).not_to include("--transcript-revision")
    save_review(state, range: [[0, start]], questions: ["A real blocker remains", SessionMemory::SessionState::COVERAGE_NOTE + "old gap"])
    expect(state.gaps(snapshot[:text].length, state.read.fetch("reviewed"))).to be_empty
    expect(File.read(state.digest_path)).not_to include(SessionMemory::SessionState::COVERAGE_NOTE)
    expect(File.read(state.digest_path)).to include("A real blocker remains")
  end

  it "caps startup context and preserves useful instructions when the digest is huge" do
    path, = source
    File.write(path, File.read(path).sub("Build feature A", "Goal #{'x' * 30_000}"))

    text = handoff.prepare(current_session_id: "new-session")
    expect(text.length).to be <= 8000
    expect(text).to include("--expected-digest", "digest truncated", "Follow the current user's request")
  end

  it "uses captured evidence if the native transcript disappears and preserves it on later hooks" do
    path, transcript, state = source
    File.delete(transcript)
    before = File.read(@store.log_path(path))
    payload = { hook_event_name: "Stop", session_id: "source01-full-id", cwd: @repo, transcript_path: transcript }
    _, _, status = run_cli("hook", "codex", input: payload.to_json)

    expect(status).to be_success
    expect(File.read(@store.log_path(path))).to eq(before)
    expect(state.snapshot[:text]).to include("Feature A implementation started")
    expect(handoff.prepare(current_session_id: "new-session")).to include("last captured log", "uncaptured activity cannot be verified")
  end

  it "reports unavailable evidence without modifying the previous digest" do
    path, transcript, = source
    File.delete(transcript)
    File.delete(@store.log_path(path))
    original = File.read(path)

    text = handoff.prepare(current_session_id: "new-session")
    expect(text).to include("transcript is unavailable", "Build feature A")
    expect(text).not_to include("--transcript-revision")
    expect(File.read(path)).to eq(original)
  end

  it "prepares and reads evidence without creating files or chmodding the store" do
    source
    expect(File).not_to receive(:chmod)
    expect(File).not_to receive(:rename)
    expect(FileUtils).not_to receive(:mkdir_p)

    expect(handoff.prepare(current_session_id: "new-session")).to include("Source session: source01")
    expect(handoff.transcript(session_id: "source01")).to include("Feature A implementation started")
    expect(@store.latest_digest).not_to be_nil
  end

  it "does nothing when no other session exists and rejects using the current conversation as its source" do
    expect(handoff.prepare(current_session_id: "receiver")).to be_nil
    source(id: "receiver")
    expect(handoff.prepare(current_session_id: "receiver-full-id")).to be_nil
    expect { handoff.prepare(current_session_id: "receiver-full-id", from: "receiver") }.to raise_error(described_class::Error, /another conversation/)
  end

  it "rejects invalid read budgets and ranges" do
    _, _, state = source
    snapshot = state.snapshot
    expect { handoff.transcript(session_id: "source01", offset: -1) }.to raise_error(described_class::Error, /offset/)
    expect { handoff.transcript(session_id: "source01", max_chars: 999) }.to raise_error(described_class::Error, /max-chars/)
    expect do
      SessionMemory::Checkpoint.new(store: @store).write!(data: data, session_id: "source01",
        transcript_revision: snapshot[:revision], expected_digest: snapshot[:digest_revision], reviewed: [[0, snapshot[:text].length + 1]])
    end.to raise_error(SessionMemory::Checkpoint::Error, /reviewed ranges/)
  end
end
