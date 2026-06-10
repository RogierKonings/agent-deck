import AppKit
import SwiftUI

private struct ThreadMessageRow<Content: View>: View {
    enum CopySide { case leading, trailing }

    let copyText: String
    let copyOn: CopySide
    let cardMaxWidth: CGFloat
    var onFork: (() -> Void)? = nil
    /// When non-nil and non-empty, the fork affordance becomes a Menu offering
    /// "Fork as Pi session" (the original `onFork` action) plus a nested
    /// "Fork as 1:1 agent chat…" submenu. Otherwise the existing single
    /// `AppForkIconButton` is shown unchanged.
    var forkAgentOptions: [ForkAgentMenuItem]? = nil
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            if copyOn == .leading {
                Spacer(minLength: 60)
                card
            } else {
                card
                Spacer(minLength: 60)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var card: some View {
        // Both buttons float into the 60pt Spacer beside the card via .overlay,
        // never contributing to layout. Copy sits closer to the card; Fork sits
        // outboard of Copy. Leading side: [Fork][Copy][card]. Trailing side:
        // [card][Copy][Fork] — symmetric. Single button offset = 38pt (28pt
        // button + 10pt gap to card). Two-button HStack is 28+4+28 = 60pt;
        // offset 70 preserves the same 10pt gap to the card.
        content()
            .frame(maxWidth: cardMaxWidth, alignment: copyOn == .leading ? .trailing : .leading)
            .overlay(alignment: copyOn == .leading ? .leading : .trailing) {
                HStack(spacing: 4) {
                    if copyOn == .leading, onFork != nil {
                        forkAffordance
                    }
                    AppCopyIconButton(
                        text: copyText,
                        help: "Copy message",
                        size: CGSize(width: 28, height: 28)
                    )
                    if copyOn == .trailing, onFork != nil {
                        forkAffordance
                    }
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .offset(x: copyOn == .leading ? -(onFork == nil ? 38 : 70) : (onFork == nil ? 38 : 70))
            }
    }

    @ViewBuilder
    private var forkAffordance: some View {
        if let onFork {
            if let options = forkAgentOptions, !options.isEmpty {
                Menu {
                    Button("Fork as Pi session", action: onFork)
                    Menu("Fork as 1:1 agent chat…") {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            Button(option.title, action: option.action)
                                .disabled(option.isDisabled)
                        }
                    }
                } label: {
                    ZStack {
                        Color.clear
                            .contentShape(Capsule(style: .continuous))
                        Image(systemName: "arrow.trianglehead.branch")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Fork session…")
            } else {
                AppForkIconButton(action: onFork)
            }
        }
    }
}

struct PiAgentTranscriptThreadCard: View {
    /// Which slice of the thread to render. `.fullThread` is the original
    /// behaviour (used by the "Earlier Transcript" sheet). `.question` and
    /// `.child` each render exactly ONE `ThreadMessageRow` — this is what lets
    /// the AppKit transcript host each block as its own NSTableView row, so
    /// streaming/scrolling only touch one small block instead of a whole thread.
    enum RenderMode: Hashable {
        case fullThread
        case question
        case child(PiAgentThreadChild)
    }

    let thread: PiAgentTranscriptThread
    let visibility: PiAgentTranscriptVisibilitySettings
    let skills: [SkillRecord]
    var commandSlashNames: Set<String> = []
    let projectPath: String?
    let nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    let nativeSubagentCard: (PiSubagentRunRecord) -> PiNativeSubagentRunCard
    var renderMode: RenderMode = .fullThread
    /// Invoked when the hover-revealed Fork button on a user-message row is
    /// tapped. Only user-question rows render the button — child rows never do.
    /// nil disables the button (e.g. earlier-transcript sheet, where fork doesn't apply).
    var onFork: ((PiAgentTranscriptEntry) -> Void)? = nil
    /// When non-nil and non-empty, the fork button becomes a Menu that also
    /// offers "Fork as 1:1 agent chat…" with one row per agent. The closure
    /// receives the user message entry and the chosen agent.
    var forkAgentChoices: [EffectiveAgentRecord]? = nil
    var onForkAsAgentChat: ((PiAgentTranscriptEntry, EffectiveAgentRecord) -> Void)? = nil

    @Environment(\.transcriptContentWidth) private var transcriptContentWidth

    var body: some View {
        switch renderMode {
        case .fullThread: fullThreadBody
        case .question: questionBlock
        case .child(let child): childBlock(child)
        }
    }

    /// Builds the per-agent submenu items for the fork affordance on `entry`.
    /// Returns `nil` (single-action fork) when the upstream session has no
    /// agent choices wired up — i.e. subagents are off or no agents discovered.
    fileprivate func forkAgentMenuItems(for entry: PiAgentTranscriptEntry) -> [ForkAgentMenuItem]? {
        guard let choices = forkAgentChoices, !choices.isEmpty,
              let handler = onForkAsAgentChat else { return nil }
        return choices.map { agent in
            ForkAgentMenuItem(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { handler(entry, agent) }
            )
        }
    }

    @ViewBuilder
    private var fullThreadBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.threadSpacing) {
            questionBlock
            if hasChildren {
                VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
                    ForEach(thread.children) { child in
                        childBlock(child)
                    }
                }
            }
        }
    }

    /// The user-question row — iMessage-style right-aligned bubble with the
    /// hover-revealed glass copy + fork buttons just to its LEFT.
    @ViewBuilder
    private var questionBlock: some View {
        if let question = thread.question {
            ThreadMessageRow(
                copyText: question.text,
                copyOn: .leading,
                cardMaxWidth: PiAgentBubbleWidth.huggedUser(
                    text: PiAgentUserMessageContent.displayMessageText(for: question, skills: skills, commandSlashNames: commandSlashNames),
                    pillsWidth: PiAgentUserMessageContent.displayChipsNaturalWidth(for: question, skills: skills, commandSlashNames: commandSlashNames),
                    paneWidth: transcriptContentWidth
                ),
                onFork: onFork.map { handler in { handler(question) } },
                forkAgentOptions: forkAgentMenuItems(for: question)
            ) {
                PiAgentTranscriptCard(entry: question, style: .question, skills: skills, commandSlashNames: commandSlashNames)
                    .id(question.id)
            }
        }
    }

    /// One reply row — assistant / tool / status card on the left, copy button
    /// hover-revealed on the RIGHT. Divider-style status entries (Compaction +
    /// git completions) bypass ThreadMessageRow so they span the full transcript
    /// width instead of sitting inside the assistant bubble column.
    @ViewBuilder
    private func childBlock(_ child: PiAgentThreadChild) -> some View {
        if case .status(let entry) = child,
           entry.isDividerStatus,
           !Self.shouldHideNativeSubagentStatus(entry, nativeSubagentRunsByID: nativeSubagentRunsByID) {
            statusRowView(entry)
        } else {
            ThreadMessageRow(
                copyText: copyText(for: child),
                copyOn: .trailing,
                cardMaxWidth: PiAgentBubbleWidth.replyCap(for: transcriptContentWidth)
            ) {
                childView(child)
            }
        }
    }

    /// Plain-text representation of a thread child suitable for the system
    /// pasteboard. Combines text from underlying entries (or tool-group
    /// entries) and falls back to the raw entry text.
    private func copyText(for child: PiAgentThreadChild) -> String {
        switch child {
        case .steering(let entry), .thinking(let entry), .assistant(let entry),
             .status(let entry), .error(let entry):
            return entry.text
        case .toolGroup(let group):
            return group.entries.map(\.text).joined(separator: "\n\n")
        case .retry(let entry, _):
            return entry.text
        }
    }

    @ViewBuilder
    private func childView(_ child: PiAgentThreadChild) -> some View {
        switch child {
        case .steering(let entry):
            PiAgentTranscriptCard(entry: entry, style: childStyle, skills: skills, commandSlashNames: commandSlashNames)
                .id(entry.id)
        case .thinking(let entry):
            if visibility.showThinking {
                PiAgentTranscriptCard(entry: entry, style: childStyle, skills: skills, commandSlashNames: commandSlashNames)
                    .id(entry.id)
            }
        case .assistant(let entry):
            PiAgentTranscriptCard(entry: entry, style: childStyle, skills: skills, commandSlashNames: commandSlashNames)
                .id(entry.id)
        case .toolGroup(let group):
            toolGroupView(group)
        case .status(let entry):
            if Self.shouldShowStatusEntry(entry, visibility: visibility, nativeSubagentRunsByID: nativeSubagentRunsByID) {
                statusRowView(entry)
            }
        case .error(let entry):
            // Fatal turn/model/provider errors always render (even with the Errors
            // toggle off) so a turn that produced no output is never silent; tool
            // errors keep honoring the toggle.
            if entry.isModelError || visibility.showErrors {
                PiAgentStatusTranscriptRow(entry: entry)
                    .id(entry.id)
            }
        case .retry(let entry, let info):
            PiAgentRetryCard(info: info, timestamp: entry.timestamp)
                .id(entry.id)
        }
    }

    @ViewBuilder
    private func toolGroupView(_ group: PiAgentThreadToolGroup) -> some View {
        let webActivities = group.activities.filter(\.isWebActivity)
        let toolActivities = group.activities.filter { !$0.isWebActivity }
        // A tool group can emit several cards (web activity, tool calls, diffs).
        // They MUST be wrapped in a VStack — without an explicit vertical
        // container the sibling cards have no imposed arrangement, and the
        // enclosing row lays them out side by side instead of stacked.
        VStack(alignment: .leading, spacing: 8) {
            if visibility.showWebActivity, !webActivities.isEmpty {
                PiAgentWebActivitySummaryView(activities: webActivities)
            }
            if visibility.showToolCalls, !toolActivities.isEmpty {
                PiAgentActivitySummaryView(activities: toolActivities)
            }
            if visibility.showDiffs {
                PiAgentThreadDiffSummaryView(activities: toolActivities, projectPath: projectPath)
            }
        }
    }

    @ViewBuilder
    private func statusRowView(_ entry: PiAgentTranscriptEntry) -> some View {
        if let memoryEvent = entry.agentMemoryEvent {
            PiAgentMemoryActivityCard(event: memoryEvent)
                .id(entry.id)
        } else if let runID = entry.nativeSubagentRunID, let run = nativeSubagentRunsByID[runID] {
            nativeSubagentCard(run)
                .id(entry.id)
        } else {
            PiAgentStatusTranscriptRow(entry: entry)
                .id(entry.id)
        }
    }

    private var childStyle: PiAgentTranscriptCardStyle {
        thread.question == nil ? .standalone : .threadChild
    }

    private var hasChildren: Bool {
        !thread.children.isEmpty
    }

    static func shouldHideNativeSubagentStatus(
        _ entry: PiAgentTranscriptEntry,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> Bool {
        guard let runID = entry.nativeSubagentRunID,
              let run = nativeSubagentRunsByID[runID],
              run.mode == .single,
              let representedAt = parallelChildUpdatedAtByRunID(nativeSubagentRunsByID)[runID] else { return false }
        // Continuations reuse the same run ID and update the same transcript card.
        // Hide only the child entry while it is still represented by the parent
        // parallel card; later direct continuations must remain visible.
        return entry.timestamp <= representedAt.addingTimeInterval(5)
    }

    private static func parallelChildUpdatedAtByRunID(
        _ nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> [UUID: Date] {
        var output: [UUID: Date] = [:]
        for run in nativeSubagentRunsByID.values where run.mode == .parallel {
            for child in run.children ?? [] {
                guard let executionRunID = child.executionRunID else { continue }
                let existing = output[executionRunID]
                if existing == nil || child.updatedAt > existing! {
                    output[executionRunID] = child.updatedAt
                }
            }
        }
        return output
    }

    /// The children that actually render as rows, given the visibility
    /// settings — mirrors the gating inside `childView`. The AppKit
    /// block-row transcript uses this so a hidden child produces no row.
    static func visibleChildren(
        of thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> [PiAgentThreadChild] {
        let filtered = thread.children.filter { child in
            switch child {
            case .thinking: return visibility.showThinking
            case .error(let entry): return entry.isModelError || visibility.showErrors
            case .status(let entry):
                return shouldShowStatusEntry(entry, visibility: visibility, nativeSubagentRunsByID: nativeSubagentRunsByID)
            case .toolGroup(let group):
                // A tool group whose every section is hidden must NOT stay in the
                // list: it would still emit a 0-height row that the inter-row inset
                // pass pads on both sides, leaving a phantom gap between turns.
                return toolGroupHasVisibleContent(group, visibility: visibility)
            case .steering, .assistant, .retry: return true
            }
        }
        return coalesceAdjacentToolGroups(filtered)
    }

    /// Re-merge tool groups that became adjacent only because the child between them
    /// was filtered out (a hidden thinking block, a hidden status, a read-only tool
    /// group with its sections off, …). The build-time splitter in
    /// `chronologicalChildren` flushes a group on every thinking/status/etc. arrival
    /// without knowing visibility, so a hidden separator would otherwise leave two
    /// "Changes" diff cards split by an invisible gap. A *visible* separator keeps the
    /// groups non-adjacent here, so they correctly stay split.
    ///
    /// A merged run rebuilds its activities via `PiAgentTranscriptActivity.make` over the
    /// combined entries (NOT a plain `activities` concat): two adjacent groups can each
    /// hold an `edit` activity, and only `make` re-folds them into one `edit ×N` so the
    /// tool-call chips and web cards match what an unsplit burst shows. Cost stays off the
    /// common path — `make` runs once per *merged* run (2+ groups), and a lone group is
    /// passed through untouched. For code tools `make` is just string/dictionary grouping
    /// (web link/detail parsing is skipped for non-web tools).
    private static func coalesceAdjacentToolGroups(
        _ children: [PiAgentThreadChild]
    ) -> [PiAgentThreadChild] {
        var result: [PiAgentThreadChild] = []
        var run: [PiAgentThreadToolGroup] = []

        func flushRun() {
            guard let first = run.first else { return }
            if run.count == 1 {
                result.append(.toolGroup(first))                   // untouched, zero cost
            } else {
                let entries = run.flatMap(\.entries)
                result.append(.toolGroup(PiAgentThreadToolGroup(
                    id: first.id,                                  // stable descriptor id
                    entries: entries,
                    activities: PiAgentTranscriptActivity.make(from: entries)
                )))
            }
            run = []
        }

        for child in children {
            if case .toolGroup(let group) = child {
                run.append(group)
            } else {
                flushRun()
                result.append(child)
            }
        }
        flushRun()
        return result
    }

    /// Whether a tool group would render at least one section under the current
    /// visibility. Cheap (no diff parsing): a group shows the diff card only when
    /// it has edit/write activities, the tool list when it has any non-web tool,
    /// and the web card when it has web activities.
    static func toolGroupHasVisibleContent(
        _ group: PiAgentThreadToolGroup,
        visibility: PiAgentTranscriptVisibilitySettings
    ) -> Bool {
        var hasTool = false, hasWeb = false, hasEditable = false
        for activity in group.activities {
            if activity.isWebActivity {
                hasWeb = true
            } else {
                hasTool = true
                let name = activity.name.lowercased()
                if name == "edit" || name == "write" { hasEditable = true }
            }
        }
        return (visibility.showToolCalls && hasTool)
            || (visibility.showWebActivity && hasWeb)
            || (visibility.showDiffs && hasEditable)
    }

    private static func shouldShowStatusEntry(
        _ entry: PiAgentTranscriptEntry,
        visibility: PiAgentTranscriptVisibilitySettings,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> Bool {
        if entry.title == "System Prompt Captured" {
            return visibility.showFinalSystemPrompt
        }
        if entry.agentMemoryEvent != nil {
            return visibility.showMemoryCards
        }
        return !shouldHideNativeSubagentStatus(entry, nativeSubagentRunsByID: nativeSubagentRunsByID)
    }

}

extension PiAgentTranscriptEntry {
    var agentMemoryEvent: AgentMemoryTranscriptEvent? {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let event = try? transcriptJSONDecoder.decode(AgentMemoryTranscriptEvent.self, from: data),
              event.type == AgentMemoryTranscriptEvent.rawType else {
            return nil
        }
        return event
    }
}
