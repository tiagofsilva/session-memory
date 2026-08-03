## Session memory (handoff)

Private per-user handoff memory so a task can move between Cursor, Claude, and Codex
without losing decisions, requirements, corrections, and the current thread.

Sessions live under `~/.session-memory/sessions/<repo>/` (never committed to the repo).

- Each conversation has a `*.digest.md` summary and a matching `*.log.md` transcript.
- To resume on the current branch: run `session-memory show` (or `session-memory latest`)
  from the repo, read that digest, treat Requirements and Decisions as binding, and
  continue from Next step. Consult the matching log only if you need more detail.
- When asked to "checkpoint" or "update the session digest", rewrite that digest's
  Decisions, Corrections, Current state, and Next step. Never edit `*.log.md`
  (auto-generated).

Install / upgrade: `git -C <session-memory-checkout> pull && ./bin/session-memory install`
Doctor: `./bin/session-memory doctor`
