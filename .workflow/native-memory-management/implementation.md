# Native Memory Management — Implementation Checkpoint

Stopped validation per parent/user request; no further xcodebuild test retries were run.

## 1) Implementation changes made

- Replaced Agent Deck memory models with canonical Pi memory concepts:
  - scopes: `general`, `project`
  - types: `fact`, `event`, `procedure`, `insight`
  - canonical metadata: reasoning, tags, weight/effective weight, project id, supersedes/superseded_by, synthesized_from, source session.
- Reworked `AgentMemoryStore` to use the canonical SQLite DB schema at `~/.pi/agent/memories/memories.db` by default, with injectable test DB path support.
  - Creates/migrates canonical columns where missing.
  - Loads current memories for `general + current project`.
  - Uses basename-derived project ids (`agent-deck`).
  - Implements create/update/delete/reinforce/recall-ish retrieval and effective weight calculation.
  - Delete attempts canonical supersession-chain repair.
- Rebuilt the Memory Library UI around canonical fields:
  - default current view with optional history/superseded toggle
  - sort controls for newest, weight/relevance, scope, type, title, updated, created
  - edit sheet for title/content/reasoning/type/scope/tags/weight/supersedes
  - refresh and Dream toolbar actions.
- Added a native deterministic `PiMemoryDreamService`:
  - proposes merge/reweight/discover-pattern actions
  - shows proposals in a confirmation sheet
  - applies only selected proposal objects.
- Replaced model-facing memory bridge tool names with canonical names:
  - `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`
  - Added parent/subagent dispatch plumbing for those bridge payloads.
- Updated memory documentation to describe canonical SQLite-backed behavior.
- Updated `AgentMemoryStoreTests` toward canonical DB/sorting/update/delete/recall/Dream seams.

## 2) Current git status and diff stat

`git status --short`:

```text
 M agent-deck-documentation/memory.md
 M agent-deck/AgentMemoryModels.swift
 M agent-deck/AgentMemoryStore.swift
 M agent-deck/AgentMemoryViews.swift
 M agent-deck/AppNotifications.swift
 M agent-deck/AppViewModel.swift
 M agent-deck/ContentView.swift
 M agent-deck/PiAgentRunnerService.swift
 M agent-deck/PiNativeSubagentBridgeExtensions.swift
 M agent-deck/PiSubagentRunService.swift
 M agent-deckTests/AgentMemoryStoreTests.swift
?? agent-deck/PiMemoryDreamService.swift
```

`git diff --stat`:

```text
agent-deck-documentation/memory.md                | 298 +------
 agent-deck/AgentMemoryModels.swift                | 167 +++-
 agent-deck/AgentMemoryStore.swift                 | 895 ++++++++++++----------
 agent-deck/AgentMemoryViews.swift                 | 733 ++++++------------
 agent-deck/AppNotifications.swift                 |   2 +
 agent-deck/AppViewModel.swift                     | 177 ++++-
 agent-deck/ContentView.swift                      |  19 +-
 agent-deck/PiAgentRunnerService.swift             |  53 +-
 agent-deck/PiNativeSubagentBridgeExtensions.swift | 116 +--
 agent-deck/PiSubagentRunService.swift             |  65 +-
 agent-deckTests/AgentMemoryStoreTests.swift       | 206 ++---
 11 files changed, 1201 insertions(+), 1530 deletions(-)
```

Note: `git diff --stat` does not include the untracked new file `agent-deck/PiMemoryDreamService.swift`.

## 3) Validation status and latest evidence

Validation attempted:

1. `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' -only-testing:agent-deckTests/AgentMemoryStoreTests test`
   - Failed early due missing local Mac Development signing certificate.
2. Retried with `CODE_SIGNING_ALLOWED=NO`.
   - Exposed compile errors; fixed those.
3. Retried targeted `AgentMemoryStoreTests` several times while fixing store/test issues.
   - Earlier runs reached tests and exposed store initialization/loading failures.
   - Later runs became slow/hung around launching/running the app test host, with repeated system `com.apple.linkd.autoShortcut` connection errors and no final `TEST SUCCEEDED`/`TEST FAILED` before timeout.
4. Final slow command stopped per parent/user instruction:

```text
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:agent-deckTests/AgentMemoryStoreTests test
```

Latest evidence from `/tmp/agent-memory-test9.log` before stop:

```text
[Connection] Unable to get synchronousRemoteObjectProxy, error: ... connection to service named com.apple.linkd.autoShortcut
[Connection] Unable to re-register with Process Instance Registry, error: ... connection to service named com.apple.linkd.autoShortcut
```

Build validation did complete successfully:

```text
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **
```

## 4) Readiness assessment

Not ready for merge as-is. It is build-clean, but the targeted test loop did not complete after the latest fixes, and the change is broad enough that it needs reviewer attention before any merge decision.

Reviewer focus areas:

- Verify canonical SQLite read/write behavior against an existing real `~/.pi/agent/memories/memories.db`.
- Check the new sqlite CLI wrapper robustness and async `refresh()` behavior.
- Review supersession repair semantics carefully.
- Review native bridge compatibility with Pi RPC extension UI payload routing.
- Decide whether deterministic Dream v1 is sufficient or should be wired to an LLM reviewer seam before merge.
- UI review for Memory Library density/style after the large rewrite.
