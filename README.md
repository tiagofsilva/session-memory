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

That seeds a digest (once per conversation), regenerates the matching log from the tool transcript when available, and injects the latest digest for the current repo/branch into the agent context at session start.

### Store layout

```
~/.session-memory/                     (mode 700)
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.digest.md
  sessions/<repo>/YYYY-MM-DD-HHMM-<repo>-<branch>-<shortid>.log.md
```

Worktrees share the parent repo's memory (via `git rev-parse --git-common-dir`).

### Resume

```sh
session-memory show          # print latest digest for cwd's repo+branch
session-memory latest        # print its path
```

Or tell the agent: "resume the session" / "checkpoint this session".

## Commands

| Command | Purpose |
| --- | --- |
| `install [--dry-run]` | Wire user-level hooks + instructions |
| `uninstall [--dry-run]` | Remove our hook entries (keeps the store) |
| `doctor` | Verify Ruby, configs, feature flag, store |
| `hook <tool>` | Invoked by harness hooks (stdin JSON) |
| `latest [repo]` | Path to newest digest for repo+branch |
| `show [repo]` | Print that digest |
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
