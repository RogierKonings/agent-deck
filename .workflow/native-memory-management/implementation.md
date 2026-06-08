# Native Memory Management — Implementation Report

Status: stabilization pass complete, committed on `side-agent/native-memory-impl`, **not yet marked ready for merge** pending reviewer/parent approval.

Current stabilization commit: this commit (`Stabilize native memory tests`; see `git log --oneline -1` for the exact hash).
Previous implementation commits:

- `381d569 Implement native Pi memory management`
- `698724e Update native memory implementation report`

## Latest stabilization pass

### AgentMemoryStoreTests hang isolation

The hang was isolated to the app-host XCTest harness interacting with `AgentMemoryStore` initialization and async test execution:

- Prior sample evidence `/tmp/agentdeck-hang-1.txt` showed the main thread inside:

```text
AgentMemoryStore.init -> refresh -> ensureSchema -> tableColumns -> runWithOutput -> waitUntilExit
```

- The previous bounded test attempt consistently passed five tests, then hung after starting `testRecallExcludesSupersededByDefault`.
- Stabilization changes:
  - Added `autoRefresh: Bool = true` to `AgentMemoryStore.init(...)` and made store tests construct stores with `autoRefresh: false`, creating a deterministic non-autoload seam for tests.
  - Added synchronous `retrieveNow(...)`; `retrieve(...) async` now delegates to it. The recall test no longer uses XCTest's async test runner for a purely synchronous memory lookup.
  - Removed the Dream service `await progress(...)` calls that produced `no async operations occur within await` warnings.
  - Kept sqlite CLI containment: `.timeout 5000`, `PRAGMA busy_timeout=5000`, and a local 5s process watchdog loop.

### Validation after isolation

#### Build for testing

Command:

```sh
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

Outcome: passed.

Evidence log: `/tmp/native-memory-stabilize3-build-for-testing.log`

```text
** TEST BUILD SUCCEEDED **
```

Only non-actionable AppIntents metadata warnings were emitted.

#### AgentMemoryStoreTests

Command:

```sh
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  -only-testing:agent-deckTests/AgentMemoryStoreTests \
  test-without-building
```

Outcome: passed in the single bounded attempt after the isolation fix.

Evidence log: `/tmp/native-memory-stabilize3-agent-memory-tests.log`

```text
Test Suite 'AgentMemoryStoreTests' passed
Executed 10 tests, with 0 failures (0 unexpected) in 6.177 seconds
```

The app host still emits macOS `com.apple.linkd.autoShortcut` connection warnings before tests begin, but those no longer block this targeted suite.

## Duplicate-tool launch smoke

A live parent/native-subagent launch smoke with the external TS memory extension enabled was not run in this narrow pass. Reason: it requires app-host/Pi launch orchestration beyond the now-fixed store unit seam and risks reintroducing a long-running GUI/RPC validation path.

Best static/source-level evidence gathered:

- Native bridge tool names are canonical only:

```text
PiNativeSubagentBridgeExtensions.memoryToolNames = [
  "store_memory", "recall_memories", "reinforce_memory", "update_memory", "delete_memory"
]
```

- The generated native memory bridge registers those five names and no longer registers `agent_deck_memory_*` names.
- Parent launch injects the Swift-owned memory extension when `agentMemoryEnabled` is true:

```text
PiAgentRunnerService -> memoryExtensionURL() -> extraArguments += ["--extension", memoryURL.path]
```

- Native subagent launch does the same when memory is enabled:

```text
PiSubagentRunService -> memoryExtensionURL -> toolArguments(includeMemoryTools: true) -> extraArguments += ["--extension", memoryURL.path]
```

Reviewer should still run one end-to-end duplicate-tool launch before final approval if feasible: enable Agent Deck memory and the external TS memory extension as a user extension, then verify the process does not fail on duplicate canonical tool registration and that `store_memory` routes to Swift.

## Implemented behavior summary

- Canonical SQLite memory DB at `~/.pi/agent/memories/memories.db` by default.
- Default Memory Library scope: `general + current project`.
- Canonical project id derivation from basename (`agent-deck`).
- Canonical types: `fact`, `event`, `procedure`, `insight`.
- Editable canonical fields: title, content, reasoning, type, scope/project, tags, weight, supersedes.
- Canonical effective weight calculation and access reinforcement.
- Canonical delete with supersession chain repair and throwing failure semantics.
- Tri-state supersession updates and validation for self/missing/already-superseded/cycles.
- Fresh DB FTS5 triggers for insert/update/delete synchronization.
- Canonical model-facing bridge tools:
  - `store_memory`
  - `recall_memories`
  - `reinforce_memory`
  - `update_memory`
  - `delete_memory`
- Native deterministic Dream v1 with propose/confirm/apply flow.

## Dream approximation boundary

The current Dream implementation is intentionally native and deterministic. It follows the `/dream` action model enough for safe review-gated application (`merge`, `reweight`, `discover-pattern`, plus no-op/skip handling in the model types), but it is not full embedding/LLM parity with the external Pi `/dream` command. It does not launch or delegate to external `/dream`; approved proposal objects are applied directly without rerunning analysis.

## Remaining risks / reviewer focus

- Do not merge until reviewer/parent approves.
- Live duplicate-tool launch smoke is still outstanding.
- SQLite work is bounded but still uses `/usr/bin/sqlite3`; a future hardening pass should move DB I/O to a non-MainActor actor/service or direct SQLite binding.
- Review bridge routing behavior in a real parent Pi session and native subagent run.
- Review Memory Library UI with an existing real `~/.pi/agent/memories/memories.db`.
- Review deterministic Dream v1 scope against product expectations before final approval.
