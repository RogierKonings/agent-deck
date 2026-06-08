import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
// MARK: - Transcript debug gallery

struct TranscriptDebugScreen: View {
    private let sessionID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript")
                    .font(.title2.weight(.semibold))
                Text("Production Pi Agent transcript components with representative content")
                    .font(AppTheme.Font.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            PiAgentAppKitTranscriptView(
                items: items,
                sessionID: sessionID,
                renderRevision: 0,
                streamingRevision: 0,
                autoScrollTurnRevision: 0,
                bottomScrollRequest: 0,
                onPinnedToBottomChange: { _ in },
                onBenchAdvanceSession: {},
                benchSessionCount: { 0 }
            )
            .padding(.horizontal, 18)
            .transcriptEdgeFade()
        }
        .background(AppTheme.windowBackground)
    }

    private var items: [PiAgentAppKitTranscriptItem] {
        let question = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .user,
            title: "You",
            text: """
            Please inspect the transcript UI and update the shared components.

            - Keep the production spacing
            - Render **Markdown**, `inline code`, and links
            """
        )
        let thinking = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .thinking,
            title: "Thinking",
            text: "I’ll trace the production rendering path first, then make the smallest shared change."
        )
        let assistant = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .assistant,
            title: "Coding Agent",
            text: """
            I found the shared renderer. This reply demonstrates:

            1. Normal body text
            2. **Bold** and *italic* text
            3. `inline code`

            ```swift
            struct ExampleView: View {
                var body: some View { Text("Shared component") }
            }
            ```
            """
        )
        let status = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .status,
            title: "Session Ready",
            text: "Pi is connected and ready."
        )
        let toolError = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .error,
            title: "Tool: shell",
            text: "Command exited with status 1."
        )
        let modelError = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .error,
            title: "Model Error",
            text: "The provider rejected the request. Check the selected model and credentials."
        )
        return [
            spacer("debug-top", height: 18),
            native("debug-shortcuts", spec: .of(PiAgentNativeShortcutsStripView.self) { view, width in
                view.configure(width: width)
            }),
            native("debug-fork", spec: .of(PiAgentNativeForkOriginCardView.self) { view, width in
                view.configure(payload: NativeForkOriginPayload.make(
                    parentTitle: "Refine transcript UI",
                    parentSessionID: UUID(),
                    transcriptSnapshot: "User: Update the transcript.\nAssistant: I’ll inspect the shared components.",
                    onSelectParent: { _ in }
                ), width: width)
            }),
            bubble("debug-question", payload: NativeBubblePayload(
                role: .user,
                headerTitle: "You",
                iconSymbol: "person.crop.circle",
                markdownSource: question.text,
                bodyPrefix: nil,
                copyText: question.text,
                copySide: .leading,
                isThreadChild: false,
                isUserHugged: true,
                fork: ForkModel(onForkSession: {}, agentOptions: [])
            )),
            native("debug-chip-question", spec: .of(PiAgentNativeQuestionView.self) { view, width in
                let entry = PiAgentTranscriptEntry(
                    sessionID: sessionID,
                    role: .user,
                    title: "You",
                    text: "/review-my-changes @agent-deck/PiAgentViews.swift\nCheck the transcript gallery."
                )
                view.configure(
                    payload: NativeQuestionPayload.make(
                        entry: entry,
                        skills: [],
                        commandSlashNames: ["review-my-changes"],
                        fork: ForkModel(onForkSession: {}, agentOptions: [])
                    ),
                    width: width
                )
            }),
            bubble("debug-steering", payload: NativeBubblePayload(
                role: .user,
                headerTitle: "Steering",
                iconSymbol: "arrowshape.turn.up.forward.circle",
                markdownSource: "Also include every tool, memory, and agent card.",
                bodyPrefix: nil,
                copyText: "Also include every tool, memory, and agent card.",
                copySide: .trailing,
                isThreadChild: true
            )),
            bubble("debug-thinking", payload: NativeBubblePayload(
                role: .thinking,
                headerTitle: thinking.title,
                iconSymbol: "brain.head.profile",
                markdownSource: thinking.text,
                bodyPrefix: "Reasoning",
                copyText: thinking.text,
                copySide: .trailing,
                isThreadChild: true
            )),
            bubble("debug-assistant", payload: NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: assistant.text,
                bodyPrefix: nil,
                copyText: assistant.text,
                copySide: .trailing,
                isThreadChild: true
            )),
            native("debug-tools", spec: .of(PiAgentNativeToolGroupView.self) { view, width in
                view.configure(model: toolGroupModel, width: width)
            }),
            native("debug-status", spec: .of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: NativeStatusPayload.make(for: status), width: width)
            }),
            native("debug-prompt-status", spec: .of(PiAgentNativeStatusRowView.self) { view, width in
                let entry = PiAgentTranscriptEntry(
                    sessionID: sessionID,
                    role: .status,
                    title: "System Prompt Captured",
                    text: "The final runtime system prompt was captured for inspection.",
                    rawJSON: #"{"systemPrompt":"You are a coding agent. Read the project instructions before editing."}"#
                )
                view.configure(payload: NativeStatusPayload.make(for: entry), width: width)
            }),
            native("debug-compaction", spec: .of(PiAgentNativeStatusDividerView.self) { view, width in
                let entry = PiAgentTranscriptEntry(
                    sessionID: sessionID,
                    role: .status,
                    title: "Compaction",
                    text: "Context compacted."
                )
                view.configure(payload: NativeDividerPayload.make(for: entry), width: width)
            }),
            native("debug-git-divider", spec: .of(PiAgentNativeStatusDividerView.self) { view, width in
                let entry = PiAgentTranscriptEntry(
                    sessionID: sessionID,
                    role: .status,
                    title: "Commit and Push",
                    text: "Committed and pushed transcript gallery changes."
                )
                view.configure(payload: NativeDividerPayload.make(for: entry), width: width)
            }),
            native("debug-retry", spec: .of(PiAgentNativeRetryRowView.self) { view, width in
                view.configure(payload: NativeRetryPayload(
                    icon: "arrow.triangle.2.circlepath",
                    accent: AppTheme.ns(AppTheme.roleTool),
                    headline: "Retrying request…",
                    detail: "The model provider is temporarily unavailable.",
                    resetLine: "Attempt 2 of 5",
                    timeText: Date().formatted(date: .omitted, time: .shortened),
                    copyText: nil
                ), width: width)
            }),
            native("debug-tool-error", spec: .of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: NativeStatusPayload.make(for: toolError), width: width)
            }),
            native("debug-model-error", spec: .of(PiAgentNativeErrorRowView.self) { view, width in
                view.configure(payload: NativeErrorPayload.make(for: modelError), width: width)
            }),
            native("debug-single-agent", spec: .of(PiAgentNativeSubagentRunCardView.self) { view, width in
                view.configure(payload: singleAgentPayload, width: width)
            }),
            native("debug-parallel-agents", spec: .of(PiAgentNativeSubagentParallelCardView.self) { view, width in
                view.configure(payload: parallelAgentPayload, width: width)
            }),
            native("debug-summary", spec: .of(PiAgentNativeSubagentSummaryView.self) { view, width in
                view.configure(payload: NativeSubagentSummaryPayload(
                    title: "Parallel · 3 agents",
                    isRunning: true,
                    metrics: [
                        .init(text: "1/3 done", color: .systemGreen),
                        .init(text: "2 running", color: .systemOrange)
                    ],
                    agents: [
                        .init(icon: "checkmark", color: .systemGreen, name: "Explorer", meta: "4 tools · 8s", detail: "Mapped transcript components", detailIsMono: false),
                        .init(icon: "ellipsis", color: .systemCyan, name: "Coder", meta: "2 tools · 1.2k token", detail: "Updating shared renderer", detailIsMono: false),
                        .init(icon: "ellipsis", color: .systemCyan, name: "Reviewer", meta: "running", detail: "Checking visual consistency", detailIsMono: false)
                    ]
                ), width: width)
            }),
            native("debug-supervisor-freeform", spec: .of(PiAgentNativeSupervisorCardView.self) { view, width in
                view.configure(payload: NativeSupervisorPayload(
                    title: "Agent needs a decision",
                    message: "Should the transcript cards use compact or comfortable spacing?",
                    fields: [.init(id: "", label: nil, placeholder: "Response", isInfo: false, isRequired: true)],
                    isInterview: false,
                    onRespond: { _ in },
                    onCancel: {}
                ), width: width)
            }),
            native("debug-supervisor-interview", spec: .of(PiAgentNativeSupervisorCardView.self) { view, width in
                view.configure(payload: NativeSupervisorPayload(
                    title: "Agent interview",
                    message: "Please confirm the desired transcript treatment.",
                    fields: [
                        .init(id: "density", label: "Density", placeholder: "Compact or comfortable", isInfo: false, isRequired: true),
                        .init(id: "note", label: "Context", placeholder: "This response is sent to the running agent.", isInfo: true, isRequired: false)
                    ],
                    isInterview: true,
                    onRespond: { _ in },
                    onCancel: {}
                ), width: width)
            }),
            memoryItem(.recalled, summary: "Loaded two relevant project memories into this turn."),
            memoryItem(.stored, summary: "Stored a durable note about transcript component ownership."),
            memoryItem(.edited, summary: "Updated the existing transcript design preference."),
            memoryItem(.archived, summary: "Archived an obsolete transcript implementation note."),
            memoryItem(.stale, summary: "Marked a no-longer-accurate rendering note as stale."),
            memoryItem(.blocked, summary: "Blocked a memory write because it contained sensitive data."),
            native("debug-pre-compaction-archive", spec: .of(PiAgentNativeArchiveNoticeView.self) { view, width in
                view.configure(payload: .preCompaction(
                    hiddenCount: 42,
                    compactedAt: Date(),
                    isShowing: false,
                    onToggle: {}
                ), width: width)
            }),
            native("debug-recent-archive", spec: .of(PiAgentNativeArchiveNoticeView.self) { view, width in
                view.configure(payload: .recentWindow(hiddenCount: 120, limit: 200, onOpen: {}), width: width)
            }),
            native("debug-loading", spec: .of(PiAgentNativeStateCardView.self) { view, width in
                view.configure(payload: .loading(), width: width)
            }),
            native("debug-empty", spec: .of(PiAgentNativeStateCardView.self) { view, width in
                view.configure(payload: .empty(), width: width)
            }),
            spacer("debug-bottom", height: 18)
        ]
    }

    private var toolGroupModel: NativeToolGroupModel {
        NativeToolGroupModel(
            web: .init(
                title: "Web",
                callCount: "3 calls",
                hasErrors: false,
                rows: [
                    .init(id: UUID(), icon: "magnifyingglass", title: "Search", detail: "SwiftUI transcript UI patterns", isError: false, links: [
                        .init(title: "SwiftUI documentation", domain: "developer.apple.com"),
                        .init(title: "Human Interface Guidelines", domain: "developer.apple.com")
                    ]),
                    .init(id: UUID(), icon: "doc.text.magnifyingglass", title: "Read content", detail: "Transcript rendering guidance", isError: false, links: [])
                ],
                hiddenCount: 1
            ),
            calls: .init(items: [
                .init(icon: "terminal", name: "Shell", successCount: 3, errorCount: 1),
                .init(icon: "doc.text.magnifyingglass", name: "Read", successCount: 4, errorCount: 0),
                .init(icon: "pencil.and.outline", name: "Edit", successCount: 2, errorCount: 0),
                .init(icon: "pencil.and.outline", name: "Write", successCount: 1, errorCount: 0),
                .init(icon: "checklist", name: "Plan", successCount: 2, errorCount: 0),
                .init(icon: "wrench.and.screwdriver", name: "Custom Tool", successCount: 1, errorCount: 0)
            ]),
            diff: .init(fileCount: 2, rows: [
                .init(path: "agent-deck/PiAgentViews.swift", diff: """
                + struct TranscriptDebugScreen: View {
                +     var body: some View { transcriptGallery }
                + }
                """),
                .init(path: "agent-deck/SidebarModels.swift", diff: """
                - case debugDoctorEmpty
                + case debugTranscript
                """)
            ])
        )
    }

    private var singleAgentPayload: NativeAgentBlockPayload {
        NativeAgentBlockPayload(
            agentName: "Coder",
            statusText: "Running",
            statusColor: .systemBlue,
            isActive: true,
            avatarURL: nil,
            outcomePill: "Artifact",
            task: "Implement the complete transcript component gallery using production renderers.",
            metrics: [
                .init(icon: "timer", text: "42s"),
                .init(icon: "tugriksign.circle", text: "2.4k"),
                .init(icon: "wrench.and.screwdriver", text: "7"),
                .init(icon: "cpu", text: "claude-sonnet")
            ],
            actions: [
                .init(symbol: "info.circle", help: "Run details") { _ in },
                .init(symbol: "text.bubble", help: "Open transcript") { _ in },
                .init(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in }
            ]
        )
    }

    private var parallelAgentPayload: NativeSubagentParallelPayload {
        NativeSubagentParallelPayload(
            title: "Parallel agents",
            count: 3,
            statusText: "Running",
            statusColor: .systemBlue,
            children: [
                singleAgentPayload,
                NativeAgentBlockPayload(
                    agentName: "Explorer",
                    statusText: "Completed",
                    statusColor: .systemGreen,
                    isActive: false,
                    avatarURL: nil,
                    outcomePill: "Report",
                    task: "Inventory every production transcript row.",
                    metrics: [.init(icon: "timer", text: "18s"), .init(icon: "wrench.and.screwdriver", text: "5")],
                    actions: [.init(symbol: "text.bubble", help: "Open transcript") { _ in }]
                ),
                NativeAgentBlockPayload(
                    agentName: "Reviewer",
                    statusText: "Blocked",
                    statusColor: .systemOrange,
                    isActive: false,
                    avatarURL: nil,
                    outcomePill: "Review",
                    task: "Review visual coverage and identify missing states.",
                    metrics: [.init(icon: "timer", text: "11s")],
                    actions: [.init(symbol: "text.bubble", help: "Open transcript") { _ in }]
                )
            ]
        )
    }

    private func memoryItem(_ kind: AgentMemoryEventKind, summary: String) -> PiAgentAppKitTranscriptItem {
        let event = AgentMemoryTranscriptEvent(
            type: AgentMemoryTranscriptEvent.rawType,
            event: kind,
            memoryIDs: kind == .blocked ? [] : ["architecture", "testing"],
            memoryTitles: kind == .blocked ? nil : ["Transcript architecture", "Validation commands"],
            scope: .project,
            title: kind.displayTitle,
            summary: summary
        )
        return native("debug-memory-\(kind.rawValue)", spec: .of(PiAgentNativeMemoryCardView.self) { view, width in
            view.configure(payload: NativeMemoryCardPayload.make(event: event), width: width)
        })
    }

    private func bubble(_ id: String, payload: NativeBubblePayload) -> PiAgentAppKitTranscriptItem {
        PiAgentAppKitTranscriptItem(
            id: id,
            kind: .bubble(payload),
            bottomInset: AppTheme.Chat.rowSpacing,
            estimatedHeight: { _ in 120 }
        )
    }

    private func native(_ id: String, spec: NativeRowSpec) -> PiAgentAppKitTranscriptItem {
        PiAgentAppKitTranscriptItem(
            id: id,
            kind: .native(spec),
            bottomInset: AppTheme.Chat.rowSpacing,
            estimatedHeight: { _ in 90 }
        )
    }

    private func spacer(_ id: String, height: CGFloat) -> PiAgentAppKitTranscriptItem {
        PiAgentAppKitTranscriptItem(
            id: id,
            kind: .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = height }),
            estimatedHeight: { _ in height }
        )
    }
}
#endif
