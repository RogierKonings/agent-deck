# Native Memory Management Implementation

Status: continuation complete on `side-agent/dream-parity`; ready for parent/reviewer inspection, not self-merged.

## Commits

- Implementation commit: `6ea3850 Complete native dream parity`.
- Report update commit: `e7268d2 Update native memory report`.
- Project-scope Dream apply fix: pending this follow-up commit.

## Behavior implemented

- Canonical SQLite memory DB defaults to `~/.pi/agent/memories/memories.db`.
- Memory Library loads `general + current project` for the table, with search/filter/sort and optional superseded history.
- Manual memory create/edit/delete/reinforce use canonical fields and supersession behavior.
- Canonical bridge tools route to Swift:
  - `store_memory`
  - `recall_memories`
  - `reinforce_memory`
  - `update_memory`
  - `delete_memory`
- Native Swift Dream button now uses the full `/dream` phase/action pipeline shape without external TypeScript `/dream` delegation:
  - loads non-superseded memories from the Swift store for analysis,
  - clusters related memories for merge review,
  - runs schema synthesis for related-but-distinct clusters,
  - runs global weight rebalance,
  - scans factual contradictions,
  - discovers temporal event patterns,
  - includes skip/no-op and report-only contradiction proposals,
  - presents proposed action objects for user confirmation,
  - applies exactly the selected approved proposal objects without rerunning analysis,
  - persists an app-owned dream-cycle JSONL audit log and a canonical dream-cycle event memory when approved actions are applied.
- Follow-up project-scope apply fix:
  - project-scoped Dream-derived memories can now be created from reloaded DB records whose `projectPath` is nil as long as the canonical `projectID` is present;
  - skip-only selections now return without writing an empty-approved dream audit log or appending an “Applied 1” UI event.

## Dream implementation notes

- The Swift implementation has a `PiMemoryDreamReviewing` seam so tests can inject deterministic fake reviewer output while production uses `PiMemoryDreamLLMReviewer` through Agent Deck's model infrastructure.
- Prompt builders and parsers mirror the canonical `/dream` phases and JSON shapes, including canonical contradiction (`factA`/`factB`) and temporal (`eventIds`) response forms while keeping compatibility with the WIP parser shape.
- The clustering pass is native Swift and bounded; it uses tags/type/token similarity rather than copying Pi's embedding-cache internals. The full phase/action LLM pipeline and application semantics are present natively.
- Approved application semantics match the canonical behavior where the Swift store supports it:
  - merge creates a synthesized memory, supersedes the first source, and marks remaining sources superseded by the merged memory;
  - synthesize creates a higher-level memory with `synthesizedFrom` and reduces source weights unless an explicit approved reweight for that source is present;
  - reweight updates exact listed weights;
  - discover-pattern creates an insight from event IDs;
  - flag-contradiction is visible/report-only and does not mutate contradiction memories;
  - skip/no-op proposals are visible but not applied as mutations.

## Validation evidence

Artifacts are under `.pi/agent-runs/native-memory-dream-parity/`.

- `build-for-testing.log` / `build-for-testing.status`
  - Command: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing`
  - Result: exit 0.
- `AgentMemoryStoreTests-16-47-xcresult-summary.json` / `AgentMemoryStoreTests-16-47-xcresult-summary.status`
  - Command: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:agent-deckTests/AgentMemoryStoreTests test-without-building`
  - Result: exit 0; Xcode xcresult summary reports 14 passed, 0 failed, 0 skipped. This includes Dream fake-reviewer phase coverage, approved subset application, canonical action application/audit log, cancel no-op, and existing store tests.
- Project-scope follow-up validation artifacts are under `.pi/agent-runs/native-memory-project-scope-fix/`:
  - `build-for-testing.log` / `build-for-testing.status`
    - Command: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing`
    - Result: exit 0.
  - `ProjectScopeDreamTests-test-without-building-retry.log` / `ProjectScopeDreamTests-test-without-building-retry.status`
    - Command: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -only-testing:agent-deckTests/AgentMemoryStoreTests/testDreamApplyProjectScopedMergeAfterReloadUsesProjectIDWithoutPath -only-testing:agent-deckTests/AgentMemoryStoreTests/testDreamApplyProjectScopedSynthesizeAfterReloadUsesProjectIDWithoutPath -only-testing:agent-deckTests/AgentMemoryStoreTests/testDreamApplyProjectScopedDiscoverPatternAfterReloadUsesProjectIDWithoutPath -only-testing:agent-deckTests/AgentMemoryStoreTests/testDreamApplySkipOnlyDoesNotWriteEmptyAuditLog test-without-building`
    - Result: exit 0; 4 focused regression tests passed.

Notes on bounded validation:
- A first targeted `test` attempt without `CODE_SIGNING_ALLOWED=NO` failed due missing local Mac Development signing certificate.
- A retry with `test` and signing disabled timed out in the build phase; because `build-for-testing` had already succeeded, `test-without-building` was used for targeted execution and passed at 16:47.
- After final doc/test warning-cleanup edits, `build-for-testing` was rerun and passed. A final `test-without-building` rerun timed out at 180s before test execution started; per bounded-validation guidance, this was not chased further. No app source changed after the passing targeted test; the subsequent code edit was test-only `String(contentsOf:encoding:)` warning cleanup plus documentation.
- During the project-scope follow-up, a full-class `AgentMemoryStoreTests` `test-without-building` run again timed out before test execution started. One bounded retry narrowed to the new regression tests plus skip-only audit polish with an explicit arm64 destination; that retry passed.

## Remaining risks / reviewer focus

- Production Dream depends on a configured Agent Deck/Pi model; tests use the fake reviewer seam and do not require network/model calls.
- Native clustering intentionally does not copy Pi's embedding cache internals; reviewer should confirm this is acceptable under the clarified parity criterion now that the full native phase/action pipeline and LLM seams exist.
- Live duplicate-tool launch smoke is still outstanding: enable Agent Deck memory and the external TS memory extension as a user extension, then verify duplicate canonical tool registration does not break launch and `store_memory` routes to Swift.
- SQLite work remains `/usr/bin/sqlite3` based and MainActor-bound; a future hardening pass could move DB I/O to a dedicated actor or direct SQLite binding.
