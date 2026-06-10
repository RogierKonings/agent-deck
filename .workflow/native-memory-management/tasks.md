# Tasks — Native Swift memory management for Agent Deck

| # | Task | Character | Depends on | Output |
|---|------|-----------|------------|--------|
| 1 | ✅ Map `/Users/rogierkonings/.pi/agent/extensions/memory` behavior and current Agent Deck memory architecture without editing files | context-builder | — | `.workflow/native-memory-management/context.md` |
| 2 | ✅ Produce an ordered Swift/UI/test implementation plan with file-level changes and migration risks | planner | 1 | `.workflow/native-memory-management/plan.md` |
| 3 | ✅ Completed native Swift memory management implementation with full Pi `/dream` phase/action parity and project-scoped apply fix | worker | 2 + final review/product decision | branch `side-agent/dream-parity`; commits through `7d677c4`; `.workflow/native-memory-management/implementation.md` |
| 4 | ✅ Review implementation for correctness, UI consistency, storage safety, and duplicate-tool-registration regressions | reviewer | 3 | `.workflow/native-memory-management/review.md` (approve to verifier) |
| 5 | Verify implementation against `spec.md` with build/test evidence and acceptance-criteria verdict | verifier | 4 | `.workflow/native-memory-management/verification.md` (stopped at user request; final live smoke not completed) |
| 6 | Merge after approval and capture lessons learned | parent orchestrator | 5 | landed changes + memory entries or explicit skip |

## Notes
- The builder must not mutate `/Users/rogierkonings/.pi/agent/extensions/memory`; it is a reference source only.
- Tasks 3 and 4 must NOT overlap with any other writer on the same files.
- If implementation touches more than three files, keep the planner artifact canonical and update this task list if the plan changes the breakdown.
- The worker kickoff must inline the relevant spec and canonical plan because side-agents may not read parent workflow context automatically.
- Final close-out includes a lessons-learned memory pass for large features/phases.

## Side-agent orchestration checklist
- Before each `planner`, `reviewer`, or `verifier` dispatch, run a singleton check against active registry/status, same-cwd sessions if relevant, and runtime files before respawning after an `agent-check` mismatch.
- Treat `planner`, `reviewer`, and `verifier` as singleton roles per phase unless the workflow explicitly requests alternatives.
- If duplicates appear, choose one canonical agent immediately, record it in `## Canonical agents`, and stop or ignore stale duplicates with rationale.
- Before closing any planner/reviewer/verifier phase, copy or commit the canonical artifact into this workflow directory and verify it exists.

## Canonical agents
| Phase | Canonical agent id | Branch | Worktree | Canonical artifact | Status | Notes |
|---|---|---|---|---|---|---|
| Recon | native-memory-recon | side-agent/native-memory-recon | `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0001` | `.workflow/native-memory-management/context.md` | complete | Artifact copied from side-agent worktree to parent workflow dir |
| Planning | native-memory-plan | side-agent/native-memory-plan | `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0002` | `.workflow/native-memory-management/plan.md` | complete | Artifact copied from side-agent worktree to parent workflow dir |
| Review | native-memory-review | side-agent/native-memory-review | `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0004` | `.workflow/native-memory-management/review.md` | complete - approve to verifier | Project-scoped Dream apply blocker resolved; live duplicate-tool smoke remains verifier scope |
| Verification | dream-verify | side-agent/dream-verify | `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0006` | `.workflow/native-memory-management/verification.md` | stopped/cancelled | User stopped orchestration after excessive loop; registry cleared; live duplicate-tool smoke not completed |

## Acceptance coverage map
- Task 1 maps the external memory tool behavior, active storage schema, stale/hidden support, Dream semantics, and current app UI/loading/icon conventions.
- Task 2 turns the mapping into explicit Swift service/model/view/test changes.
- Task 3 implements native loading for general + current project, newest-first plus alternate sorting, editable metadata, stale/hidden-aware delete, and confirmed Dream mutations.
- Task 4 checks correctness and app-style consistency before merge approval.
- Task 5 provides evidence for build/tests and every acceptance criterion in `spec.md`.

## Closeout
- [ ] Canonical recon/planning/review/verification artifacts are present in `.workflow/native-memory-management/`.
- [ ] `tasks.md` records final statuses and actual artifact paths.
- [ ] Duplicate/stale agents are stopped, ignored with rationale, or explicitly left for follow-up.
- [ ] Durable lessons are stored in memory or explicitly skipped as not reusable.
