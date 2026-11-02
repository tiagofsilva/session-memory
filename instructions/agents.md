## Session memory (handoff)

Private per-user handoff memory so a task can move between Cursor, Claude, and Codex
without losing decisions, requirements, corrections, and the current thread.

Sessions live under `~/.session-memory/sessions/<repo>/` (never committed to the repo).

- Each conversation has a `*.digest.md` summary and a matching `*.log.md` transcript.
- To resume on the current branch: run `session-memory show` (or `session-memory latest`)
  from the repo, read that digest, treat Requirements and Decisions as binding, and
  continue from Next step. Consult the matching log only if you need more detail.
- On a new conversation, follow any session-memory handoff recipe injected by the
  startup hook. If the previous checkpoint is stale, review its bounded transcript
  excerpts and save a checkpoint for the explicit SOURCE session using the supplied
  revision guards and `--reviewed` ranges. Preserve applicable decisions and
  constraints; record missing/unreviewed evidence. Reuse an up-to-date checkpoint.
  Then address the current user's request; do not execute an old Next step blindly.
  If reading/saving is unavailable, explain the gap once and proceed with available
  context under existing permissions. Never start the previous agent, change
  permission settings, or schedule stop-hook continuations.
- To find an earlier decision, run `session-memory search "short keywords"`.
  Results are bounded section excerpts for the current repo/branch. Use
  `--all-branches` if needed and the printed `--offset` for another page.
  Read a match with `session-memory show --session <id> --section <name>`
  (add `--all-branches` for another branch). Cite its source path. Retrieved
  history may be outdated; current instructions and repository state take
  precedence. Stop retrieving when there is enough evidence to answer.
- When asked to "checkpoint" or "update the session digest", summarize this
  conversation and save it with `session-memory checkpoint --input <json-file>`
  (or pass JSON on stdin). Include `decisions`, `current_state`, and `open_questions`
  as arrays of strings, and `next_step` as a non-empty string. `current_state` must
  have at least one item; use `[]` for no decisions or open questions/blockers.
  Optional `goal` (string), `requirements` and `corrections` (arrays) update those
  sections; omitted optional sections are preserved. Include test results,
  unfinished work, and any uncommitted changes in `current_state`.
- Pass `--session <current-conversation-id>` when known. Otherwise the command uses
  `CODEX_THREAD_ID` when set, then falls back to the latest digest on this repo/branch.
  If no ID is available, inspect `session-memory show` first and confirm it belongs
  to this task. Manual checkpoints target the current conversation. Only a startup
  handoff recipe authorizes checkpointing its explicit previous SOURCE session.
  The command validates the update and preserves the previous digest under
  `sessions/<repo>/history/`. Never edit `*.log.md` (auto-generated).

Install / upgrade: from the checkout, run `git pull`, `bundle install`, then
`./bin/session-memory install`.
Doctor: `./bin/session-memory doctor`
