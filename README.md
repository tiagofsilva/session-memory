# session-memory

Lightweight, private handoff memory so a coding task can move between Cursor, Claude Code, and Codex without losing decisions, requirements, corrections, and the current thread.

Sessions are **per person** and stored under `~/.session-memory/`. Nothing is written into your repositories. Install the same tool and keep their own sessions.

## Install

```sh
git clone <this-repo> ~/workspace/session-memory
cd ~/workspace/session-memory
./bin/session-memory install
./bin/session-memory doctor
```

`install` is idempotent. Re-run after `git pull` to upgrade hook wiring.

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

At session start, the hook injects the latest digest from another conversation on the current repo/branch. Delivery is tracked so it happens once per conversation. Claude Code and Codex can also deliver it on a prompt if startup did not deliver one. With no previous digest, nothing is injected.

Prompt and stop hooks seed this conversation's digest (once) and regenerate its matching log from the tool transcript when available.

### Store layout

```
~/.session-memory/                     (mode 700)
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.digest.md
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.log.md
  sessions/<repo>/history/<digest-name>/<timestamp>-<id>.digest.md
```

Worktrees share the parent repo's memory (via `git rev-parse --git-common-dir`).

### Resume

```sh
session-memory show          # print latest digest for cwd's repo+branch
session-memory latest        # print its path
```

Or tell the agent: "resume the session" / "checkpoint this session".

### Checkpoint

When you ask for a checkpoint, the agent summarizes the conversation and saves it
through the CLI. The command does not call an LLM or generate a summary itself.

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

## Commands

| Command | Purpose |
| --- | --- |
| `install [--dry-run]` | Wire user-level hooks + instructions |
| `uninstall [--dry-run]` | Remove our hook entries (keeps the store) |
| `doctor` | Verify Ruby, configs, feature flag, store |
| `hook <tool>` | Invoked by harness hooks (stdin JSON) |
| `latest [repo]` | Path to newest digest for repo+branch |
| `show [repo]` | Print that digest |
| `checkpoint [--session ID] [--input FILE] [repo]` | Validate and save a summary, keeping the previous version |
| `prune [--days N]` | Delete digests/logs older than N days (default 30) |

## Known limits

- **Cursor cloud / background agents** do not load user-level hooks (no home directory on the VM). Repos that need cloud coverage need a small committed `.cursor/hooks.json` shim that shells out to the same `session-memory hook cursor` command.
- Logs are raw transcripts and may contain secrets you paste into prompts. The store is mode `700`; use `prune` for retention.
- Outside a git repo the hook exits silently.

## Development

Runtime needs Ruby 3.0+ (stdlib only). Specs need Bundler:

```sh
bundle install
bundle exec rspec
```

## Uninstall

```sh
./bin/session-memory uninstall
# optionally: rm -rf ~/.session-memory
```
