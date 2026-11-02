# frozen_string_literal: true

require "sqlite3"
require "tempfile"

module SessionMemory
  class Index
    class Error < StandardError; end

    SCHEMA_VERSION = 1
    MAX_RESULTS = 20
    SNIPPET_CHARS = 400

    def initialize(store:)
      @store = store
    end

    def path
      File.join(@store.root, "search.sqlite3")
    end

    def self.refresh_safely(store:, path:)
      new(store: store).refresh!(path)
    rescue SQLite3::Exception, Error, SystemCallError => e
      warn("session-memory: Markdown saved; search index update failed: #{e.message}. Run session-memory reindex.")
    end

    def refresh!(digest_path)
      # Capture and checkpoint hooks never wait behind a long search or rebuild.
      with_lock(nonblock: true) do
        with_database(path) do |db|
          db.transaction(:immediate) { import(db, digest_path, @store.repo_name) }
        end
      end
    end

    def search(query:, all_branches: false, limit: 5, offset: 0)
      raise Error, "limit must be between 1 and #{MAX_RESULTS}" unless (1..MAX_RESULTS).cover?(limit)
      raise Error, "offset must be between 0 and 10000" unless (0..10_000).cover?(offset)
      raise Error, "query must be at most 1000 characters" if query.length > 1000

      # Treat user input as literal keywords, including FTS operators and quotes.
      terms = query.scan(/[\p{L}\p{N}_]+/)
      raise Error, "provide at least one search keyword" if terms.empty?
      match = terms.map { |term| %Q{"#{term}"} }.join(" AND ")

      with_lock do
        with_database(path) do |db|
          db.transaction(:immediate) { sync_repo(db, @store.sessions_dir, @store.repo_name) }
          conditions = "sections MATCH ? AND d.repo = ?"
          binds = [match, @store.repo_name]
          unless all_branches
            conditions += " AND d.branch = ?"
            binds << @store.current_branch
          end
          rows = db.execute(<<~SQL, [*binds, limit + 1, offset])
            SELECT d.session_id, d.branch, d.tool, d.started_at, d.path,
                   sections.heading,
                   snippet(sections, 2, '[', ']', ' … ', 32) AS excerpt
            FROM sections JOIN documents d ON d.id = sections.document_id
            WHERE #{conditions}
            ORDER BY bm25(sections), d.started_at DESC, d.path, sections.rowid
            LIMIT ? OFFSET ?
          SQL
          {
            hits: rows.first(limit).map { |row| row.merge("excerpt" => excerpt(row.fetch("excerpt"))) },
            more: rows.length > limit,
          }
        end
      end
    end

    def rebuild!
      with_lock do
        Tempfile.create([".search-rebuild-", ".sqlite3"], @store.root) do |file|
          file.close
          count = with_database(file.path) do |db|
            db.transaction(:immediate) do
              Dir.glob(File.join(@store.root, "sessions", "*")).select { |dir| File.directory?(dir) }.sum do |dir|
                sync_repo(db, dir, File.basename(dir))
              end
            end
            db.get_first_value("SELECT count(*) FROM documents")
          end
          # Every CLI database connection uses the same lock and closes before replacement.
          %w[-journal -wal -shm].each do |suffix|
            File.delete("#{path}#{suffix}") if File.exist?("#{path}#{suffix}")
          end
          File.rename(file.path, path)
          count
        end
      end
    end

    private

    def excerpt(text)
      return text if text.length <= SNIPPET_CHARS

      start = [text.index("[").to_i - 80, 0].max
      "…#{text[start, SNIPPET_CHARS - 2]}…"
    end

    def with_lock(nonblock: false)
      @store.ensure!
      File.open(File.join(@store.root, ".search-index.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        mode = File::LOCK_EX | (nonblock ? File::LOCK_NB : 0)
        return unless lock.flock(mode)

        yield
      end
    end

    def with_database(database_path)
      File.open(database_path, File::RDWR | File::CREAT, 0o600) { }
      db = SQLite3::Database.new(database_path)
      db.results_as_hash = true
      db.busy_timeout = 250
      version = db.get_first_value("PRAGMA user_version")
      raise Error, "unsupported index schema #{version}; run session-memory reindex" if version > SCHEMA_VERSION

      if version.zero?
        db.transaction(:immediate) do
          db.execute_batch(<<~SQL)
            CREATE TABLE documents (
              id INTEGER PRIMARY KEY,
              path TEXT NOT NULL UNIQUE,
              repo TEXT NOT NULL,
              branch TEXT NOT NULL,
              session_id TEXT NOT NULL,
              tool TEXT NOT NULL,
              started_at TEXT NOT NULL,
              signature TEXT NOT NULL
            );
            CREATE INDEX documents_scope ON documents(repo, branch);
            CREATE VIRTUAL TABLE sections USING fts5(document_id UNINDEXED, heading, body, tokenize='unicode61');
            PRAGMA user_version = #{SCHEMA_VERSION};
          SQL
        end
      end
      yield db
    ensure
      db&.close
    end

    def sync_repo(db, directory, repo)
      paths = Dir.glob(File.join(directory, "*.digest.md"))
      known = db.execute("SELECT id, path FROM documents WHERE repo = ?", [repo])
      present = paths.to_h { |digest_path| [digest_path, true] }
      known.each { |row| remove(db, row.fetch("id")) unless present.key?(row.fetch("path")) }
      paths.each { |digest_path| import(db, digest_path, repo) }
      paths.size
    end

    def import(db, digest_path, repo)
      stat = File.stat(digest_path)
      signature = [stat.mtime.to_r, stat.ctime.to_r, stat.size, stat.ino].join(":")
      existing = db.get_first_row("SELECT id, signature FROM documents WHERE path = ?", [digest_path])
      return if existing && existing.fetch("signature") == signature

      text = File.binread(digest_path).force_encoding("UTF-8").scrub
      session_id = text[/\A# Session digest: ([^\r\n]+)/, 1]
      name = File.basename(digest_path)
      metadata = session_id && name.match(/\A(\d{4}-\d{2}-\d{2}-\d{4})-#{Regexp.escape(repo)}-(.+)-#{Regexp.escape(session_id)}\.digest\.md\z/)
      unless metadata
        remove(db, existing.fetch("id")) if existing
        return
      end

      tool = text[/^Date: .*? · Tool: ([^·\r\n]*)/, 1].to_s.strip
      remove(db, existing.fetch("id")) if existing
      db.execute(
        "INSERT INTO documents(path, repo, branch, session_id, tool, started_at, signature) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [digest_path, repo, metadata[2], session_id, tool, metadata[1], signature],
      )
      id = db.last_insert_row_id
      Digest.sections(text).each do |heading, body|
        db.execute("INSERT INTO sections(document_id, heading, body) VALUES (?, ?, ?)", [id, heading, body])
      end
    rescue Errno::ENOENT
      remove(db, existing.fetch("id")) if existing
    end

    def remove(db, id)
      db.execute("DELETE FROM sections WHERE document_id = ?", [id])
      db.execute("DELETE FROM documents WHERE id = ?", [id])
    end
  end
end
