# frozen_string_literal: true

require "spec_helper"

RSpec.describe SessionMemory::Checkpoint do
  around do |example|
    Dir.mktmpdir do |tmp|
      @repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(@repo)
      system("git", "init", "-b", "main", @repo, out: File::NULL, err: File::NULL)
      system("git", "-C", @repo, "-c", "user.name=Test", "-c", "user.email=t@example.com",
        "commit", "--allow-empty", "-m", "init", out: File::NULL, err: File::NULL)
      @store = SessionMemory::Store.new(repo_root: @repo, root: File.join(tmp, "memory"))
      @digest = @store.digest_path("session1", time: Time.new(2020, 1, 1))
      SessionMemory::Digest.write(
        path: @digest, short_id: "session1", tool: "cursor", model: "m",
        goal: "Original goal", log_path: @store.log_path(@digest), git_sha: "abc",
      )
      original = File.read(@digest)
      original.sub!("## Requirements / constraints\n- ", "## Requirements / constraints\n- Keep Ruby stdlib only.")
      original.sub!("## Corrections\n- ", "## Corrections\n- Preserve this correction.")
      File.write(@digest, original)
      File.write(@store.log_path(@digest), "Transcript stays untouched")
      @original = original
      example.run
    end
  end

  let(:checkpoint) { described_class.new(store: @store) }
  let(:data) do
    {
      "decisions" => ["Use the checkpoint command."],
      "current_state" => ["Implementation complete.", "Tests pass."],
      "open_questions" => [],
      "next_step" => "Review and commit the changes.",
    }
  end

  def history
    Dir.glob(File.join(@store.sessions_dir, "history", "**", "*.digest.md"))
  end

  it "updates the summary, preserving metadata, omitted fields, custom sections and the log" do
    File.write(@digest, "#{@original}\n## References\nKeep this reference.\n")
    before = File.read(@digest)

    result = checkpoint.write!(data: data)

    updated = File.read(@digest)
    expect(updated).to start_with(@original.split("## Goal").first)
    expect(updated).to include("## Goal\nOriginal goal", "- Keep Ruby stdlib only.", "- Preserve this correction.")
    expect(updated).to include("## Decisions\n- Use the checkpoint command.")
    expect(updated).to include("## Current state\n- Implementation complete.\n- Tests pass.")
    expect(updated).to include("## Open questions / blockers\n- None.")
    expect(updated).to include("## Next step\nReview and commit the changes.")
    expect(updated).to include("## References\nKeep this reference.")
    expect(File.read(@store.log_path(@digest))).to eq("Transcript stays untouched")
    expect(result[:digest]).to eq(@digest)
    expect(File.read(result[:previous_version])).to eq(before)
    expect(@store.latest_digest).to eq(@digest)
    [@digest, result[:previous_version]].each do |path|
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end
    expect(File.stat(File.dirname(result[:previous_version])).mode & 0o777).to eq(0o700)
  end

  it "can update the goal and explicitly clear optional sections" do
    checkpoint.write!(data: data.merge("goal" => "Updated goal", "requirements" => [], "corrections" => []))

    expect(File.read(@digest)).to include("## Goal\nUpdated goal", "## Requirements / constraints\n- None.", "## Corrections\n- None.")
  end

  it "adds the open questions section to older digests before the next step" do
    File.write(@digest, @original.sub("## Open questions / blockers\n- \n\n", ""))

    checkpoint.write!(data: data.merge("open_questions" => ["Waiting for review."]))

    expect(File.read(@digest)).to include("## Open questions / blockers\n- Waiting for review.\n\n## Next step")
  end

  it "preserves literal backslashes and indents multiline list entries" do
    checkpoint.write!(data: data.merge("decisions" => ["Use \\1 literally.\nKeep this detail."]))

    expect(File.read(@digest)).to include("- Use \\1 literally.\n  Keep this detail.")
  end

  it "keeps every previous version across repeated checkpoints" do
    first = checkpoint.write!(data: data)
    first_checkpoint = File.read(@digest)
    second = checkpoint.write!(data: data.merge("next_step" => "Ship it."))

    expect(history.size).to eq(2)
    expect(File.read(first[:previous_version])).to eq(@original)
    expect(File.read(second[:previous_version])).to eq(first_checkpoint)
    expect(File.read(@digest)).to include("Ship it.")
  end

  it "updates the requested session even when another session is newer" do
    newer = @store.digest_path("session2", time: Time.new(2021, 1, 1))
    File.write(newer, @original)

    checkpoint.write!(data: data, session_id: "session1-full-id")

    expect(File.read(@digest)).to include("Use the checkpoint command.")
    expect(File.read(newer)).to eq(@original)
  end

  {
    "a non-object input" => [],
    "missing fields" => { "current_state" => ["Done"] },
    "unknown fields" => { "next_action" => "Commit" },
    "empty state" => { "current_state" => [] },
    "a string instead of a list" => { "decisions" => "Use Ruby" },
    "a non-text list item" => { "open_questions" => [nil] },
    "a blank list item" => { "decisions" => ["  "] },
    "a blank next step" => { "next_step" => "\n " },
    "a non-text next step" => { "next_step" => [] },
    "a section heading inside a value" => { "next_step" => "Continue\n## Decisions\nInjected section" },
  }.each do |description, invalid|
    it "rejects #{description} without changing the digest or creating history" do
      input = description == "missing fields" || !invalid.is_a?(Hash) ? invalid : data.merge(invalid)

      expect { checkpoint.write!(data: input) }.to raise_error(described_class::Error)

      expect(File.read(@digest)).to eq(@original)
      expect(history).to be_empty
    end
  end

  it "rejects an unknown session instead of updating another conversation" do
    expect { checkpoint.write!(data: data, session_id: "unknown-session") }.to raise_error(described_class::Error, /no digest/)
    expect(File.read(@digest)).to eq(@original)
    expect(history).to be_empty
  end

  it "refuses to update a session from another branch" do
    system("git", "-C", @repo, "checkout", "-b", "other", out: File::NULL, err: File::NULL)

    expect { checkpoint.write!(data: data, session_id: "session1-full-id") }.to raise_error(described_class::Error, /no digest/)
    expect(File.read(@digest)).to eq(@original)
  end

  it "rejects a malformed existing digest without replacing it" do
    File.write(@digest, "handwritten text")

    expect { checkpoint.write!(data: data) }.to raise_error(described_class::Error, /invalid session digest/)
    expect(File.read(@digest)).to eq("handwritten text")
    expect(history).to be_empty
  end

  it "does not mistake a branch with the same prefix for the current branch" do
    system("git", "-C", @repo, "checkout", "-b", "main-extra", out: File::NULL, err: File::NULL)
    other = @store.digest_path("session2")
    File.write(other, @original)
    system("git", "-C", @repo, "checkout", "main", out: File::NULL, err: File::NULL)

    expect { checkpoint.write!(data: data, session_id: "session2-full-id") }.to raise_error(described_class::Error, /no digest/)
    expect(File.read(other)).to eq(@original)
  end

  it "leaves the digest intact and cleans up the temporary file if replacement fails" do
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(anything, @digest).and_raise(Errno::EIO)

    expect { checkpoint.write!(data: data) }.to raise_error(Errno::EIO)

    expect(File.read(@digest)).to eq(@original)
    expect(history.size).to eq(1)
    expect(File.read(history.first)).to eq(@original)
    expect(Dir.glob(File.join(@store.sessions_dir, "**", ".checkpoint-*.tmp"))).to be_empty
  end
end
