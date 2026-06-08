# Native Swift memory management for Agent Deck

## Problem
Agent Deck currently has its own Swift-owned Pi persistent memory support, but the canonical memory-management behavior now exists in `/Users/rogierkonings/.pi/agent/extensions/memory`. The app needs to replace the Agent Deck memory tool surface with a native Swift implementation of that behavior, while keeping the Memory Library useful for inspecting and managing current memories.

## Goal
Agent Deck should natively implement the Pi memory management tool in Swift, including reading existing current memories, sorting/filtering the Memory Library table, editing memory fields, manually deleting or hiding memories, and providing a Dream action that analyzes memory and proposes mutations before applying them. The UI should match existing app loading and icon conventions.

## Acceptance criteria
- [ ] The existing memory-management behavior from `/Users/rogierkonings/.pi/agent/extensions/memory` is mapped and reimplemented in Swift rather than relying on the TypeScript extension or a temporary Pi `/dream` process for core behavior.
- [ ] The Memory Library table loads current memory entries for `general` plus the current project by default.
- [ ] Existing memories from the active Pi memory store are visible in the Memory Library table after launch/refresh.
- [ ] The table defaults to newest-first sorting and supports alternate sorts such as weight/relevance, project/scope, kind/type, title, and updated/created dates where the data model supports them.
- [ ] Users can manually delete memories; if the backing model supports stale/hidden semantics, deletion uses stale/hidden behavior rather than destructive removal unless an explicit destructive path already exists.
- [ ] Users can modify editable memory fields beyond title/content, including available metadata such as kind/type, project/scope, tags, weight, stale/hidden status, and supersession linkage where supported.
- [ ] The Dream button is fully native Swift and implements the Pi `/dream` slash-command logic end-to-end: all non-superseded memory analysis, semantic/cluster review, merge, synthesis, weight rebalance, contradiction scan, temporal pattern discovery, dream-cycle logging/event memory, proposed mutations, user confirmation, and exact approved-action application without delegating to the external TypeScript extension.
- [ ] Dream supports cancel/no-op behavior and reports progress/errors using the same loading conventions as the rest of Agent Deck.
- [ ] Icons and controls reuse the current Agent Deck visual style rather than introducing a separate icon language.
- [ ] Normal Pi session extension loading does not double-register memory tools or regress existing Pi launches/native subagents.
- [ ] Validation covers build/type safety and at least targeted tests or testable seams for memory loading, sorting, editing/deleting, and Dream proposal/application logic.

## Non-goals
- Rewriting unrelated Pi extension selection or subagent features.
- Changing the external `/Users/rogierkonings/.pi/agent/extensions/memory` source of truth unless needed only for reference.
- Automatically applying Dream mutations without a confirmation step.
- Showing all projects by default; broader scopes can be optional filters.

## Constraints
- Keep durable memory state and core behavior Swift-owned inside Agent Deck.
- Do not edit bundled built-in resources in place; user edits must go through app persistence/override paths.
- Preserve existing app-wide loading, button, table, and icon styling conventions.
- Keep normal Pi session memory tool registration boundary-safe and avoid duplicate tool names.
- Default Memory Library scope is `general` plus the current project.
- Default Memory Library sort is newest first, with user-selectable alternatives.
- Manual deletion should prefer stale/hidden semantics when supported.

## Approach (chosen)
Use a scout/planner-driven native replacement: first map the external Pi memory extension behavior and the existing Agent Deck memory architecture, then plan the Swift file-level changes, implement the native Swift store/UI/Dream proposal pipeline, review, verify against this spec, and merge only after approval. This minimizes guessing about the TypeScript memory tool while preserving Agent Deck's existing Swift ownership boundary.

## Approaches considered (rejected)
- **Keep launching `/dream` extension in isolation**: rejected because the user explicitly requested a full native Swift reimplementation.
- **Deterministic Dream v1 approximation**: rejected after product clarification; Dream must be on par with Pi `/dream`, not just a safe heuristic propose/confirm/apply subset.
- **Destructive delete only**: rejected because the user prefers stale/hidden behavior when supported.
- **Show all memory by default**: rejected because the requested default scope is current project plus general.
- **Immediate Dream mutation**: rejected because proposed mutations must be shown first and confirmed.
- **Direct parent implementation without scout/planner**: rejected because this spans unknown external extension behavior, storage semantics, UI, and tests.

## Open questions
- None after user clarification. If the scout finds unsupported stale/hidden or supersession semantics in the active store, the planner should document the nearest safe fallback before implementation.
