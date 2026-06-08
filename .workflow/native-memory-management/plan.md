# Implementation Plan

## Goal
Replace Agent Deck's project-only Markdown memory surface with a native Swift implementation of Pi's canonical persistent-memory behavior, backed by `~/.pi/agent/memories/memories.db`, with library inspection/edit/delete/sort and a confirmation-gated native Dream workflow.

## Tasks
1. **Establish branch and runtime guardrails**: Start from the worker worktree/branch only and confirm no side-agent runtime file changes are needed.
   - File: `.pi/side-agent-runtime.yaml`
   - Changes: Do not create or edit this file; recon found it absent in this repo/worktrees, so no runtime isolation settings are required beyond normal side-agent worktree isolation.
   - Acceptance: `git status --short --branch` shows the worker branch and a clean/expected worktree before edits; no production edits occur outside that branch.

2. **Add canonical Pi memory models and request DTOs**: Replace the old Agent Deck-only memory enums with Pi-compatible scope/type/status/action models while preserving transcript event compatibility.
   - File: `agent-deck/AgentMemoryModels.swift`
   - Changes: Model `PiMemoryScope`/`AgentMemoryScope` as `.general` and `.project(String)` or equivalent displayable scope; model canonical types `fact`, `event`, `procedure`, `insight`; add `PiMemoryRecord` fields matching SQLite (`id`, `title`, `content`, `reasoning`, `tags`, `weight`, `type`, `supersedes`, `supersededBy`, `synthesizedFrom`, `createdAt`, `lastAccessed`, `accessCount`, `sourceSession`, `project`). Add derived status (`current` vs `superseded`; optional app-only hidden flag only if implemented as separate overlay, not DB schema). Replace old bridge DTOs with canonical `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory` request structs and add `DreamAction`, `DreamProposal`, `DreamCycleResult` structs.
   - Acceptance: Models encode/decode epoch-millisecond dates and JSON-array tags; old transcript events still decode for existing session cards.

3. **Create a Swift-owned SQLite store for the canonical DB**: Implement canonical schema/migrations, CRUD, effective weight, search/load, and supersession repair in Swift-owned code.
   - File: `agent-deck/PiMemoryStore.swift` (new; or rename `AgentMemoryStore.swift` only after updating all call sites)
   - Changes: Open `~/.pi/agent/memories/memories.db` by default, with injectable temp DB URL for tests. Use `/usr/bin/sqlite3` or a small SQLite wrapper consistently; wrap every mutation in `BEGIN IMMEDIATE ... COMMIT`, enable WAL, create `memories` and `memory_fts` with triggers if missing, and migrate canonical columns (`type`, `supersedes`, `superseded_by`, `synthesized_from`). Implement `deriveProjectID(path)` as basename lowercased/non-alphanumeric-to-`-`, not the old full-path hash. Implement `loadLibrary(projectPath:)` defaulting to `general` + derived current project, newest-first. Implement `storeMemory`, `recallMemories`, `reinforceMemory`, `updateMemory`, `deleteMemory`, `markSuperseded`, `effectiveWeight`, and `getSupersessionChain` with canonical weight clamp `0.3...1.0` and chain-cycle validation.
   - Acceptance: Existing rows in `~/.pi/agent/memories/memories.db` for `general` and `agent-deck` load without requiring the TypeScript extension; tests can create an isolated temp DB and validate schema/mutations.

4. **Decide deletion/stale semantics explicitly**: Keep canonical DB schema compatible and avoid unsupported hidden/stale columns.
   - File: `agent-deck/PiMemoryStore.swift`
   - Changes: For manual Delete, use canonical permanent delete with supersession-chain repair because the Pi DB has no `stale`/`hidden` columns. Add a separate non-destructive UI action such as “Mark Superseded…” only when the user selects/creates a replacement memory; if hidden is needed, implement it as an app-only overlay file under `~/Library/Application Support/Agent Deck/Memory/hidden-memory-ids.json`, not a DB schema column.
   - Acceptance: Delete does not add columns the TypeScript memory extension would ignore; delete tests prove predecessor/successor supersession links are repaired.

5. **Retire old Markdown store behavior safely**: Stop using app Markdown manifests for active memory behavior, without deleting user files.
   - File: `agent-deck/AgentMemoryStore.swift`
   - Changes: Either replace this type with a compatibility facade over `PiMemoryStore` or remove it from active call sites. Leave `~/Library/Application Support/Agent Deck/Memory` untouched. Do not auto-import old Markdown memories in this change unless a separate import UI is added; document that existing current Pi memories are now the source of truth.
   - Acceptance: Launch, Memory Library, session recall, bridge tools, and tests no longer depend on per-project Markdown manifests or old `index.sqlite` files.

6. **Update AppViewModel memory wiring to canonical behavior**: Route all memory UI/session/subagent operations through the canonical store and tool names.
   - File: `agent-deck/AppViewModel.swift`
   - Changes: Replace `let agentMemoryStore = AgentMemoryStore()` with the new store. Update manual create/edit/delete/status methods for canonical fields (`title`, `content`, `reasoning`, `tags`, `weight`, `type`, `scope`, `supersedes`). Update launch-time parent/subagent prompt generation to match Pi memory index behavior: include current project + general, sort by effective weight plus recency for prompt recall, exclude superseded by default, and render canonical tool guidance. Preserve one recall snapshot per logical parent session and native subagent recall behavior.
   - Acceptance: Starting a session with memory enabled injects only one memory prompt snapshot, uses canonical tool names, and does not call external `/dream` or the TypeScript memory extension.

7. **Replace the generated bridge extension with canonical memory tools**: Keep TypeScript only as the UI bridge transport; Swift owns durable behavior.
   - File: `agent-deck/PiNativeSubagentBridgeExtensions.swift`
   - Changes: Change `memoryToolNames` to `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`. Rewrite `memoryExtensionSource` tool schemas/descriptions/prompt snippets to mirror the canonical Pi extension params and forward `kind` values such as `memory_store`, `memory_recall`, etc. through `AGENT_DECK_BRIDGE`. Remove old `agent_deck_memory_write`, `agent_deck_memory_mark_stale`, `agent_deck_memory_search` registration unless a temporary backwards-compat alias is explicitly desired and allowlisted.
   - Acceptance: `PiNativeBridgeExtensionSourceTests` or equivalent asserts every tool in `memoryToolNames` is registered exactly once and old Agent Deck memory tool names are absent.

8. **Update parent and native subagent bridge request dispatch**: Decode/respond to canonical bridge requests in both Pi launch paths.
   - Files: `agent-deck/PiAgentRunnerService.swift`, `agent-deck/PiSubagentRunService.swift`
   - Changes: Replace `memory_write`, `memory_mark_stale`, `memory_search` cases and callback properties with canonical request kinds. Ensure tool results match the canonical wording enough for agents: store returns ID, recall returns compact index/results, reinforce returns effective weight, update reports changed fields, delete reports chain repair/destructive delete. Keep transcript status cards using existing visual card conventions.
   - Acceptance: Parent sessions and native subagents can call all five canonical tools through Agent Deck, with no duplicate memory tool registration or regressions in non-memory bridge tools.

9. **Update launch allowlists and duplicate-extension mitigation**: Prevent duplicate memory tool registration from user-selected Pi extensions.
   - Files: `agent-deck/PiAgentLaunchArgumentBuilder.swift`, `agent-deck/ExtensionsScreen.swift`, `agent-deck/PiNativeSubagentBridgeExtensions.swift`, `agent-deckTests/PiAgentExtensionLoadingModeTests.swift`
   - Changes: Ensure explicit agent tool allowlists append the canonical memory tool names when memory is enabled. Update `allBridgeToolNames` conflict detection so user-selected `/Users/rogierkonings/.pi/agent/extensions/memory` is flagged as conflicting on `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`. Because Agent Deck bridge extensions load first, either suppress conflicting user memory extension loading when memory is enabled or show a clear warning that those tools will be shadowed.
   - Acceptance: Tests prove canonical memory tools appear in resolved allowlists and conflict detection catches the external Pi memory extension.

10. **Rebuild the Memory Library UI around canonical rows**: Load current memories on launch/refresh and add sort/filter controls.
   - Files: `agent-deck/AgentMemoryViews.swift`, `agent-deck/ContentView.swift`
   - Changes: Add loading state so the screen shows an app-style progress/loading surface instead of flashing “No Memories Yet”. Default library scope is `general + current project`; add optional scope filter for current/general/all visible projects. Default sort newest-first (`createdAt` or `lastAccessed`/`createdAt` fallback); add picker options for effective/raw weight, project/scope, type, title, created date, last accessed. Add “show superseded/history” toggle. Reuse current `AppPage`, `AppCard`, `List`, `AppKeyValueList`, `.appSecondaryButton()`, `AppPrimaryButtonStyle()`, `.appContentSurface(...)`, `ControlGroup`, and `Label(..., systemImage:)` patterns.
   - Acceptance: Fresh app launch/refresh shows existing `general` and `agent-deck` DB rows in newest-first order, sorting changes row order deterministically, and no empty-state flash occurs while loading.

11. **Expose canonical edit/delete controls**: Let users edit all supported fields and delete safely.
   - File: `agent-deck/AgentMemoryViews.swift`
   - Changes: Update `MemoryEditorSheet` to edit title, content, reasoning, type, scope/project, tags, weight, supersedes/superseded metadata where supported. Show superseded/synthesized/source metadata in detail panel. Replace old status menu with current actions: Edit, Reinforce, Mark Superseded/Set Supersedes, Clear Supersedes, Delete. Use SF Symbols in existing tinted rounded-square style (`pin.circle`, `calendar`, `list.bullet.rectangle`, `lightbulb`, `clock.badge.exclamationmark`, `eye.slash`, `trash`) rather than emoji.
   - Acceptance: Editing fields persists to SQLite and refreshes the selected row; delete removes the row/repairs chains; icon styling matches current Agent Deck row/detail surfaces.

12. **Add a native Dream service with proposal/application split**: Port the canonical Dream algorithm without calling `/dream` or the TypeScript extension.
   - File: `agent-deck/PiMemoryDreamService.swift` (new)
   - Changes: Implement `propose(projectPath:, model:, progress:, cancellation:)` and `apply(approvedActions:)`. Proposal load: all non-superseded memories across relevant scopes, optionally all projects for global rebalance if selected by UI. Deterministic clustering fallback: group by type + tag overlap + token similarity/FTS/BM25; do not block on embedding parity in v1. LLM phases should use existing one-shot Pi/Foundation automation patterns (see `SkillDescriptionGenerationService.swift`) with JSON-only prompts derived from canonical modules: cluster merge/keep-separate, weight rebalance candidates, contradiction scan for facts, temporal event pattern discovery. Applying approved actions must mutate exactly the approved proposal objects, not rerun the model.
   - Acceptance: Unit tests can inject a fake reviewer to produce deterministic `merge`, `synthesize`, `reweight`, `flag-contradiction`, `discover-pattern`, and `skip` actions; apply tests prove DB mutations match canonical semantics.

13. **Add Dream UI and progress/cancel/no-op handling**: Add a toolbar Dream button and proposal confirmation sheet.
   - Files: `agent-deck/ContentView.swift`, `agent-deck/AgentMemoryViews.swift`, optionally `agent-deck/PiMemoryDreamViews.swift` (new)
   - Changes: Add a Memory toolbar `Dream` button in the existing `ControlGroup` with SF Symbol styling and disabled/loading states. Show progress using app loading conventions, allow cancel, report no-op when no proposals are generated, and show errors inline/toast consistently with existing screens. Present grouped proposals by phase/action with checkboxes or approve/reject controls and only call `apply` after user confirmation.
   - Acceptance: Cancel leaves DB unchanged; no-op reports clearly; approving a subset applies only that subset; rejecting/closing leaves DB unchanged.

14. **Update settings, docs, and contributor guidance**: Reflect canonical Pi DB behavior and remove old Markdown/project-only language.
   - Files: `agent-deck-documentation/memory.md`, `agent-deck-documentation/agent-deck-system-prompt-logic.md`, `docs/agent-guidelines/PI-RUNTIME.md`, possibly `agent-deck/AppSettings.swift` and `SettingsAndCatalogViews.swift` if labels mention old status/retention behavior.
   - Changes: Document DB location, default library scope, supported tool names, Dream confirmation requirement, deletion semantics, and old Markdown files as legacy untouched data. Keep memory settings that still apply (`enabled`, subagents, transcript cards, injection budget); remove or repurpose retention if it no longer applies to canonical DB.
   - Acceptance: Docs no longer describe project-only Markdown manifests as the active source of truth.

15. **Replace/update tests for canonical memory behavior**: Cover model, store, UI sort seam, bridge source, launch allowlist, and Dream apply logic.
   - Files: `agent-deckTests/AgentMemoryStoreTests.swift` (replace or rename), `agent-deckTests/PiMemoryStoreTests.swift` (new), `agent-deckTests/PiMemoryDreamServiceTests.swift` (new), `agent-deckTests/PiNativeBridgeExtensionSourceTests.swift`, `agent-deckTests/PiAgentExtensionLoadingModeTests.swift`, `agent-deckTests/PiParentAppendPromptResolverTests.swift`
   - Changes: Add temp-DB tests for schema creation/migration, loading `general + project`, project ID derivation (`/Users/.../agent-deck` -> `agent-deck`), newest-first and alternate sort comparators, update editable metadata, delete chain repair, recall include/exclude superseded, reinforce access count/effective weight, bridge canonical tool registration, allowlist/conflict behavior, and Dream proposal application. Remove assertions for Markdown manifests/per-project old `index.sqlite`.
   - Acceptance: Targeted tests pass locally and fail if implementation reverts to old project-only Markdown behavior.

16. **Run validation and capture durable evidence**: Verify build/type safety plus targeted memory behavior.
   - Files: validation artifacts only under a harness/debug-run directory; no production file changes for evidence.
   - Changes: Run standard validation from repo root: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` and `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' test`. For durable reviewer/verifier handoff, wrap important commands with `/Users/rogierkonings/.pi/agent/scripts/pi-debug-run.ts` (or copy/add a repo-local `scripts/pi-debug-run.ts` only if the project adopts that harness) and preserve `metadata.json`, `command.log`, and any DB/screenshot artifacts under the produced run directory.
   - Acceptance: Build and tests are green or failures are documented with `metadata.json` + `command.log`; manual smoke confirms Memory Library shows current Pi DB rows and Dream approval/cancel behavior.

## Files to Modify
- `agent-deck/AgentMemoryModels.swift` - canonical memory records/types/scopes/status/action/request DTOs.
- `agent-deck/AgentMemoryStore.swift` - retire old Markdown store or convert to compatibility facade over the canonical store.
- `agent-deck/AgentMemoryViews.swift` - Memory Library loading/sorting/filtering/detail/editor/delete/Dream proposal UI.
- `agent-deck/ContentView.swift` - Memory toolbar info/new/dream controls and memory count logic.
- `agent-deck/AppViewModel.swift` - store wiring, session recall, bridge handlers, manual CRUD, Dream actions.
- `agent-deck/PiNativeSubagentBridgeExtensions.swift` - canonical memory tool names and generated bridge source.
- `agent-deck/PiAgentRunnerService.swift` - parent-session canonical memory bridge dispatch.
- `agent-deck/PiSubagentRunService.swift` - native-subagent canonical memory bridge dispatch.
- `agent-deck/PiAgentLaunchArgumentBuilder.swift` - canonical memory tool allowlist injection.
- `agent-deck/ExtensionsScreen.swift` - duplicate/conflict warning for external memory extension tool names.
- `agent-deck/AppSettings.swift` and related settings views - only if old retention/status labels no longer apply.
- `agent-deck-documentation/memory.md` - active memory behavior docs.
- `agent-deck-documentation/agent-deck-system-prompt-logic.md` - canonical prompt/tool behavior.
- `docs/agent-guidelines/PI-RUNTIME.md` - update old Markdown/type/status invariants.
- `agent-deckTests/AgentMemoryStoreTests.swift` - replace old Markdown assertions.
- `agent-deckTests/PiNativeBridgeExtensionSourceTests.swift` - canonical tool registration tests.
- `agent-deckTests/PiAgentExtensionLoadingModeTests.swift` - allowlist/conflict tests.
- `agent-deckTests/PiParentAppendPromptResolverTests.swift` - launch recall regression tests.

## New Files
- `agent-deck/PiMemoryStore.swift` - canonical SQLite DB layer, migrations, CRUD, search, effective weight, supersession repair.
- `agent-deck/PiMemoryDreamService.swift` - native Dream proposal and approved-action application logic.
- `agent-deck/PiMemoryDreamViews.swift` - optional split-out Dream progress/proposal confirmation UI.
- `agent-deckTests/PiMemoryStoreTests.swift` - temp-DB canonical store tests.
- `agent-deckTests/PiMemoryDreamServiceTests.swift` - fake-reviewer Dream proposal/apply tests.
- Optional `agent-deck/PiMemorySorting.swift` - pure sort/filter comparators if useful for unit testing UI sort behavior.

## Dependencies
- Tasks 2-4 must happen before UI/session/bridge rewiring because they define the canonical data model and store API.
- Task 5 depends on Task 3 so old Markdown behavior can be retired without losing active memory functionality.
- Tasks 6-9 depend on canonical DTOs/store and should be implemented before broad UI polish so bridge and launch behavior are testable.
- Tasks 10-11 depend on store loading/edit APIs from Tasks 3-4 and AppViewModel wiring from Task 6.
- Tasks 12-13 depend on the store mutation API and available automation model/RPC helper patterns.
- Task 15 should be developed alongside each implementation task, but final replacement tests depend on all behavior being wired.
- Task 16 is last and should not be skipped before reviewer handoff.

## Risks
- The canonical Pi DB has no `stale`, `hidden`, or `deleted` columns; adding them would fork schema behavior from the TypeScript source of truth. Prefer supersession or app-only overlay state.
- Project ID derivation is a compatibility trap: use basename normalization (`agent-deck`), not the existing full-path hash and not a side-agent worktree basename.
- Full embedding parity for Dream clustering/search is high effort; v1 should use deterministic lexical/FTS clustering plus LLM review and clearly document that approximation.
- Dream must apply the already-approved proposal objects; rerunning after confirmation can produce unapproved mutations.
- External user-selected memory extensions can register identical canonical tool names. Agent Deck must load its bridge first and warn/suppress duplicates to avoid confusing shadowed tools.
- SQLite CLI string escaping and concurrent writes can corrupt behavior if not transaction-protected; use robust escaping, JSON encoding for tags, WAL, and `BEGIN IMMEDIATE` around mutations.
- Existing old Markdown memories should not be destructively deleted or silently imported; acceptance focuses on current Pi DB visibility.
- Secret scanning exists in the old store but canonical Pi tools do not emphasize it; preserve scanner on `storeMemory` as app hardening unless this conflicts with canonical acceptance.
- Validation may hang on full Xcode tests; use explicit timeouts and stop after two hung attempts per project guidance.
- Worker guardrails: do not mutate `/Users/rogierkonings/.pi/agent/extensions/memory`; do not merge; keep all code in the worker branch; after implementation/report, wait for reviewer/verifier.

## Verification Recipe
- Unit/targeted tests: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' test`.
- Build: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
- Manual smoke: launch app, select `/Users/rogierkonings/Projects/agent-deck`, open Memory, confirm current `general` + `agent-deck` rows from `~/.pi/agent/memories/memories.db` are visible newest-first; test sort changes, edit metadata, delete a disposable test memory, and Dream cancel/approve paths.
- Durable evidence: run key validation through `/Users/rogierkonings/.pi/agent/scripts/pi-debug-run.ts`; reviewer should inspect the produced `metadata.json`, `command.log`, and any DB/screenshot artifacts for the build, test, and manual-smoke commands.
