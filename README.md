# session-memory

Lightweight, private handoff memory so a coding task can move between Cursor, Claude Code, and Codex without losing decisions, requirements, corrections, and the current thread.

Sessions are **per person** and stored under `~/.session-memory/`. Nothing is written into your repositories. Install the same tool and keep their own sessions.

## Install

```sh
git clone <this-repo> ~/workspace/session-memory
cd ~/workspace/session-memory
bundle install
./bin/session-memory install
./bin/session-memory doctor
```

Runtime requires Ruby 3.2+ and the `sqlite3` gem. `bundle install` installs the
locked dependencies; SQLite runs locally without a database service.

`install` is idempotent. After `git pull`, run `bundle install` and re-run
`install` to upgrade dependencies, hook wiring, and agent instructions. The CLI
loads its own bundle even when launched from a different project's directory.

If Codex hooks are not enabled yet, the installer prints the exact lines to add to `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

Older Codex versions used `codex_hooks = true`; that name still works but is deprecated, so rename it to `hooks`.

Codex may ask you to trust the hook via `/hooks` on first use.

## How it works

On each prompt / session start / stop, a user-level hook calls:

```sh
<path-to-ruby> <checkout>/bin/session-memory hook <cursor|codex|claude>
```

At session start, the hook selects the most recently active other conversation on
the current repo/branch. It injects its digest and, when needed, a recipe for the
incoming agent to prepare a checkpoint from saved activity. Delivery is tracked
so this happens once per receiving conversation. Claude Code and Codex can also
deliver it on a prompt if startup did not deliver one. With no previous session,
nothing is injected. Stop hooks only refresh capture; they never request an agent
continuation.

Prompt and stop hooks seed this conversation's digest (once) and regenerate its matching log from the tool transcript when available.

### Store layout

```
~/.session-memory/                     (mode 700)
  search.sqlite3                      (mode 600; rebuildable index)
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.digest.md
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.log.md
  sessions/<repo>/history/<digest-name>/<timestamp>-<id>.digest.md
  sessions/<repo>/.session-<hash>.json   (mode 600; activity/coverage receipts)
```

Worktrees share the parent repo's memory (via `git rev-parse --git-common-dir`).

### Resume

```sh
session-memory show          # print latest digest for cwd's repo+branch
session-memory latest        # print its path
```

Or tell the agent: "resume the session" / "checkpoint this session".

### Checkpoint when handing work to another session

Suppose you work on feature A in Codex and then open Claude Code on the same
branch. The incoming Claude session receives the previous session's digest. If
that digest is stale or incomplete, Claude is instructed to read bounded excerpts
of Codex's saved activity and checkpoint **the Codex session**, then address your
current request. Codex does not have to remain running. The same flow works when
opening another conversation in the same agent.

The source is selected by captured activity and native transcript changes, rather
than filename order or the time someone later edited its digest. The receiving
session and other branches are excluded. Existing, up-to-date checkpoints are
reused. Legacy digests without coverage receipts get one evidence review when a
transcript is available.

To inspect or refresh a handoff recipe explicitly:

```sh
session-memory handoff --current <receiving-session-id>
session-memory handoff --from <source-session-id>
session-memory transcript --session <source-session-id> --max-chars 6000
```

Startup context is capped at 8,000 characters. A transcript read defaults to a
recent window of up to 4,000 source characters within a total 6,000-character
output budget. `--offset` reads another window; `--max-chars` accepts 1,000–20,000.
The receiving agent is instructed to stay within 20,000 characters of transcript
output in total. Earlier history may remain unreviewed; that gap is recorded in
the checkpoint rather than claimed as covered. The current user's request always
takes precedence over historical instructions or an old Next step.

Transcript output includes a snapshot revision, digest revision, and reviewed
character range. The recipe supplies a guarded save command:

```sh
session-memory checkpoint --session <source-id> \
  --transcript-revision <revision> --expected-digest <digest-revision> \
  --reviewed <start>:<end> --input /tmp/checkpoint.json
```

Pass ranges for the excerpts actually reviewed, repeating `--reviewed` for extra
chunks. The command rejects a changed source transcript or digest and preserves
the old note. Receipts identify the source snapshot represented by the checkpoint
and retain any review gaps. If a later transcript extends that snapshot, the next
handoff can focus on the new activity while keeping earlier gaps visible.

When the native transcript is available, handoff reads can include work captured
there after the last hook. Otherwise the last useful captured log is used and its
limits are reported. Missing evidence never replaces a useful capture with an
empty placeholder. If neither source is available, the existing digest is kept
and the gap is explained. Logs remain generated from transcripts, never edited
by the receiving agent.

Digest, handoff and transcript reads do not modify the store or its permissions.
Saving checkpoints requires the agent's normal access to the private store. If a
save is unavailable, the agent should explain that once and continue with the
available context; it must not change permission settings or start the old agent.
The hook/CLI flow is integration-tested; summary quality and actual writes depend
on the receiving agent and its existing permissions.

### Checkpoint

You can also ask for a checkpoint at any time. The agent summarizes the conversation
and saves it through the CLI. The command does not call an LLM or generate a summary itself.

Save a JSON file such as `/tmp/checkpoint.json`:

```json
{
  "decisions": ["Keep the runtime dependency-free."],
  "current_state": ["Checkpoint command implemented; tests pass; changes are uncommitted."],
  "open_questions": [],
  "next_step": "Review and commit the changes."
}
```

From the repository, run:

```sh
session-memory checkpoint --input /tmp/checkpoint.json
# Or supply the same JSON on stdin:
session-memory checkpoint < /tmp/checkpoint.json
# Target a specific conversation when several sessions are open:
session-memory checkpoint --session <conversation-id> --input /tmp/checkpoint.json
```

All four example fields are required. Lists must contain non-empty strings;
`current_state` needs at least one item and `next_step` must be a non-empty string.
Empty `decisions` and `open_questions` lists explicitly record "None." Optional
`goal` (string), `requirements` and `corrections` (arrays of strings) replace those
sections when supplied. Omitted optional sections, session metadata, and custom
sections are preserved. Unknown fields and values containing level-two Markdown
headings (`## `) are rejected.

The target is `--session`, then `CODEX_THREAD_ID` if set, otherwise the latest
digest for the current repo/branch. A missing target is an error; checkpointing
does not create a new conversation. With no known session ID, inspect
`session-memory show` to verify the latest digest belongs to your task first.

Each save keeps the previous digest in `sessions/<repo>/history/` and atomically
replaces the current digest. Logs are untouched. Checkpoint writes to the same
digest are serialized. History is excluded from handoff selection and is retained
when `prune` removes old session digests and logs.

Re-run `./bin/session-memory install` after upgrading to refresh the agent
instructions for this command.

### Search older decisions

Ask your agent, for example: "Find why we chose atomic writes for checkpoints."
The agent can search with a few relevant keywords, then read the matching section:

```sh
session-memory search "atomic writes"
session-memory search "atomic writes" --all-branches
session-memory show --session <id> --section decisions
session-memory show --session <id> --section decisions --all-branches --max-chars 2000
```

Search uses SQLite FTS5 and returns ranked **section matches** from the current
repo/branch. All query keywords must occur in the same section; punctuation is
treated as separators, and query words are interpreted literally. Results include
the session ID, branch, date, tool, section name, source path, and a short excerpt.
Transcripts and previous checkpoint versions are excluded.

The default is five matches with excerpts of at most 400 characters and a total
output budget of 6,000 characters, including metadata. `--limit` accepts 1–20 and
`--max-chars` accepts 512–20,000. When results remain, the command prints the next
`--offset` to request. If a single result cannot fit, increase the output budget.
Selected-section reads default to 4,000 characters and report truncation. Plain
`show` keeps its existing full-digest behavior.

Markdown remains the source of truth. New captured digests and checkpoints update
the index automatically. Search reconciles manual edits and deleted digests,
checking file metadata so unchanged bodies do not have to be reread. Capture and
checkpoint saves skip a busy index and let the next search catch up. An index
failure leaves the saved Markdown available for handoffs.

To recreate the entire index from all repositories' current digests:

```sh
session-memory reindex
```

First searches automatically import existing digests for the current repository;
running `reindex` in advance is optional. It also replaces a damaged database.
`doctor` checks that the Ruby selected for hooks can load SQLite with FTS5.

## Commands

| Command | Purpose |
| --- | --- |
| `install [--dry-run]` | Wire user-level hooks + instructions |
| `uninstall [--dry-run]` | Remove our hook entries (keeps the store) |
| `doctor` | Verify Ruby, SQLite/FTS5, configs, feature flag, store |
| `hook <tool>` | Invoked by harness hooks (stdin JSON) |
| `latest [repo]` | Path to newest digest for repo+branch |
| `show [--session ID] [--section NAME] [--max-chars N] [--all-branches] [repo]` | Read a digest or a bounded section |
| `checkpoint [--session ID] [--input FILE] [repo]` | Validate and save a summary, keeping the previous version |
| `handoff [--from ID] [--current ID] [repo]` | Prepare a handoff from another session on this branch |
| `transcript --session ID [--revision HASH] [--offset N] [--max-chars N] [repo]` | Read a bounded source transcript window |
| `search "keywords" [--all-branches] [--limit N] [--offset N] [--max-chars N] [repo]` | Search digest sections with bounded output |
| `reindex [repo]` | Rebuild SQLite from all repositories' current digests |
| `prune [--days N]` | Delete digests/logs older than N days (default 30) |

## Known limits

- **Cursor cloud / background agents** do not load user-level hooks (no home directory on the VM). Repos that need cloud coverage need a small committed `.cursor/hooks.json` shim that shells out to the same `session-memory hook cursor` command.
- Logs are raw transcripts and may contain secrets you paste into prompts. The store is mode `700`; use `prune` for retention.
- Outside a git repo the hook exits silently.

## Development

Runtime needs Ruby 3.2+ and SQLite through the `sqlite3` gem. Specs use RSpec:

```sh
bundle install
bundle exec rspec
```

## Uninstall

```sh
./bin/session-memory uninstall
# optionally: rm -rf ~/.session-memory
```
