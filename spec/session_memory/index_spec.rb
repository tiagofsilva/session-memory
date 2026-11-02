# frozen_string_literal: true

require "spec_helper"

RSpec.describe SessionMemory::Index do
  around do |example|
    Dir.mktmpdir do |tmp|
      @repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(@repo)
      system("git", "init", "-b", "main", @repo, out: File::NULL, err: File::NULL)
      system("git", "-C", @repo, "-c", "user.name=Test", "-c", "user.email=t@example.com",
        "commit", "--allow-empty", "-m", "init", out: File::NULL, err: File::NULL)
      @store = SessionMemory::Store.new(repo_root: @repo, root: File.join(tmp, "memory"))
      @store.ensure!
      example.run
    end
  end

  let(:index) { described_class.new(store: @store) }

  def digest(id: "session1", branch: "main", repo: @store.repo_name, decision: "Use atomic writes for checkpoints.")
    directory = File.join(@store.root, "sessions", repo)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "2020-01-01-0000-#{repo}-#{branch}-#{id}.digest.md")
    SessionMemory::Digest.write(
      path: path, short_id: id, tool: "cursor", model: "m", goal: "Build memory",
      log_path: @store.log_path(path), git_sha: "abc",
    )
    File.write(path, File.read(path).sub("## Decisions\n- ", "## Decisions\n- #{decision}"))
    path
  end

  it "indexes existing digests by section and returns source metadata" do
    path = digest
    original = File.read(path)

    result = index.search(query: "atomic writes")

    expect(result[:hits].size).to eq(1)
    expect(result[:hits].first).to include("session_id" => "session1", "branch" => "main", "tool" => "cursor", "path" => path, "heading" => "Decisions")
    expect(result[:hits].first.fetch("excerpt")).to include("[atomic]", "[writes]")
    expect(File.read(path)).to eq(original)
    expect(File.stat(index.path).mode & 0o777).to eq(0o600)
  end

  it "filters by repository and the exact branch, with an explicit all-branches option" do
    digest
    digest(id: "session2", branch: "main-extra")
    digest(id: "session3", repo: "other-repo")
    index.rebuild!

    expect(index.search(query: "atomic")[:hits].map { |hit| hit["session_id"] }).to eq(["session1"])
    expect(index.search(query: "atomic", all_branches: true)[:hits].map { |hit| hit["session_id"] }).to contain_exactly("session1", "session2")
  end

  it "ignores transcripts and previous checkpoint versions" do
    path = digest(decision: "A different decision")
    File.write(@store.log_path(path), "transcriptonlyneedle")
    history = File.join(@store.sessions_dir, "history", "old")
    FileUtils.mkdir_p(history)
    File.write(File.join(history, File.basename(path)), File.read(path).sub("A different decision", "historyonlyneedle"))

    expect(index.search(query: "transcriptonlyneedle")[:hits]).to be_empty
    expect(index.search(query: "historyonlyneedle")[:hits]).to be_empty
    expect(index.rebuild!).to eq(1)
  end

  it "does not reread unchanged documents on subsequent searches" do
    path = digest
    index.search(query: "atomic")
    expect(File).not_to receive(:binread).with(path)

    expect(index.search(query: "atomic")[:hits].size).to eq(1)
  end

  it "refreshes manual edits even when the size and modification time are unchanged" do
    path = digest(decision: "Choose apples.")
    index.search(query: "apples")
    mtime = File.mtime(path)
    File.write(path, File.read(path).sub("apples", "orange"))
    File.utime(mtime, mtime, path)

    expect(index.search(query: "apples")[:hits]).to be_empty
    expect(index.search(query: "orange")[:hits].size).to eq(1)
  end

  it "removes deleted files from search results" do
    path = digest
    index.search(query: "atomic")
    File.delete(path)

    expect(index.search(query: "atomic")[:hits]).to be_empty
  end

  it "keeps result counts and snippets bounded and supports pagination" do
    4.times { |n| digest(id: "session#{n}", decision: "#{'x' * 10_000} atomic checkpoint") }

    first = index.search(query: "atomic", limit: 2)
    second = index.search(query: "atomic", limit: 2, offset: 2)

    expect(first[:more]).to be(true)
    expect(second[:more]).to be(false)
    expect(first[:hits].size).to eq(2)
    expect(first[:hits].map { |hit| hit["session_id"] } & second[:hits].map { |hit| hit["session_id"] }).to be_empty
    first[:hits].each do |hit|
      expect(hit.fetch("excerpt").length).to be <= 400
      expect(hit.fetch("excerpt")).to include("[atomic]")
    end
  end

  it "treats punctuation, quotes, and FTS operator names as literal keyword input" do
    digest(decision: "Use OR with atomic writes.")

    expect(index.search(query: '"OR" atomic')[:hits].size).to eq(1)
    expect(index.search(query: "atomic'); DROP TABLE documents;--")[:hits]).to be_empty
    expect(index.search(query: "atomic")[:hits].size).to eq(1)
  end

  it "rebuilds a damaged database from all repositories without changing Markdown" do
    first = digest
    second = digest(id: "session2", repo: "other-repo")
    originals = [first, second].to_h { |path| [path, File.read(path)] }
    File.write(index.path, "broken database")

    expect(index.rebuild!).to eq(2)
    expect(index.search(query: "atomic")[:hits].size).to eq(1)
    originals.each { |path, text| expect(File.read(path)).to eq(text) }
  end

  it "recreates a missing database and skips malformed digests" do
    digest
    File.write(File.join(@store.sessions_dir, "invalid.digest.md"), "Not a digest")
    index.search(query: "atomic")
    File.delete(index.path)

    expect(index.search(query: "atomic")[:hits].size).to eq(1)
  end

  it "skips immediate indexing while another operation holds the lock" do
    path = digest
    File.open(File.join(@store.root, ".search-index.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      expect(index.refresh!(path)).to be_nil
      expect(File.exist?(index.path)).to be(false)
    end

    expect(index.search(query: "atomic")[:hits].size).to eq(1)
  end

  it "keeps a successful checkpoint when SQLite indexing fails" do
    path = digest
    File.write(index.path, "broken database")
    data = { "decisions" => ["Use SQLite."], "current_state" => ["Complete."], "open_questions" => [], "next_step" => "Review." }

    expect { SessionMemory::Checkpoint.new(store: @store).write!(data: data) }.to output(/Markdown saved; search index update failed/).to_stderr

    expect(File.read(path)).to include("Use SQLite.")
  end

  it "indexes checkpoint updates immediately" do
    digest
    index.search(query: "atomic")
    data = { "decisions" => ["Use SQLite."], "current_state" => ["Complete."], "open_questions" => [], "next_step" => "Review." }
    SessionMemory::Checkpoint.new(store: @store).write!(data: data)

    SQLite3::Database.new(index.path) do |db|
      expect(db.get_first_value("SELECT count(*) FROM sections WHERE sections MATCH 'SQLite'")).to eq(1)
      expect(db.get_first_value("SELECT count(*) FROM sections WHERE sections MATCH 'atomic'")).to eq(0)
    end
  end

  ["", "!!!", "x" * 1001].each do |query|
    it "rejects an empty or oversized query (#{query.length} characters)" do
      expect { index.search(query: query) }.to raise_error(described_class::Error)
    end
  end
end
