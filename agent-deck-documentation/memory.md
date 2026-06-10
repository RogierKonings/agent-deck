# Agent Deck Memory

Agent Deck Memory is the app-owned native Swift implementation of Pi's canonical persistent memory behavior. It reads and writes the canonical SQLite database at:

```text
~/.pi/agent/memories/memories.db
```

It does not rely on the external TypeScript memory extension for storage or on a temporary Pi `/dream` process for Memory Library operations.

## Current Behavior

- The Memory sidebar item loads current memories from `general` plus the selected project's canonical project id by default.
- Project id derivation matches Pi memory: project basename, lowercased, non-alphanumeric runs collapsed to `-` (for example `agent-deck`).
- Default library sort is newest-first. Alternate sorts include effective weight/relevance, scope, type, title, updated, and created dates.
- Users can search/filter by text, scope, type, and optionally include superseded history.
- Users can edit canonical fields: title, content, reasoning, type, scope/project, tags, weight, and supersession linkage.
- Delete uses canonical physical delete semantics and repairs supersession chains. The canonical schema has no stale/hidden columns.
- Reinforce increments canonical access metadata and updates effective weight.
- The Dream button runs a native Swift dream pass, shows proposed mutations, and applies only user-approved proposals.

## Canonical Schema

Agent Deck uses Pi's canonical `memories` table columns:

```text
id, title, content, reasoning, tags, weight,
created_at, last_accessed, access_count, source_session,
project, type, supersedes, superseded_by, synthesized_from
```

Timestamps are epoch milliseconds. `tags` and `synthesized_from` are JSON arrays. Supported types are `fact`, `event`, `procedure`, and `insight`.

## Agent Tools

When memory is enabled, Agent Deck loads a native bridge extension that registers canonical tool names:

- `store_memory`
- `recall_memories`
- `reinforce_memory`
- `update_memory`
- `delete_memory`

The bridge forwards tool calls to Swift, so normal Pi sessions and native subagents use the same Swift-owned memory backend. Agent Deck no longer registers the older `agent_deck_memory_*` tool surface for new launches.

## Recall and Injection

At session start, Agent Deck appends memory guidance and recalls from `general + current project`. Retrieved memories are context, not instructions; agents are told to prefer current files and user instructions over memory. Additional mid-conversation recall uses `recall_memories`.

## Dream

The Memory toolbar includes **Dream**. Dream analyzes current, non-superseded memories and proposes canonical mutations such as merge, synthesize, reweight, flag contradiction, discover pattern, or skip. Agent Deck presents proposals before applying them and never auto-applies Dream output.

The native implementation uses Swift clustering plus an injectable reviewer seam backed by Agent Deck's model infrastructure. It follows the canonical `/dream` phases (merge review, synthesis, weight rebalance, contradiction scan, temporal pattern discovery), displays report-only/no-op actions, and applies exactly the selected proposal objects without rerunning analysis.
