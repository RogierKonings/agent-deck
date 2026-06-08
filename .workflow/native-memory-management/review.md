# Native Memory Management — Project-Scope Dream Fix Re-review

## Verdict

**Verdict: approve to verifier.**

The previously identified code blocker is resolved. I do not see remaining code-level blockers in `side-agent/dream-parity` after the project-scoped Dream apply fix. The branch should proceed to verifier for the outstanding live parent/native-subagent launch smoke, especially duplicate canonical memory-tool behavior with the external TS memory extension enabled.

Reviewed target: `side-agent/dream-parity` at `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0003`.

## Previous blocker status

**Resolved: project-scoped Dream apply from reloaded DB records.**

Evidence:

- `createMemory(scope: .project, projectID: explicitProjectID, projectPath: nil)` is now allowed when a canonical project ID is supplied. The project branch now checks `projectPath?.nilIfBlank`, then falls back to `explicitProjectID?.nilIfBlank`, and only throws `missingProject` if both are absent (`side-agent/dream-parity:agent-deck/AgentMemoryStore.swift:117-132`).
- Dream apply still passes `projectID: first?.projectID` for merge/synthesis/pattern records (`side-agent/dream-parity:agent-deck/AgentMemoryStore.swift:371-405`), so reloaded records with `projectPath == nil` and `projectID == "agent-deck"` can now create project-scoped derived memories.
- Regression tests cover the exact reloaded-DB shape where `projectPath` is nil:
  - merge: `side-agent/dream-parity:agent-deckTests/AgentMemoryStoreTests.swift:192-218`
  - synthesize: `AgentMemoryStoreTests.swift:220-244`
  - discover-pattern: `AgentMemoryStoreTests.swift:246-268`

**Resolved: skip-only selection no longer writes empty audit/apply success.**

Evidence:

- `AgentMemoryStore.applyDreamProposals` now returns immediately when all selected proposals are `.skip`, before creating a dream log or event memory (`side-agent/dream-parity:agent-deck/AgentMemoryStore.swift:357-360`).
- `AppViewModel.applyDreamMemoryProposals` filters to actionable proposals and returns without appending an “Applied …” transcript event when no actionable proposals remain (`side-agent/dream-parity:agent-deck/AppViewModel.swift:4980-4986`).
- Regression test verifies no audit file is created for skip-only apply (`side-agent/dream-parity:agent-deckTests/AgentMemoryStoreTests.swift:270-282`).

## Remaining findings

### Blocker

None found in this focused re-review.

### High

1. **Live duplicate-tool launch smoke remains outstanding, but should be verifier scope.**
   - Evidence: worker report still lists live duplicate-tool launch smoke as outstanding (`side-agent/dream-parity:.workflow/native-memory-management/implementation.md:74-79`).
   - Source posture from prior review remains acceptable: Agent Deck registers canonical memory tools and loads its bridges before user extensions, but only live Pi/RPC launch can prove duplicate canonical tool registration with the external TS memory extension does not regress launches.
   - Recommendation: verifier should run bounded parent and native-subagent launch smoke, and if feasible enable the external TS memory extension as a user-selected extension.

2. **Production Dream depends on configured model/RPC behavior not covered by fake-reviewer tests.**
   - Evidence: Dream has a proper `PiMemoryDreamReviewing` seam; production uses `PiMemoryDreamLLMReviewer`, while tests use a fake reviewer (`side-agent/dream-parity:agent-deck/PiMemoryDreamService.swift:3-9`, `PiMemoryDreamService.swift:431-554`, `side-agent/dream-parity:agent-deckTests/AgentMemoryStoreTests.swift:265-298`).
   - Assessment: This is expected for model-backed behavior. It is not a code blocker, but verifier/manual smoke should exercise at least one production Dream proposal path if a model is available.

### Medium / follow-up

- SQLite remains `/usr/bin/sqlite3` + MainActor-bound with timeouts. This is not blocking this change after the deterministic test seams and passing regressions, but remains a future hardening target.

## Dream parity assessment

The branch now satisfies the clarified full native `/dream` phase/action parity requirement within the accepted implementation boundary that native clustering is bounded Swift tag/type/token similarity rather than a literal copy of Pi embedding-cache internals.

Confirmed:

- Full native phase pipeline exists: cluster merge review, schema synthesis, weight rebalance, contradiction scan, temporal event patterns (`side-agent/dream-parity:agent-deck/PiMemoryDreamService.swift:23-82`).
- JSON prompt/parser shapes exist for merge, synthesis, weight, contradiction (`factA`/`factB`), and temporal (`eventIds`) reviewer responses (`PiMemoryDreamService.swift:180-412`).
- Production/test seam exists via `PiMemoryDreamReviewing` and `PiMemoryDreamLLMReviewer` (`PiMemoryDreamService.swift:3-9`, `PiMemoryDreamService.swift:431-554`).
- UI groups proposals by phase and passes exact selected proposal objects without rerunning analysis (`side-agent/dream-parity:agent-deck/AgentMemoryViews.swift:44-49`, `AgentMemoryViews.swift:351-383`).
- Store applies merge/synthesize/reweight/discover-pattern, treats contradiction as report-only, ignores skip/no-op mutations, persists dream JSONL audit, and creates canonical dream-cycle event memory for approved actions (`side-agent/dream-parity:agent-deck/AgentMemoryStore.swift:357-439`, `AgentMemoryStore.swift:448-470`).
- Project-scoped derived memories now work after DB reload via canonical project ID fallback (`AgentMemoryStore.swift:117-132`) and focused tests.

## Validation assessment

Validation evidence inspected:

- `.pi/agent-runs/native-memory-project-scope-fix/build-for-testing.log`
  - status: exit 0
  - contains `** TEST BUILD SUCCEEDED **`
  - no compile errors; only AppIntents metadata warnings.
- `.pi/agent-runs/native-memory-project-scope-fix/ProjectScopeDreamTests-test-without-building-retry.log`
  - status: exit 0
  - contains `** TEST EXECUTE SUCCEEDED **`
  - passed focused tests:
    - `testDreamApplyProjectScopedDiscoverPatternAfterReloadUsesProjectIDWithoutPath`
    - `testDreamApplyProjectScopedMergeAfterReloadUsesProjectIDWithoutPath`
    - `testDreamApplyProjectScopedSynthesizeAfterReloadUsesProjectIDWithoutPath`
    - `testDreamApplySkipOnlyDoesNotWriteEmptyAuditLog`
- Earlier full Dream parity suite evidence remains valid for broader Dream/store coverage: `.pi/agent-runs/native-memory-dream-parity/AgentMemoryStoreTests-16-47-xcresult-summary.json` reported 14 passed, 0 failed, 0 skipped.

The full-class rerun timeout before execution is acceptable under the project’s bounded-validation guidance because the focused regression retry passed and directly covers the prior blocker.

## Exact next step

**Dispatch verifier; do not send back to worker unless verifier finds a live-launch failure.**

Suggested verifier prompt:

```text
Verify side-agent/dream-parity before merge. Build/test evidence is already present in:
- .pi/agent-runs/native-memory-dream-parity/build-for-testing.log
- .pi/agent-runs/native-memory-dream-parity/AgentMemoryStoreTests-16-47-xcresult-summary.json
- .pi/agent-runs/native-memory-project-scope-fix/build-for-testing.log
- .pi/agent-runs/native-memory-project-scope-fix/ProjectScopeDreamTests-test-without-building-retry.log

Focus on remaining live smoke gates only:
1. Parent Pi launch with Agent Deck memory enabled; confirm session starts and canonical memory tools are present.
2. Native subagent launch with memory enabled; confirm session starts and memory tools are available/allowed as expected.
3. If feasible, enable the external TS memory extension as a user-selected extension too; verify duplicate canonical memory tool registration does not crash launch and store_memory routes to Swift/Agent Deck.
4. If a model is configured, do a bounded Dream UI smoke to confirm production reviewer wiring reaches the proposal sheet; do not chase long model/RPC hangs.
```
