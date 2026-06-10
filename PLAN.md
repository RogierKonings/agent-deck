# Performance Improvement Plan — agent-deck

This document is a self-contained work plan for improving runtime performance of agent-deck
(native macOS SwiftUI app that runs Pi sessions via the `pi` CLI in JSONL RPC mode).
It is written so that each task can be executed independently by an implementing agent
without re-doing the analysis.

## How to work with this plan

- Execute tasks in order within a phase. Phases are ordered by user-visible impact.
- Each task lists: the problem, the exact files, the change to make, and how to verify.
- After EVERY task, build and run tests before moving on:
  - Build: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
  - Tests: `xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' test`
- Line numbers are approximate (snapshot from June 2026). Search for the quoted code if lines drifted.
- Make one focused commit per task. Do not combine tasks in one commit.

## Critical constraints — DO NOT VIOLATE

These mitigations already exist and MUST be preserved. Do not "simplify" them away:

- Assistant streaming tokens are buffered and flushed every 33–60ms with `persist: false`
  (`PiAgentRunnerService` ~line 1503–1560). Keep this.
- `PiAgentSessionStore` debounces transcript writes (750ms) and session-index writes (450ms),
  and coalesces `transcriptRevision` bumps at 66ms. Keep all of this.
- `PiAgentTranscriptRenderCache` coalesces UI publishes at 33ms. Keep this.
- `PiAgentScreen` holds the render cache as `@State` (NOT `@StateObject`) so the screen body
  does not subscribe to the cache's ~30Hz pulses; only `PiAgentTranscriptHost` observes it
  via `@ObservedObject`. Keep this isolation (`PiAgentScreen.swift` ~line 51–60).
- `SessionListContent`, `PiAgentSessionRow`, and `PiAgentComposerPanel` use `.equatable()`
  guards. Keep them.
- `AppViewModel` is `@Observable` injected with `.environment(viewModel)` — do NOT convert
  anything to `ObservableObject`/`@Published`/`EnvironmentObject`.
- `RPCDebugLog` and `HangWatchdog` are DEBUG-only. Leave them functional in DEBUG builds.
- Never edit bundled built-in resources in place; user edits go through override/persistence paths.

## Background: the streaming hot path

```
pi CLI stdout
  -> LineStreamReader (FileHandle readabilityHandler, PiAgentProcess.swift)
  -> PiRPCClient (JSONL decode per line)
  -> Task { @MainActor } per stdout batch
  -> PiAgentRunnerService.handle(...)        [@MainActor]
  -> PiAgentSessionStore (upsert, revision++) [@MainActor, coalesced 66ms]
  -> PiAgentTranscriptRenderCache (publish, coalesced 33ms)
  -> PiAgentTranscriptHost / PiAgentAppKitTranscriptView (NSTableView)
```

During token streaming this whole chain runs ~15–30 times per second. Anything O(N) in the
transcript length, any synchronous disk write, and any subprocess spawn on `@MainActor`
directly causes UI hitches. Most tasks below remove exactly that kind of work.

---

# Phase 1 — Main-thread stalls (highest impact)

## Task 1.1 — Move AgentMemoryStore SQLite work off the main actor

**Problem.** `AgentMemoryStore` (`agent-deck/Services/Memory/AgentMemoryStore.swift`) is
`@MainActor @Observable` and runs SQLite through a **spawned `sqlite3` subprocess** with
`Thread.sleep` polling and `waitUntilExit` (see `runWithOutput(sql:)` ~line 677–733, with a
5-second timeout). Every mutation (`createMemory`, `updateMemory`, `reinforceMemory`,
`deleteMemory`, `markUsed`, `setStatus`) ends in `refresh()` (~line 80–92), which spawns
sqlite3 again and reloads **all rows**. These are invoked synchronously from
`PiAgentRunnerService.handle()` (memory bridge handlers, ~line 2033–2110) while a session is
streaming — each memory tool call can block the main thread for tens to hundreds of ms.
Also: `retrieve()` (~line 283–285) is `async` but just calls `retrieveNow` inline on MainActor,
and `createMemory` calls `loadAllRecords()` twice (~line 149–172).

**Change.**
1. Introduce a non-main executor for DB work. Simplest safe approach: keep
   `AgentMemoryStore` as the `@MainActor` facade, but move all subprocess/SQL execution
   into a new `actor AgentMemoryDatabase` (same file or a new file
   `agent-deck/Services/Memory/AgentMemoryDatabase.swift`). All `runWithOutput`/`run` calls
   move into the actor. The `@MainActor` store `await`s the actor and then applies results
   to its `@Observable` `records` state.
2. Make mutations incremental: after a successful INSERT/UPDATE/DELETE, mutate the in-memory
   `records` array directly (insert/replace/remove the one record) and bump `revision`,
   instead of calling full `refresh()`. Keep `refresh()` only for explicit reload
   (init, external change, error recovery).
3. Batch `markUsed`: accumulate IDs and flush with a short debounce (e.g. 1s) in a single
   UPDATE statement; do not call `refresh()` after it at all (only `access_count`/
   `last_accessed` change — update the in-memory records directly).
4. In `PiAgentRunnerService`, make the memory bridge handlers (`handleMemoryWrite`,
   `handleMemoryReinforce`, `handleMemoryUpdate`, `handleMemoryDelete`, recall) async:
   wrap the work in a `Task { @MainActor in ... await ... }` and call
   `respondToExtensionUI(id:value:)` only after the awaited result. Confirm the Pi protocol
   tolerates the response arriving asynchronously (it already does for `retrieve`, which is
   async today — follow that pattern).
5. Fix `retrieve()` to actually run scoring off-main: load/score inside the DB actor or a
   `Task.detached`, then return.
6. Fix `createMemory` to not call `loadAllRecords()` twice: validate supersession with a
   targeted SELECT, insert the row, append to `records` in memory.

**Do NOT** change the on-disk schema or the FTS table in this task.

**Verify.** Build + tests. Manually: run a Pi session that triggers memory writes
(or unit-test the store) and confirm memories still create/update/delete and appear in the
Memory screen. In DEBUG, `HangWatchdog` should no longer report hangs during memory tool calls.

## Task 1.2 — Stop persisting on every `tool_execution_update`

**Problem.** In `agent-deck/Services/Pi/PiAgentRunnerService.swift` (~line 1810–1844), the
`tool_execution_update` case calls `store.upsert(...)` with the default `persist: true`.
Long-running tools (bash, web fetch) emit many partial updates per second; each one snapshots
the transcript for disk and schedules the session-index save. Assistant deltas already use
`persist: false` — tool updates should match.

**Change.** Pass `persist: false` on the `tool_execution_update` upsert. Ensure the
corresponding `tool_execution_end` (and session end / runner teardown paths) performs a
persisting upsert or explicit persist so the final tool result is durable. Check how
`flushStreamingEntries` finalizes assistant text and mirror that lifecycle.

**Verify.** Build + tests. Run a session with a long tool call, kill the app after the tool
finishes, relaunch, confirm the tool card content survived.

## Task 1.3 — Same fix for subagent streaming flushes

**Problem.** `agent-deck/Services/Pi/PiSubagentRunService.swift` (~line 468–492) flushes
subagent thinking/assistant streaming every 33ms via `store.upsertSubagentTranscript(...)`,
which persists to disk on every flush (no `persist:` parameter exists on the subagent path).

**Change.** Add a `persist: Bool = true` parameter to `upsertSubagentTranscript` in
`PiAgentSessionStore`, pass `false` from the streaming flushes, and persist once when the
subagent turn/run completes (mirror the parent-session pattern from Task 1.2).

**Verify.** Build + tests. Run a native subagent, confirm its transcript persists after
completion and after app relaunch.

## Task 1.4 — Reuse JSON coders in the RPC hot path

**Problem.**
- `agent-deck/Services/Pi/PiRPCClient.swift` (~line 47–52) allocates `JSONDecoder()` for
  **every stdout line** inside `onStdoutLines`.
- `agent-deck/Services/Pi/PiAgentRunnerService.swift` bridge handlers (~line 2033 and several
  similar sites) allocate `JSONDecoder()` per event.
- `agent-deck/Services/Pi/PiAgentSessionStore.swift` (~line 1674–1688) declares
  `static var piAgent: JSONEncoder` / `JSONDecoder` as computed `var`s, building a new
  configured instance on every persist/load.

**Change.**
1. In `PiRPCClient`, create one `JSONDecoder` per client instance (it is used from the
   readability-handler callback serially, so a single instance per client is safe) and reuse
   it in `onStdoutLines`.
2. Change `JSONEncoder.piAgent` / `JSONDecoder.piAgent` from computed `static var` to
   `static let` with closure initialization. They are `nonisolated`; JSONEncoder/Decoder
   instances are safe to share for encode/decode-only use, but if the compiler complains
   under strict concurrency, keep them as `let` inside the existing `nonisolated` extension
   or wrap access through the existing `saveQueue`.
3. Replace per-call `JSONDecoder()` in the bridge handlers with one shared decoder stored on
   `PiAgentRunnerService`.

**Verify.** Build + tests. Run a streaming session and confirm transcripts render and persist
identically.

## Task 1.5 — Single MainActor drain per session instead of a Task per stdout batch

**Problem.** `agent-deck/Services/Pi/PiAgentRunnerService.swift` (~line 688–694): every
readability-handler batch schedules a fresh unstructured `Task { @MainActor }`. With multiple
concurrent sessions and chatty tools, this creates heavy MainActor enqueue churn and prevents
cross-batch coalescing. Same pattern exists in `PiSubagentRunService.swift` (~line 273–279)
and `PiProviderLoginService.swift` (~line 80–81).

**Change.** Replace the per-batch Task with one long-lived drain per client:
use an `AsyncStream<[EventLine]>` (continuation captured by the `onEvent` callback, which
just calls `continuation.yield(events)`) plus a single `Task { @MainActor in for await batch
in stream { ... handle each event ... } }` started when the client launches and finished/
cancelled on teardown. Preserve event ordering (AsyncStream is FIFO; use
`bufferingPolicy: .unbounded`). Apply the same pattern to the subagent service. The login
service is low-traffic — change it only if trivial.

**Verify.** Build + tests. Run two streaming sessions simultaneously; confirm transcripts
remain ordered and complete, and session teardown does not leak the drain task (finish the
continuation in the termination handler).

---

# Phase 2 — Streaming transcript O(N) work

## Task 2.1 — Make the transcript items signature incremental

**Problem.** `agent-deck/Features/PiAgent/Screen/PiAgentScreen+AppKitTranscriptItems.swift`:
`appKitTranscriptItems` (~line 9–24) is memoized by a signature, but
`appKitTranscriptItemsSignature` (~line 34–52) itself computes `transcriptTimelineSnapshot`
(maps + sorts all threads) and hashes **every subagent run** — on every
`PiAgentTranscriptHost.body` evaluation (~30Hz while streaming). The memo avoids the full
build (a documented 20–37ms cost) but not the O(N) signature.

**Change.** Replace the heavy signature with one composed only of cheap monotonic inputs:
`transcriptCache.renderRevision`, `transcriptCache.streamingRevision`, the selected session
ID, and a `subagentRunsRevision` counter. If `PiAgentSessionStore` does not already maintain
a revision counter that bumps whenever `subagentRuns(for:)` results change, add one
(increment it in every code path that mutates `subagentRunsBySessionID`) and hash that
instead of iterating runs. Audit what else the current signature covers (width/theme inputs
etc.) and keep equivalent cheap proxies — the requirement is: every input that can change the
built items must bump at least one hashed revision.

**Verify.** Build + tests. Stream a session with active subagents: subagent cards must still
update live. Use the DEBUG `TranscriptScrollProfiler` output: `itemsBuild` log lines should
show near-zero cost on memo hits.

## Task 2.2 — Stop PiAgentScreen body from re-evaluating at streaming cadence

**Problem.** `agent-deck/Features/PiAgent/Screen/PiAgentScreen.swift`:
- `.task(id: store.selectedTranscriptRevision)` (~line 182–184) and
- `.onChange(of: store.transcriptRevisionsBySessionID)` (~line 171–172)

both read store revision state inside the screen body/modifiers, registering observation so
the whole `PiAgentScreen` body re-runs ~15Hz during streaming. That also rebuilds derived
maps each pass (`workingVisibleSessionIDs`, `visibleSessionProjectsByID` ~line 419–436;
`scopedSessions` sort ~line 218–231), and `rebuildSessionActivityCache()` runs even when a
*background* session's revision changed.

**Change.**
1. Replace the dictionary-wide `.onChange(of: store.transcriptRevisionsBySessionID)` with a
   scalar: add a computed/stored per-selected-session revision on the store (or read
   `store.transcriptRevisionsBySessionID[store.selectedSessionID]` inside a small extracted
   child view) so only the selected session's changes trigger `rebuildSessionActivityCache()`.
2. Move the transcript-cache scheduling out of the screen body: the cleanest option is to
   extract a tiny invisible child view (or move the `.task(id:)`/`.onChange` onto
   `PiAgentTranscriptHost` itself) whose body reads `store.selectedTranscriptRevision` and
   calls `scheduleTranscriptCacheUpdate()`, so the observation registration is scoped to that
   child instead of the whole screen. Alternatively, drive the cache directly from the store
   via a non-SwiftUI callback (closure the screen registers on appear) — pick whichever fits
   the existing code with the smallest diff.
3. Cache `workingVisibleSessionIDs` / `visibleSessionProjectsByID` / `scopedSessions` in
   `@State`, recomputed only via `.onChange` of `store.sessionListRevision` (this revision
   already exists), following the existing `cachedVisibleSessions` pattern (~line 237–246).

**Verify.** Build + tests. DEBUG: the existing `SessionListPerf` log and
`TranscriptScrollProfiler` should show the session list and screen body no longer re-evaluate
per streaming pulse. Functional: selecting sessions, streaming updates, git-activity badges
all still work.

## Task 2.3 — Incremental render-cache publish for streaming tail

**Problem.** `agent-deck/Features/PiAgent/Transcript/PiAgentTranscriptRenderCache.swift`
(~line 95–122): every coalesced publish (~30Hz while streaming) re-runs
`compactMap(normalizedTranscriptEntry).filter(isValuableTranscriptEntry)` →
`coalescedCompactionEntries` → `normalizeThinkingOrder` → `PiAgentTranscriptThread.make`
over the **entire** transcript. For long sessions this is significant main-thread work per
token flush.

**Change.** Add a fast path: when the new `rawEntries` differ from the previous publish only
in the LAST entry (same count and same IDs except the tail, or count grew by appending — the
common streaming shapes), update only the affected entry/thread in place and bump
`streamingRevision`, skipping the full normalize/threading pipeline. Keep the existing full
rebuild for every other shape (structural change → `renderRevision += 1`). Be conservative:
if detection of "tail-only change" is at all ambiguous, fall back to the full rebuild.
Keep behavior identical — this is purely a compute shortcut.

**Verify.** Build + tests. Stream a long session (100+ entries): transcript content,
thinking-block ordering, and tool cards must be pixel-identical to before (compare against a
full-rebuild run). Profiler `itemsBuild`/publish times should drop for long transcripts.

## Task 2.4 — Soften the synchronous retile during streaming

**Problem.** `agent-deck/Features/PiAgent/Transcript/PiAgentAppKitTranscriptView.swift`
(~line 682–706): on every streaming revision the coordinator reconfigures changed cells, then
runs `measureChangedCellsSynchronously` + `flushPendingHeightWorkSynchronously` +
`noteHeightsChanged` — synchronous measure and table retile on the main thread ~30Hz. The
in-file comments explain this fixes "squish→snap" wobble, so it cannot simply be removed.

**Change (careful, behavior-sensitive).** Reduce frequency, not correctness:
1. Track the last synchronous-retile timestamp in the coordinator. During active streaming
   (streamingRevision changed but renderRevision did not), allow at most one synchronous
   measure+retile per display refresh (~16ms) — if one ran more recently, schedule a single
   trailing retile via the existing pending-height machinery instead of forcing another.
2. Skip `noteHeightsChanged` when the measured height delta for every changed row is zero
   (measure returned same heights) — only reconfigure content in place.
Do not change the structural (renderRevision) path.

**Verify.** Build + DEBUG run with `TranscriptScrollProfiler`: `retile`/`forcedMeasure`
counts during streaming should drop substantially. Visually verify NO bubble wobble/squish
regression while streaming into the last visible bubble, and while scrolled up during
streaming. If wobble reappears, tighten the throttle (e.g. allow 2 per frame) rather than
reverting entirely.

## Task 2.5 — Cache `enabledAvailableModels` on AppViewModel

**Problem.** `agent-deck/AppShell/ViewModel/AppViewModel.swift` (~line 88–90):
`enabledAvailableModels` filters `modelCatalog.availableModels` on every read; the comment
above it (~line 67) documents that the toolbar reads model lists on every `ContentView.body`
eval (once per streaming token). The sibling `cachedAutomationAvailableModels` already shows
the fix pattern.

**Change.** Add `@ObservationIgnored private var cachedEnabledAvailableModels: [AvailableModel]`
plus a small observable revision (or reuse the existing automation-cache rebuild trigger):
rebuild inside `rebuildAutomationModelCaches()` (it already runs at every real model/settings
boundary) and return the cached array from `enabledAvailableModels`. Ensure every place that
mutates `modelCatalog.availableModels` or model-availability settings calls the rebuild —
check existing call sites of `rebuildAutomationModelCaches()`.

**Verify.** Build + tests. Toggle model availability in settings; the composer/toolbar model
picker must reflect changes immediately.

---

# Phase 3 — Catalog scanning, startup, background services

## Task 3.1 — Stop loading full skill bodies during catalog scans

**Problem.** `agent-deck/Services/Catalog/PiScanner.swift` (~line 248–261): every catalog
refresh reads every `SKILL.md` fully into `SkillRecord.body`. Refreshes happen at startup
(twice), on FSEvents, on a 5-minute timer, and on app activation — O(total skill files) of
file I/O and resident memory each time.

**Change.** Make `body` lazy: during scan, parse only the frontmatter/metadata needed for
list display (name, description, scope, path) and leave `body` empty or behind an accessor
that reads the file on demand. Find all consumers of `SkillRecord.body`
(`rg "\.body" agent-deck --type swift` and filter to SkillRecord usage) — typically the skill
detail view and any prompt-injection path — and switch them to an on-demand read
(`String(contentsOf:)` at point of use, off-main where possible). If too many consumers
depend on eager `body`, an acceptable fallback is to cap eager reads to frontmatter-only
parsing (read first N KB) and load the full body lazily.

**Verify.** Build + tests. Skill list renders, skill detail shows full body, launching a
session with a skill still injects full content.

## Task 3.2 — Cheapen the file-watch fingerprint

**Problem.** `agent-deck/Services/Catalog/AppRefreshService.swift`
(`FileWatchFingerprint.make`, ~line 170–199) recursively enumerates every watched directory
(including per-skill paths) computing mtimes. It runs after every refresh, every 5 minutes
(`CatalogAutoRefreshCoordinator.swift` ~line 47–51), and on every app activation — redundant
with FSEvents and expensive for large skill libraries.

**Change.** Reduce the fingerprint to the top-level watch roots only: directory mtime +
direct-children names/mtimes (one shallow `contentsOfDirectory` per root) rather than a full
recursive walk. FSEvents already covers deep changes while the app runs; the fingerprint only
needs to catch changes made while the app was inactive, and root/shallow mtimes catch the
overwhelming majority. Keep the computation on the detached task it already runs on. If a
deep change while inactive is genuinely missed, the existing 5-minute timer + manual refresh
remain as backstops — note this trade-off in a code comment.

**Verify.** Build + tests. Edit a skill file while the app is backgrounded, activate the app,
confirm the catalog refreshes (file's parent dir mtime changes, so shallow fingerprint
catches it).

## Task 3.3 — Defer model discovery off the launch path

**Problem.** `agent-deck/AppShell/ViewModel/AppViewModel.swift` (~line 229) calls
`refreshAvailableModels()` in init. That spawns `pi --list-models` plus a large `node --eval`
script (`PiModelDiscoveryService.swift` ~line 12–110) during cold launch, competing with the
catalog scan and session-store load.

**Change.**
1. Persist the last discovery result (models + thinking levels) to a JSON cache in
   Application Support. On launch, load the cache synchronously-cheap (small file, decode in
   a detached task) and populate the catalog from it immediately.
2. Schedule the real `pi --list-models` refresh after launch settles (e.g. 3–5s delay at
   `.utility` priority, or on first composer/Models-screen open), updating the catalog and
   rewriting the cache when it completes.
3. First-ever launch (no cache): keep current behavior but at `.utility` priority.

**Verify.** Build + tests. Cold launch shows models from cache instantly; adding/removing a
provider eventually reflects after the deferred refresh.

## Task 3.4 — Don't persist the session index on every `get_session_stats`

**Problem.** `agent-deck/Services/Pi/PiAgentRunnerService.swift` (~line 1240–1262): each
`get_session_stats` response during streaming calls `store.updateSession { ... }` setting
token-count fields, and `updateSession` (`PiAgentSessionStore.swift` ~line 501–532) always
calls `save()` — scheduling a full session-index encode (the snapshot serializes ALL sessions
+ subagent runs, ~line 1502–1541) on the 450ms debounce, repeatedly, for ephemeral stats.

**Change.** Add a `persist: Bool = true` parameter to `updateSession` (or a dedicated
`updateSessionStats` method) that skips `save()`. Use it for the `get_session_stats` path.
Ensure stats are persisted at meaningful boundaries: turn end / session stop / app
termination (the existing final saves cover the last two; add one persisting update at turn
completion if not already present).

**Verify.** Build + tests. Token counts still display live during streaming and survive app
relaunch after a completed turn.

## Task 3.5 — Reuse one Pi helper for memory-dream phases

**Problem.** `agent-deck/Services/Automation/PiMemoryDreamService.swift` (~line 32–50 and
`startPiHelper` ~line 503–558): a dream run spawns a fresh `pi` RPC process per LLM call —
up to 15 clusters × (merge + synthesize) + 3 global phases. Each spawn pays process startup
(45s timeout budget each). Background work, but it saturates CPU and the process table.

**Change.** Restructure `PiMemoryDreamLLMReviewer` to launch ONE `PiRPCClient` helper
(`--no-session --no-extensions`) at the start of a dream run and send each phase as a
sequential prompt on that client, tearing it down at the end. If the Pi RPC mode cannot do
multiple independent prompts in one process cleanly, fall back to: cap to one in-flight
helper at a time (it is already sequential) AND batch multiple clusters into a single prompt
per call to cut call count (e.g. review 5 clusters per request, parse a JSON array response).

**Verify.** Build + tests. Trigger a dream run from the Memory screen; proposals still
generate; observe (Activity Monitor or `ps`) that only one `pi` helper process exists during
the run.

## Task 3.6 — Memoize Memory screen filtering

**Problem.** `agent-deck/Features/Memory/AgentMemoryViews.swift` (~line 47–57):
`filteredRecords` filters + sorts all records (string joins per record) on every body
evaluation; the body re-runs on dream-state updates and store revision bumps.

**Change.** Cache the filtered+sorted list in `@State`, recomputed in `.onChange` of the
inputs (`store.revision`, `searchText`, active filters, sort selection) — the same pattern
used by `cachedLayout` in `AgentManagementViews.swift` (~line 461–523).

**Verify.** Build + tests. Search, filters, and sort still work; list updates when memories
change.

---

# Phase 4 — Smaller cleanups (do after Phases 1–3)

## Task 4.1 — Static regex/formatter instances in views
- `agent-deck/Features/PiAgent/Transcript/PiAgentTranscriptCardViews.swift` (~line 294, 382):
  `NSRegularExpression(pattern:)` per call → hoist to `static let` (pattern already used
  throughout `MarkdownViews.swift`).
- `agent-deck/Features/Projects/ProjectViews.swift` (~line 2361) and
  `agent-deck/Features/GitHub/GitHubConnectionViews.swift` (~line 85): `DateFormatter()` in
  view code → `static let` formatters.

## Task 4.2 — Avoid `Data → String → Data` round-trip per RPC line
`PiAgentProcess.swift` `normalizedLine(from:)` (~line 239–242) converts each line to `String`,
then `PiRPCClient` re-encodes with `Data(line.utf8)` to decode. Thread the raw `Data` slice
through to the decoder and keep the `String` only where actually needed (rawLine storage,
debug logging). Also replace the per-byte newline scan in `LineStreamReader` (~line 206–218)
with `buffer.firstIndex(of: 0x0A)` in a loop. Pure refactor; verify streaming still works
including non-UTF8-safe edge bytes (keep the existing lossy conversion for the String copy).

## Task 4.3 — Patch-style writes for builtin agent overrides
`agent-deck/Services/Catalog/AgentPersistence.swift` (~line 144–174, 225–252): toggling one
agent flag loads + rewrites the whole `settings.json`. Low frequency; acceptable to keep, but
if touched, mutate only `subagents.agentOverrides.<name>` and write atomically (it already
uses `AtomicFileWriter`). Do NOT change file format.

## Task 4.4 — Update the stale perf comment
`agent-deck/Features/PiAgent/Transcript/PiAgentAppKitTranscriptView.swift` (~line 1585–1593)
claims the render cache invalidates the whole `PiAgentScreen.body`; that was fixed (cache is
`@State`, only `PiAgentTranscriptHost` observes). Rewrite the comment to describe the current
architecture so future agents don't "re-fix" it.

---

# Explicitly out of scope (do not do)

- Replacing the `sqlite3` subprocess with a linked SQLite/GRDB library (worthwhile but a
  separate project; Task 1.1's actor isolation is the contract that makes it easy later).
- Migrating `readabilityHandler` to `FileHandle.bytes` async sequences (optional, riskier;
  Task 1.5 captures most of the win).
- Splitting the ~11k-line `AppViewModel` into smaller observables (architecture work, not a
  targeted perf fix).
- JSONL append-only transcript persistence format changes.
- Any change to UserDefaults storage format for `AppSettings`/`ProjectPreferences`.

# Measurement / acceptance

The app ships DEBUG instrumentation — use it for before/after evidence:

- `TranscriptScrollProfiler` (`agent-deck/Debug/TranscriptScrollProfiler.swift`): logs
  `itemsBuild`, `updateNSView`, `retile`, `forcedMeasure`, scroll hitches (>24ms),
  and severe-hitch backtraces. Targets after Phase 2: `itemsBuild` ~0ms on memo hits;
  retile/forcedMeasure counts during streaming reduced by >50%.
- `HangWatchdog` (`agent-deck/Services/Utilities/HangWatchdog.swift`): main-thread hang
  reports. Target after Task 1.1: zero hang reports attributable to memory tool calls.
- `ScrollBenchEnabled` automated scroll benchmark in `PiAgentAppKitTranscriptView`.
- Cold-launch: time from launch to interactive sidebar before/after Task 3.3 (manual
  stopwatch or os_signpost is fine).

Regression gate for every task: full `xcodebuild ... test` pass, plus a manual streaming
session (tokens render live, transcript persists across relaunch, scrolling smooth).
