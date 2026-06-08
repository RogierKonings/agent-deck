# native-memory-management recon context

## Scope / runtime evidence

- Worktree: `/Users/rogierkonings/Projects/agent-deck/.worktrees/agent-0001`, branch `side-agent/native-memory-recon`, HEAD `848d061`, clean when recon started.
- Parent repo to inspect: `/Users/rogierkonings/Projects/agent-deck`; reference extension: `/Users/rogierkonings/.pi/agent/extensions/memory`.
- `.pi/agent-runs/`, `.pi/harness-runs/`, and `.pi/side-agent-runtime.yaml` were not present in either this side worktree or the parent repo, so no durable run/harness artifacts affected this recon.
- Current Pi memory database exists at `~/.pi/agent/memories/memories.db`. Observed schema columns: `id,title,content,reasoning,tags,weight,created_at,last_accessed,access_count,source_session,project,type,supersedes,superseded_by,synthesized_from`. Observed project buckets include `general`, `agent-deck`, and this side-agent worktree bucket `agent-0001`; the most relevant app project ID should be derived from the selected project path basename (`agent-deck`), not the side-agent worktree basename.

## 1. External Pi memory extension map

Reference implementation is the canonical behavior to port to Swift, not to call via a TS extension or `/dream` helper.

### Storage and schema

- `/Users/rogierkonings/.pi/agent/extensions/memory/lib/store.sqlite.ts:1-24` documents the canonical store: single SQLite + FTS5 DB at `~/.pi/agent/memories/memories.db`, typed memories (`fact`, `event`, `procedure`, `insight`), supersession chains, type-specific decay, WAL mode.
- `store.sqlite.ts:42-58` `Memory` fields:
  - `id`, `title`, `content`, `reasoning`, `tags` JSON array, `weight`, `type`, `supersedes`, `supersededBy`, `synthesizedFrom`, `createdAt`, `lastAccessed`, `accessCount`, `sourceSession`, `project`.
- `store.sqlite.ts:98-122` creates `memories` table with base columns and indexes; `store.sqlite.ts:139-161` migrates `type`, `supersedes`, `superseded_by`, `synthesized_from`; `store.sqlite.ts:124-137` creates FTS5 table/triggers over title/content/reasoning/tags.
- `store.sqlite.ts:256-261` `loadMemories(project)` returns rows for one project sorted by raw `weight DESC`.
- `store.sqlite.ts:295-345` `addMemory` creates ids like `mem_<8 uuid chars>`, timestamps with `Date.now()` milliseconds, source session, project; if `supersedes` is set it marks the old memory’s `superseded_by`.
- `store.sqlite.ts:359-443` `updateMemory` edits title/content/reasoning/tags/weight/type/supersedes, clamps weight to `0.3...1.0`, updates `last_accessed`, validates supersession target/self/cycles, and repairs old/new `superseded_by` links.
- `store.sqlite.ts:449-471` effective weight formula: `min(1, weight * exp(-lambda_type * ageDays) + min(0.3, accessCount*0.05))`, then `*0.3` when superseded. Decay lambdas at `store.sqlite.ts:73-78`: fact `0.008`, event `0.010`, procedure `0.003`, insight `0.005`.
- `store.sqlite.ts:670-711` `deleteMemory(project,id)` is permanent delete and repairs supersession chain: clears predecessor `superseded_by`, points successor’s `supersedes` at deleted memory’s predecessor, then deletes the row.
- `store.sqlite.ts` has no explicit `stale`, `hidden`, or `deleted` columns. The closest supported “outdated but retained” semantic is `superseded_by != NULL`; otherwise deletion is physical. Acceptance criterion “prefer stale/hidden where supported” should be implemented as supersession/hidden UI where possible, or as app-side overlay only if planner approves extending state. Mutating the canonical DB with new hidden columns would be a schema extension the TS tool ignores unless coordinated.

### Exposed tools

Registered in `index.ts:62-66`, then at end of extension factory (after the event handlers) the tool/command registration functions are called.

- `store_memory` (`tools/store.ts:29-206`): params `title`, `content`, `reasoning`, `tags`, `weight`, `scope` (`project|general`), optional `type`, optional `supersedes`. Uses `deriveProjectId(ctx.cwd)` for project-scope writes, general otherwise. For `fact` without `supersedes`, searches current/general facts and emits contradiction warnings when semantic similarity >= `0.65` (`tools/store.ts:15-25`, `tools/store.ts:82-121`). Stores row, embeds it non-fatally, tracks session activity.
- `recall_memories` (`tools/recall.ts:18-206`): params optional `query`, `id`, `project`, `type`, `includeSuperseded`. ID lookup searches all projects and includes version history via `getSupersessionChain`. Query defaults to `[currentProject, general]`, searches top 5 with `includeSuperseded` default false.
- `reinforce_memory` (`tools/reinforce.ts:19-142`): params `id`, finds across projects, increments `last_accessed` and `access_count`, returns effective weight, tracks activity.
- `update_memory` (`tools/update.ts:24-179`): params `id` plus optional editable fields: `title`, `content`, `reasoning`, `tags`, `weight`, `type`, `supersedes` string or null. Re-embeds when textual fields changed. This is the canonical edit surface for metadata.
- `delete_memory` (`tools/delete.ts:21-110`): params `id`, permanent delete with embedding/association cleanup, docs explicitly say prefer `update_memory` for corrections or `supersedes` for evolution.

### Prompt/index behavior

- `index.ts:75-193` `before_agent_start` builds a persistent memory section for the system prompt. It injects a compact index, instructions for the five tools, current project, task-relevant extras, procedure-evolution nudge, dream nudge, and “more available via search” count.
- `index-builder.ts:1-20` sorts the prompt index by effective weight plus a recency boost, excludes superseded memories by default.
- `index-builder.ts:50-92` max 50 entries; `index-builder.ts:125-173` formats `[current project]`, `[general]`, and limited `[other projects]` sections, using emoji type icons (`fact` 📌, `event` 📅, `procedure` 📋, `insight` 💡). Note typo in note says `includeSupersceded` in the text, but tool param is `includeSuperseded`.
- `helpers.ts:11-18` project ID derivation is just basename lowercased, non-alphanumeric to `-`, collapsed/trimming. For selected `/Users/.../Projects/agent-deck`, canonical project is `agent-deck`.
- `memories-command.ts:11-47` `/memories` lists all memories sorted by effective weight, showing current/superseded counts.

### Dream command and algorithm

- `/dream` command: `dream-command.ts:25-296`. Supports `--dry-run`, `--history`, `--last`, and `--interactive`. It resolves a “dream” task model via shared model-auth helpers, sends progress notifications, uses a 120s abort + 130s hard timeout per LLM call with heartbeats, and in interactive mode first runs a dry-run preview, shows details, asks `ctx.ui.confirm`, then reruns to apply. Acceptance wants Swift-native Dream with proposal confirmation; do not shell/call this TS command.
- Dream pipeline is documented in `dream-cycle.ts:1-17`: load all non-superseded memories, load embedding cache, cluster memories, per-cluster merge then synthesis, global weight rebalance, contradiction scan, temporal patterns, apply unless dry-run, persist cycle log and a dream-event memory.
- `dream-cycle.ts:267-436` `runDreamCycle`: filters `getAllMemories()` to `!supersededBy`, clusters using embedding cache, runs phases `cluster-review`, `weight-rebalance`, `contradiction-scan`, `temporal-patterns`, accumulates actions and token counts, applies actions only when `dryRun == false`, then persists dream log and creates an event memory in general.
- `dream-cycle.ts:62-155` action application:
  - `merge`: add a synthesized memory in first source’s project, `supersedes` first source, `markSuperseded` all remaining source ids, embed non-fatally.
  - `synthesize`: add a higher-level memory with `synthesizedFrom`, create associations, reduce source weights to `weight*0.85` unless already reweighted.
  - `reweight`: update listed weights.
  - `discover-pattern`: add an insight memory from event IDs.
  - `flag-contradiction` and `skip`: no DB mutation.
- `dream-types.ts:8-44` `DreamAction` types: `merge`, `synthesize`, `reweight`, `flag-contradiction`, `discover-pattern`, `skip`; metadata phase names match UI proposal grouping.
- LLM review modules:
  - `s04-cluster-review.ts:14-68` merge prompt: merge near-duplicates/same evolving fact/procedure, keep siblings distinct; JSON-only schema with decision `merge|keep-separate`.
  - `s05-weight-rebalance.ts:64-72` candidates: high-use low-weight (`accessCount >= 5 && weight < 0.7`) or stale high-weight (`accessCount == 0 && weight >= 0.7 && age > 30d`), max 15, only deltas >= 0.1.
  - `s06-schema-synthesis.ts:1-36` synthesis extracts higher-level principle/checklist/pattern from related-but-distinct memories; source memories get `0.85x` weight reduction.
  - `s07-contradictions-patterns.ts:69-141` contradiction scan reviews `fact` memories in batches of 30 and only emits flag actions; `s07:153-252` temporal pattern discovery uses `event` memories in last 90 days, requires at least 3, creates insight actions.
- Dream trigger: `dream-cycle.ts:440-462` suggests Dream when current memory count >= 20 and no/stale dream cycle, or count >= 40 regardless of recency.

## 2. Current Agent Deck memory code map

Agent Deck already has an app-owned, project-only Markdown memory implementation. It does **not** read the Pi canonical SQLite DB, has no general scope, has different types/statuses, and registers differently named bridge tools.

### Models/store

- `agent-deck/AgentMemoryModels.swift:3-9`: scope only `.project`; no `.general`.
- `AgentMemoryModels.swift:11-39`: types are `context`, `decision`, `runbook`, `failure`, `preference` (not Pi’s `fact`, `event`, `procedure`, `insight`).
- `AgentMemoryModels.swift:41-61`: statuses `active`, `pinned`, `stale`, `archived`; `active/pinned` injectable. This is richer hidden/stale UI than the external DB supports.
- `AgentMemoryModels.swift:63-83`: record fields include file path, projectPath, source session/run/agent, writeReason, dates, useCount, tags; no weight, reasoning, supersedes/supersededBy/synthesizedFrom, sourceSession string, or general/project scope string.
- `AgentMemoryStore.swift:22-55`: default root is `~/Library/Application Support/Agent Deck/Memory`; async-loads manifests into `records`, not Pi DB.
- `AgentMemoryStore.swift:67-71`: `records(projectPath:)` returns `[]` when no selected project and filters only exact `projectPath`. This is why current Memory Library cannot show `general + current project` Pi memories.
- `AgentMemoryStore.swift:73-120`: creates Markdown memory, secret scans, writes manifest, inserts sorted. Requires projectPath.
- `AgentMemoryStore.swift:122-139`: edit only title/summary/body/tags. The editor’s `kind` is ignored on edit in the view.
- `AgentMemoryStore.swift:141-159`: status update and physical file delete.
- `AgentMemoryStore.swift:166-194`: retrieval searches only active/pinned current project records; first FTS via `AgentMemorySQLiteSearchIndex`, then keyword fallback.
- `AgentMemoryStore.swift:196-215`: prompt format is fenced `<memory-context source="Agent Deck" scope="project">` and renders `[Kind] title (id, updated date)` plus body.
- `AgentMemoryStore.swift:356-363`: default store sort is status rank (`pinned`, `active`, `stale`, `archived`) then `updatedAt DESC`; acceptance wants Memory Library default newest-first and alternate sorts.
- `AgentMemoryStore.swift:461-577`: local per-project search cache uses `/usr/bin/sqlite3` and a derived `index.sqlite` under app support. It can be kept for old app memory or replaced/repurposed for canonical Pi DB querying.

### Views/current UI behavior

- `AgentMemoryViews.swift:3-48` `MemoryScreen` uses `AppPage("Memory")`, central toolbar comments, notification-driven “New Memory” sheet, cached layout via `.task(id: cacheKey)`.
- `AgentMemoryViews.swift:73-91`: filtering by status, type, search across title/summary/kind/status/scope/filePath/tags. No sort controls.
- `AgentMemoryViews.swift:106-130`: `AppCard(title: "Memory Library")`; empty states use `ContentUnavailableView("No Memories Yet", systemImage: "brain")` and matching “No Matching Memories”.
- `AgentMemoryViews.swift:133-166`: filter bar uses `Picker` for status/type and a `.appSecondaryButton()` Clear button.
- `AgentMemoryViews.swift:169-230`: list rows, swipe delete, context menu for active/pinned/stale/archive/delete. It is a `List`, not a `Table`; acceptance says “table” but current app convention may favor the existing native List pattern unless planner chooses Table.
- `AgentMemoryViews.swift:290-337`: row icon style: `Image(systemName: record.kind.systemImage)` with semibold font, foreground `record.status.tint`, 30x30 rounded tinted background; row uses `.appContentSurface(cornerRadius: 12, isSelected:)`.
- `AgentMemoryViews.swift:339-460`: detail panel header mirrors icon styling; `Menu` actions with `.appSecondaryButton()`, edit button, `MemoryInfoPanel` `AppKeyValueList`, Markdown body.
- `AgentMemoryViews.swift:463-556`: editor sheet uses grid rows, `AppTextField`, `Picker`, `TextEditor`, `.appSecondaryButton()` Cancel and `AppPrimaryButtonStyle()` Save. Currently cannot edit kind on save due `_ = kind` in detail editor.
- `AgentMemoryViews.swift:558-622`: memory transcript card uses `AppRowCard`, SF Symbols from `AgentMemoryEventKind`, `AppTheme.brandAccent`, clickable recalled memory titles.
- `AgentMemoryViews.swift:624-661`: icon mappings for old kinds/statuses/scopes. New Pi memory type icons should be SF-symbol equivalents following this style (avoid emoji in native UI); external emoji are only for prompt text.

### Bridge extension / duplicate-tool boundaries

- `PiNativeSubagentBridgeExtensions.swift:6`: current memory tools are `agent_deck_memory_write`, `agent_deck_memory_mark_stale`, `agent_deck_memory_search`.
- `PiNativeSubagentBridgeExtensions.swift:47-80`: bridge descriptor presents these as “Memory” when memory enabled.
- `PiNativeSubagentBridgeExtensions.swift:99-120`: injected parent bridges list includes memory only when enabled.
- `PiNativeSubagentBridgeExtensions.swift:141-143`, `628-733`: writes a TS shim `agent-deck-memory-bridge.ts`; it registers the three Agent Deck tools and forwards calls to the Swift app via `ctx.ui.editor("AGENT_DECK_BRIDGE ...")`.
- `PiAgentRunnerService.swift:639-642`: parent sessions append Agent Deck memory bridge extension when setting `agentMemoryEnabled` is true.
- `PiSubagentRunService.swift:78-105`: native subagents also append the memory bridge when memory is enabled and include memory tool names in allowlist filtering.
- `PiAgentLaunchArgumentBuilder.swift:43-51`, `109-112`: if an agent declares a `tools` allowlist, Agent Deck appends memory tool names when memory is included.
- User-selected Pi extensions are loaded **last** (`PiAgentRunnerService.swift:734-738`, `PiSubagentRunService.swift:111-114`) so Agent Deck bridges register first and win conflicts. For acceptance criterion 7, if the new native memory surface uses canonical names (`store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`), update `memoryToolNames` and conflict descriptor; avoid simultaneously loading the external TS memory extension in normal sessions or native subagents because duplicate names will conflict and first-registration wins.
- Current extension loading starts with `--no-extensions` via `PiAgentLaunchArgumentBuilder.noExtensionsArgument`, then Agent Deck adds explicit bridge extensions. If the user enables `/Users/rogierkonings/.pi/agent/extensions/memory` as a user-selected extension, it would load last and likely lose duplicate tools if names match, but slash commands `/dream`/`/memories` might still register. Planner should decide whether to warn/suppress external memory extension when native memory is enabled.

### AppViewModel memory lifecycle

- Setup closures at `AppViewModel.swift:388-416` connect Pi runner/subagent runner to memory append prompts and bridge callbacks.
- Manual mutations: `AppViewModel.swift:4888-4935` create/update/status/delete; delete currently no transcript event.
- Parent recall: `AppViewModel.swift:5135-5171` once per logical conversation, snapshots recalled prompt/IDs; replays on process resume.
- Child recall: `AppViewModel.swift:5173-5187` task-scoped for native subagents when memory/subagent memory enabled.
- Guidance: `AppViewModel.swift:5189-5200` tells agents to use old `agent_deck_memory_*` names.
- Automatic writes/stale/search: `AppViewModel.swift:5200-5341`; stale searches current project active memories then `setStatus(.stale)`, on-demand search dedupes parent snapshot IDs.

### Existing docs/settings/tests

- `agent-deck-documentation/memory.md:1-35` describes Agent Deck-owned Markdown/project-only memory and old tools.
- `agent-deck-documentation/memory.md:36-96` documents app support storage, old types/statuses, no global memory.
- `agent-deck-documentation/memory.md:100-121` documents old three bridge tools.
- `agent-deck-documentation/memory.md:130-177` documents current recall snapshot semantics, which are valuable and probably should be preserved while swapping storage/tool names.
- Settings fields: `AppSettings.swift:167-171` include `agentMemoryEnabled`, `agentMemorySubagentsEnabled`, transcript cards, injection budget, retention days.
- Tests: `agent-deckTests/AgentMemoryStoreTests.swift` covers old Markdown persistence, retrieval, stale exclusion, project-only rejection, source metadata, secret scan, transcript event. `PiNativeBridgeExtensionSourceTests.swift` currently lacks memory bridge assertions; add/update for canonical tool names/schemas. `PiAgentBridgeSmokeTests.swift` has launch/bridge harness patterns.

## 3. Candidate files likely to change

High probability:

- `agent-deck/AgentMemoryModels.swift`: replace/extend old models with canonical Pi fields: memory type `fact/event/procedure/insight`, scope `general/project`, weight, reasoning, supersedes/supersededBy/synthesizedFrom, sourceSession, created/lastAccessed/accessCount, plus app-only hidden/stale state if approved. Bridge request structs must change from Agent Deck names to canonical tool params.
- `agent-deck/AgentMemoryStore.swift`: major rewrite or new sibling store for canonical SQLite DB. Needs direct load of `~/.pi/agent/memories/memories.db`, general + current project filtering, effective-weight calculation, FTS/search, add/update/reinforce/delete/supersession repair, optional migration from old Agent Deck Markdown if desired (not in acceptance but consider data preservation), and Dream proposal application.
- `agent-deck/AgentMemoryViews.swift`: Memory Library should load canonical current memories, default sort newest-first, add alternate sort controls, expose metadata edit fields (type/scope/tags/weight/supersession/status if available), manual delete/hide, Dream button/proposal sheet/progress/error/no-op states, keep existing `AppCard`, row icon, sheet, `ContentUnavailableView` style.
- `agent-deck/AppViewModel.swift`: update guidance, recall, bridge callbacks, manual CRUD, Dream orchestration entry points; choose model for Dream (use existing automation/default model patterns), handle progress/errors/cancel, append transcript cards where useful.
- `agent-deck/PiNativeSubagentBridgeExtensions.swift`: change memory bridge tool names/schemas/descriptions to canonical `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`; ensure bridge forwards to Swift and does not register duplicate old Agent Deck tools. Update `memoryToolNames`, descriptors, generated TS source, and user-extension conflict warnings.
- `agent-deck/PiAgentLaunchArgumentBuilder.swift`: memory tool allowlist injection must use canonical names; potentially account for agent-authored tools lists that include old names.
- `agent-deck/PiAgentRunnerService.swift` and `agent-deck/PiSubagentRunService.swift`: likely only indirect changes unless bridge URL/tool inclusion or external-memory suppression/warnings are added.
- `agent-deck/ContentView.swift`: central Memory toolbar currently has info/new buttons around `ContentView.swift:1410-1440`; add Dream button there to match app toolbar conventions, not inside the view if it should be a primary toolbar action.
- `agent-deck/AppSettings.swift`, `AppSettingsController.swift`, settings views: may need model selection for Dream or memory backend/settings, and to document that native memory uses Pi DB.
- `agent-deck-documentation/memory.md` and `agent-deck-documentation/contributors/source-map.md`: update user-visible behavior and architecture.
- Tests under `agent-deckTests/`: update `AgentMemoryStoreTests`, `PiNativeBridgeExtensionSourceTests`, launch/bridge tests; add Dream proposal/application tests.

Potential new files (cleaner than a monolithic store):

- `PiPersistentMemoryStore.swift` or `PiMemoryStore.swift` (SQLite DB layer and models), `PiMemoryDreamService.swift` (Dream planning/applying), `PiMemorySearch.swift` (FTS/effective weight), `PiMemoryBridgeRequests.swift` (canonical tool payloads), and `PiMemoryDreamViews.swift` (proposal sheet) if separation is preferred.

## 4. UI/loading/icon conventions relevant to this task

- Use `AppPage`, `AppCard`, `AppRowCard`, `AppKeyValueList`, `AppTextField`, `.appSecondaryButton()`, `AppPrimaryButtonStyle()`, `.appContentSurface(...)` rather than raw custom styling.
- Loading: app launch uses `AppInitialLoadWindowCover` (`ContentView.swift`), but in-page async work should follow existing cards/empty states. `MemoryScreen` currently async-loads via store init and shows empty state; new store should expose a loading state so existing memory rows do not momentarily show “No Memories Yet” while canonical DB is being read. Match existing `ContentUnavailableView` style and/or progress rows used elsewhere.
- Toolbar: per `docs/agent-guidelines/SWIFTUI.md:7-31`, use `ToolbarItem(placement: .primaryAction)`; 2+ related buttons in `ControlGroup`; single standalone button as plain Button; always use `Label("Name", systemImage:)`; apply `toolbarNeutralChrome()` or `toolbarPrimaryActionChrome()`. Memory toolbar already centralized in `ContentView.swift:1410-1440`; add Dream there if toolbar-level.
- Icons: native UI should use SF Symbols with monochrome/tint style like current rows (`AgentMemoryViews.swift:290-337`) and status tints (`AgentMemoryViews.swift:645-661`). Suggested canonical mappings: fact `pin.circle`/`doc.badge.gearshape`, event `calendar`, procedure `list.bullet.rectangle`, insight `lightbulb`; superseded/stale/hidden use `clock.badge.exclamationmark` or `eye.slash`, destructive delete `trash`. Do not use external extension emoji as primary native icons.
- Destructive actions must be separated and clearly labeled (guideline). Current context menu has `Divider()` before delete; keep that.

## 5. Risks / gotchas

- **Stale/hidden mismatch:** external canonical schema has no `stale`/`hidden` status. Supersession (`superseded_by`) is the only built-in stale-like semantic, and physical delete is canonical. If acceptance requires manual hide without deletion, planner must choose app-side overlay or schema extension; schema extension may be ignored by the external TS extension.
- **Project ID mismatch:** canonical project ID is basename-derived (`agent-deck`), not hashed full path (current Agent Deck store) and not side-agent worktree basename (`agent-0001`) unless the Pi process cwd is the side worktree. The Memory Library should default to `general + selected project basename` for `/Projects/agent-deck`.
- **Duplicate tool names:** canonical names may conflict with the installed external memory extension if user-selected. Agent Deck’s bridges load first and win, but duplicate command/tool registration can confuse users. Avoid loading old `agent_deck_memory_*` plus new canonical tools simultaneously; warn/suppress external memory extension when native memory is enabled if possible.
- **SQLite dependency:** Swift stdlib has no built-in SQLite wrapper. Current code shells `/usr/bin/sqlite3` for derived indexes; direct canonical DB CRUD via subprocess is possible but fragile for atomic transactions/JSON escaping. The Xcode project may need a Swift SQLite package or a thin C SQLite wrapper. Validate package constraints before implementation.
- **Embeddings:** external search/dream clustering uses embedding cache and hybrid semantic+FTS ranking. A first Swift port can faithfully implement DB schema, FTS, effective-weight, supersession, and LLM Dream prompts, but semantic embeddings/clustering are the hardest part. Options: FTS/tag/title clustering fallback, or port embedding cache only if dependencies are acceptable. Call out if semantic parity is intentionally approximate.
- **Dream interactive behavior:** external interactive mode reruns after confirmation, meaning final actions may differ. Acceptance wants “generate proposed mutations, show proposals, apply only after approval”; Swift should preferably apply the exact approved proposed actions rather than rerun, unless matching external behavior is explicitly desired.
- **Timestamps:** canonical DB uses epoch milliseconds; current Swift models use `Date` encoded ISO8601. Conversion mistakes will break newest sort and effective-weight decay.
- **Tags/synthesizedFrom JSON:** canonical DB stores arrays as JSON text. Current app writes tags as comma-separated frontmatter. New code must parse/encode JSON arrays robustly.
- **Old Agent Deck memories:** there may be existing app-support Markdown memories. Acceptance focuses on existing *current Pi* memories; decide whether to show/migrate old Agent Deck memory separately to avoid silent data loss.
- **Secret scanning:** current Agent Deck blocks secrets; external canonical `store_memory` does not show a secret scanner in the tool. Requirement says canonical behavior, but app may want to preserve safety. If preserving, document as app-owned hardening.

## 6. Recommended implementation direction

1. Add a native Swift Pi memory backend targeting `~/.pi/agent/memories/memories.db` with canonical `Memory` model and exact DB migrations/FTS triggers from `store.sqlite.ts`. Keep durable state Swift-owned at runtime; do not mutate/reference the external TS extension.
2. Replace old Memory Library data source with canonical rows filtered by default to `project in {"general", deriveProjectID(selectedProjectPath)}` and `superseded_by IS NULL` for “current” view. Include a toggle/filter to show superseded/history.
3. Map old UI concepts carefully:
   - kind/type: canonical `fact/event/procedure/insight`.
   - scope: `general` vs selected project ID.
   - status: current vs superseded; optional app-hidden/stale only if approved.
   - summary/body: canonical `title/content/reasoning`; show content and reasoning separately.
4. Implement sort state in `MemoryScreen`: default newest-first (`createdAt` or `lastAccessed`? Acceptance says newest; use `createdAt DESC` unless planner chooses `lastAccessed` for “updated”); alternate sorts: effective weight/relevance, project/scope, type, title, created, lastAccessed/updated where supported. Since canonical DB has no `updated_at`, use `last_accessed` for “updated/accessed” and explain in UI/test naming.
5. Update bridge to canonical tools. The TS bridge can remain as a transport shim to Swift (`ctx.ui.editor`) but tool names/schemas/behavior should be canonical and handled by Swift. Do not call external TS extension or `/dream`.
6. Implement Dream as a Swift service with two phases: `propose` returns `DreamAction` proposals with progress and errors; UI presents grouped actions; `apply(approvedActions)` mutates DB exactly once. Use existing one-shot Pi helper patterns (`SkillDescriptionGenerationService.swift`) or Foundation Models for LLM calls; use JSON schemas/prompts from the external modules. Start with deterministic FTS/tag clustering if embedding parity is too large; make that explicit in docs/tests.
7. Preserve parent recall snapshot semantics from `AppViewModel.swift:5135-5171`, but change prompt text/index format to canonical memory instructions/tool names and include general+current project. Keep native subagent memory injection but avoid external extension duplicate registration.

## 7. Validation targets

Recommended targeted tests before full app build:

- `AgentMemoryStoreTests` rewrite/add:
  - creates/migrates canonical SQLite schema with FTS triggers;
  - loads existing rows for `general + agent-deck` by default and excludes other projects;
  - parses/encodes tags and synthesizedFrom JSON;
  - default newest-first sort and alternate sort comparators;
  - update editable fields including type/scope/tags/weight/supersedes; cycle/self/invalid target errors;
  - delete repairs supersession chain exactly like `store.sqlite.ts:670-711`;
  - reinforce increments access count/last accessed and effective-weight calculation matches TS formula.
- Bridge source tests (`PiNativeBridgeExtensionSourceTests`): generated memory bridge registers `store_memory`, `recall_memories`, `reinforce_memory`, `update_memory`, `delete_memory`; does **not** register old `agent_deck_memory_*`; schemas contain canonical params and `additionalProperties: false` if desired.
- Launch/tool tests: parent and native subagent launch args include canonical memory tool names only when memory enabled; user-selected extensions still load last; no duplicate old names in allowlist.
- View/model tests (if available): Memory Library loading state, general+project filter, search filter, sort picker/menu behavior, edit sheet field roundtrip, manual delete/hide confirmation.
- Dream tests:
  - proposal generation with fake LLM JSON for merge/synthesize/reweight/contradiction/pattern;
  - cancel/no-op leaves DB unchanged;
  - approval applies exact proposed actions, creates/supersedes/reweights rows, and logs progress/errors;
  - LLM timeout/invalid JSON yields skip/error proposal rather than mutation.
- Full local validation after changes: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`, then targeted tests first; stop retrying if verification hangs twice.
