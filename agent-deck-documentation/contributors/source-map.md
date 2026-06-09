# Source Map

Use this file to quickly find the source of a behavior.

Paths are relative to `agent-deck/`. See `docs/agent-guidelines/ARCHITECTURE.md` for the full folder layout.

## Core models

- `Models/Models.swift` — resource records, agent configs, effective agents, chains, skills, prompts, settings summaries, env keys, snapshots
- `Models/PiAgentSessionCoreModels.swift` — Pi Agent session state, native subagent records, bridge request payloads, supervisor request models
- `Models/GitHubModels.swift` — GitHub auth, issue, board, and repository change models

## Scanning and refresh

- `Services/Catalog/PiScanner.swift` — resource discovery, parsing, baseline resolution, warnings, runtime command scan
- `Services/Pi/PiAgentLaunchResolver.swift` — app assignment-based native agent resolution
- `Services/Catalog/AppRefreshService.swift` — project/global snapshot orchestration, watch fingerprinting, and FSEvents monitor
- `Services/Projects/ProjectDiscovery.swift` — local project discovery and GitHub remote extraction
- `agent-deck-documentation/resource-refresh-and-file-watching.md` — refresh/watch lifecycle, debounce, and fallback polling behavior

## Persistence and editing

- `Services/Catalog/AgentPersistence.swift` — custom agents and builtin overrides
- `Services/Catalog/EnvPersistence.swift` — `.env` key updates
- `Services/Catalog/SubagentConfigPersistence.swift` — native/subagent config JSON

## Pi runtime integration

- `Services/Pi/PiAgentProcess.swift` — process launch, Pi executable resolution, stdout/stderr streaming
- `Services/Pi/PiRPCClient.swift` — JSONL RPC client and commands
- `Services/Pi/PiAgentRunnerService.swift` — parent session orchestration
- `Services/Pi/PiModelDiscoveryService.swift` — model catalog parsing/probing

## Native subagents

- `Services/Pi/PiSubagentRunService.swift` — child run construction and event handling
- `Services/Pi/PiNativeSubagentBridgeExtensions.swift` — generated parent/child bridge tools
- `Services/Pi/PiSubagentWorktreeService.swift` — worktree isolation and patch application
- `bundled-agents/*.md` — bundled native starter agents

## UI

- `Features/Shell/ContentView.swift` — main navigation, toolbar commands, sheets, and screen routing
- `Features/Agents/AgentManagementViews.swift`, `Features/Skills/SkillManagementViews.swift` — resource management screens
- `Features/PiAgent/Screen/PiAgentScreen.swift` — Pi Agent screen shell
- `Features/PiAgent/Composer/`, `Features/PiAgent/Transcript/`, `Features/PiAgent/Subagents/` — Pi Agent composer, transcript, and native subagent UI
- `Features/Prompts/PromptsViews.swift` — prompts screen
- `Features/GitHub/` — GitHub screen and feature sections
- `Features/Settings/` — settings, extensions, models screens
- `Design/MarkdownViews.swift` — markdown rendering

## GitHub and Git

- `Services/GitHub/GitHubCLIAuthService.swift` — `gh` auth/token lookup
- `Services/GitHub/GitHubAPIClient.swift` — REST client
- `Services/GitHub/GitHubSearchService.swift` — issue board search
- `Services/GitHub/GitHubIssueService.swift` — issue details/comments/relationships/actions
- `Services/Git/GitRepositoryService.swift` — git status/diff/stage/commit/push
