# Native Memory Management — Implementation Report

Status: continued stabilization completed, committed on `side-agent/native-memory-impl`, **not ready for merge**.

Implementation commit containing code and this report's baseline: `381d569 Implement native Pi memory management`.

## Fixes made after parent checkpoint

- Added tri-state supersession update semantics:
  - omitted supersedes = no change
  - explicit nil/blank = clear link
  - explicit id = relink
- Added canonical supersession validation before writing links:
  - rejects self-supersession
  - rejects missing targets
  - rejects targets already superseded by another memory
  - rejects cycles
- Added tests for:
  - title-only update preserving supersession links
  - explicit clear and relink
  - invalid self/missing/already-superseded/cycle links
  - delete chain repair and missing-id failure
  - fresh DB FTS trigger synchronization
- Added canonical FTS5 insert/update/delete triggers for Swift-created schemas.
- Changed delete to throw/return the deleted record so UI/bridge paths no longer report success for missing IDs or sqlite failures.
- Added bounded sqlite CLI behavior:
  - `.timeout 5000`
  - `PRAGMA busy_timeout=5000`
  - local 5-second process watchdog loop before terminating sqlite3
- Kept deterministic native Dream v1 and documented its approximation boundary:
  - no external `/dream` process
  - proposes canonical action-model mutations (`merge`, `reweight`, `discover-pattern`) for user confirmation
  - applies approved proposal objects directly without rerunning analysis

## Changed files

- `.workflow/native-memory-management/implementation.md`
- `agent-deck-documentation/memory.md`
- `agent-deck/AgentMemoryModels.swift`
- `agent-deck/AgentMemoryStore.swift`
- `agent-deck/AgentMemoryViews.swift`
- `agent-deck/AppNotifications.swift`
- `agent-deck/AppViewModel.swift`
- `agent-deck/ContentView.swift`
- `agent-deck/PiAgentRunnerService.swift`
- `agent-deck/PiMemoryDreamService.swift`
- `agent-deck/PiNativeSubagentBridgeExtensions.swift`
- `agent-deck/PiSubagentRunService.swift`
- `agent-deckTests/AgentMemoryStoreTests.swift`

## Validation outcomes

### Debug build

Command:

```sh
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Outcome: passed.

Evidence log: `/tmp/native-memory-build-stabilize.log`

```text
** BUILD SUCCEEDED **
```

### Build for testing

Command:

```sh
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

Outcome: passed.

Evidence log: `/tmp/native-memory-build-for-testing-stabilize.log`

```text
** TEST BUILD SUCCEEDED **
```

### Bounded AgentMemoryStoreTests attempt

Command:

```sh
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  -only-testing:agent-deckTests/AgentMemoryStoreTests \
  test-without-building
```

Outcome: timed out after the single bounded 180s attempt; per parent instruction, I did not retry.

Evidence log: `/tmp/native-memory-agent-memory-tests-stabilize.log`

Latest useful evidence before timeout:

```text
Test Suite 'AgentMemoryStoreTests' started
Test Case 'testDeleteRepairsSupersessionChainAndThrowsForMissingID' passed
Test Case 'testDreamApplyCreatesMergedMemory' passed
Test Case 'testExplicitClearAndRelinkSupersedes' passed
Test Case 'testFreshDatabaseFTSTriggersStaySynchronized' passed
Test Case 'testLoadsGeneralAndCurrentProjectNewestFirst' passed
Test Case 'testRecallExcludesSupersededByDefault' started
```

The app-host test process also emitted repeated macOS `com.apple.linkd.autoShortcut` connection errors before tests began. No further retries were run.

## Duplicate-tool launch smoke

Not run. A realistic duplicate-tool launch smoke requires app-host/Pi launch behavior, and the bounded app-host test attempt is still hanging. The bridge now registers canonical native tools (`store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`); reviewer should still verify conflict behavior when the external TS memory extension is enabled as a user extension.

## Remaining risks / reviewer focus

- The branch is build-clean but not test-complete; do not merge yet.
- `AgentMemoryStore` still performs sqlite3 CLI subprocess work from MainActor call sites. It is now bounded with sqlite busy-timeout and process timeout, but a future pass should move DB work behind a non-MainActor actor/service or direct SQLite binding.
- The bounded store test attempt hung after five passing tests; inspect `/tmp/native-memory-agent-memory-tests-stabilize.log` and consider isolating AgentMemoryStore tests from the full app host if possible.
- Review supersession semantics against canonical TypeScript behavior, especially relinking and chain repair.
- Review real DB behavior against `~/.pi/agent/memories/memories.db` with existing memory rows.
- Review duplicate memory tool conflict behavior with the external TS extension enabled.
- Dream v1 is deterministic and native. It follows the safe propose/confirm/apply action model but is not embedding/LLM parity with Pi `/dream`.
