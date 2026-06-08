import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentCreateSessionFromComposerButton: View {
    let projects: [DiscoveredProject]
    let action: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isProjectPickerPresented = false

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: projects.isEmpty ? "Start new Pi Agent session" : "Choose a project for the new Pi Agent session",
            action: buttonAction
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(projects.isEmpty ? "Start new Pi Agent session" : "Choose project for new Pi Agent session")
        .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
            PiAgentComposerProjectPickerPopover(
                projects: projects,
                onSelectProject: { project in
                    isProjectPickerPresented = false
                    onSelectProject(project)
                }
            )
        }
    }

    private func buttonAction() {
        if projects.isEmpty {
            action()
        } else {
            isProjectPickerPresented.toggle()
        }
    }
}

struct PiAgentComposerProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let onSelectProject: (DiscoveredProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session")
                    .font(AppTheme.Font.headline)
                Text("Choose a project for Pi Agent.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(projects) { project in
                        Button {
                            onSelectProject(project)
                        } label: {
                            HStack(spacing: 10) {
                                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 24, assetName: project.projectType.assetName)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.repositoryDisplayName)
                                        .font(AppTheme.Font.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(project.path)
                                        .font(AppTheme.Font.caption2)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 340)
        .appGlassPanel(cornerRadius: AppTheme.Chat.panelCornerRadius)
    }
}

struct PiAgentSendButton: View {
    let isRunning: Bool
    let canSend: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button(action: isRunning ? stopAction : sendAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(AppTheme.Font.body.weight(.bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
        }
        .appPrimaryCircleButton(tint: tintColor, controlSize: .large)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop Pi Agent" : "Send message")
        .accessibilityLabel(isRunning ? "Stop Pi Agent" : "Send message")
        .background {
            Button("Stop Pi Agent", action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!isRunning)
                .hidden()
        }
        .animation(.snappy(duration: 0.22), value: isRunning)
    }

    private var tintColor: Color {
        if isRunning { return Color.red }
        if canSend { return AppTheme.brandAccent }
        return AppTheme.mutedText.opacity(0.35)
    }
}

struct PiAgentModelSelection {
    let provider: String
    let modelID: String
}

struct PiAgentComposerFooterBar: View {
    let session: PiAgentSessionRecord
    var viewModel: AppViewModel
    let transcript: [PiAgentTranscriptEntry]
    let supportedThinkingLevels: [String]

    var body: some View {
        HStack(spacing: 10) {
            PiAgentContextUsageMeter(
                session: session,
                transcript: transcript,
                fallbackModels: viewModel.enabledAvailableModels,
                showsSmartZoneHint: viewModel.appSettings.showContextSmartZoneHint,
                onCompact: { viewModel.compactSelectedPiAgentSession() }
            )
            PiAgentModelPicker(
                session: session,
                fallbackModels: viewModel.enabledAvailableModels,
                disabledModelIdentifiers: viewModel.appSettings.disabledModelIdentifiers,
                defaultModel: viewModel.defaultPiAgentModel(),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onRefresh: { viewModel.refreshPiAgentControlsForSelectedSession() },
                onCycle: { viewModel.cyclePiAgentModelForSelectedSession() },
                onSelect: { selection in
                    if let selection {
                        viewModel.setPiAgentModelForSelectedSession(provider: selection.provider, modelID: selection.modelID)
                    } else {
                        viewModel.setPiAgentModelForSelectedSession(provider: nil, modelID: nil)
                    }
                }
            )
            PiAgentThinkingPicker(
                level: session.thinkingLevel,
                supportedLevels: supportedThinkingLevels,
                defaultLevel: viewModel.defaultPiAgentThinkingLevel(for: supportedThinkingLevels),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onCycle: { viewModel.cyclePiAgentThinkingLevelForSelectedSession() },
                onSelect: { viewModel.setPiAgentThinkingLevelForSelectedSession($0) }
            )
        }
    }

}

struct PiAgentContextUsageMeter: View {
    let session: PiAgentSessionRecord
    let transcript: [PiAgentTranscriptEntry]
    let fallbackModels: [AvailableModel]
    let showsSmartZoneHint: Bool
    let onCompact: () -> Void
    @State private var isConfirmingCompaction = false
    @State private var isBreakdownPresented = false

    var body: some View {
        if session.isCompacting {
            HStack(spacing: 7) {
                AppSpinner()
                    .controlSize(.small)
                Text("Compacting context")
                    .font(AppTheme.Font.caption.weight(.semibold))
                if let tokens = session.contextTokens {
                    Text("\(compact(tokens)) tokens")
                        .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .fixedSize(horizontal: true, vertical: false)
            .help("Pi is compacting this conversation. Input is disabled until compaction finishes.")
        } else if let percent = session.contextPercent, let tokens = session.contextTokens, let window = session.contextWindow {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 7) {
                        Text("Context")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                        PiAgentSmartZoneContextBar(
                            percent: percent,
                            showsSmartZoneHint: showsSmartZoneHint,
                            width: 92,
                            height: 10
                        )
                        Text("\(Int(percent))%")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.bold))
                            .lineLimit(1)
                        Text("\(compact(tokens))/\(compact(window))")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                        Image(systemName: "info.circle")
                            .font(AppTheme.Font.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .accessibilityLabel("Show context usage details")
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .appGlassCapsule()
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Capsule(style: .continuous))
                    .onTapGesture {
                        isBreakdownPresented.toggle()
                    }
                    .popover(isPresented: $isBreakdownPresented, arrowEdge: .bottom) {
                        PiAgentContextBreakdownPopover(
                            session: session,
                            transcript: transcript,
                            fallbackModels: fallbackModels,
                            showsSmartZoneHint: showsSmartZoneHint
                        )
                    }
                    .help(showsSmartZoneHint ? "Show context usage details. Smart zone hint is enabled in Settings." : "Show context usage details")

                    Button {
                        isConfirmingCompaction = true
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(width: 24, height: 24)
                            .appGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("Compact context")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .alert("Compact context?", isPresented: $isConfirmingCompaction) {
                Button("Cancel", role: .cancel) {}
                Button("Compact") { onCompact() }
            } message: {
                Text("Pi will summarize older conversation history to free context. This keeps the session usable for longer prompts.")
            }
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

struct PiAgentSmartZoneContextBar: View {
    let percent: Double
    let showsSmartZoneHint: Bool
    let width: CGFloat
    let height: CGFloat

    private var clampedPercent: Double {
        min(max(percent, 0), 100)
    }

    private var warningThreshold: Double {
        showsSmartZoneHint ? 40 : 70
    }

    private var usageFill: AnyShapeStyle {
        if clampedPercent >= 90 {
            return AnyShapeStyle(Color.red.gradient)
        }
        if clampedPercent >= warningThreshold {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(AppTheme.brandAccent.gradient)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppTheme.contentFill.opacity(0.75))

            Capsule(style: .continuous)
                .fill(usageFill)
                .frame(width: width * clampedPercent / 100)

            if showsSmartZoneHint {
                PiAgentSmartZoneDottedMarker()
                    .stroke(Color.primary.opacity(0.72), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                    .frame(width: 1.5, height: height)
                    .position(x: width * 0.4, y: height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityLabel(showsSmartZoneHint ? "Context usage with smart zone marker" : "Context usage")
        .accessibilityValue("\(Int(clampedPercent)) percent")
    }
}

struct PiAgentSmartZoneDottedMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct PiAgentContextBreakdownPopover: View {
    let session: PiAgentSessionRecord
    let transcript: [PiAgentTranscriptEntry]
    let fallbackModels: [AvailableModel]
    let showsSmartZoneHint: Bool

    private var usedPercent: Double {
        min(max(session.contextPercent ?? 0, 0), 100)
    }

    private var estimate: PiAgentContextBreakdownEstimate {
        PiAgentContextEstimateBuilder.build(
            session: session,
            transcript: transcript,
            fallbackModels: fallbackModels
        )
    }

    private var promptComposition: PiAgentPromptCompositionEstimate? {
        PiAgentContextEstimateBuilder.buildPromptComposition(systemPrompt: session.finalSystemPrompt)
    }

    private var visibleRows: [PiAgentContextVisualRow] {
        if session.contextBreakdown.isEmpty == false {
            return session.contextBreakdown.map {
                PiAgentContextVisualRow(
                    key: $0.key,
                    title: $0.title,
                    tokens: $0.tokens,
                    percent: $0.percent,
                    tint: tint(for: $0.key)
                )
            }
        }
        return estimate.rows.map {
            PiAgentContextVisualRow(
                key: $0.key,
                title: $0.title,
                tokens: $0.tokens,
                percent: $0.percent,
                tint: tint(for: $0.key)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Context usage")
                    .font(AppTheme.Font.headline.weight(.semibold))
                if let tokens = session.contextTokens, let window = session.contextWindow {
                    HStack(spacing: 4) {
                        Image(systemName: "tugriksign.circle")
                            .font(AppTheme.Font.caption.weight(.semibold))
                        Text("\(format(tokens)) of \(format(window)) tokens · \(formatPercent(usedPercent))")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.mutedText)
                } else {
                    Text("Exact usage will appear after Pi reports session stats.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            PiAgentContextDotGrid(rows: visibleRows)

            VStack(alignment: .leading, spacing: 8) {
                if session.contextBreakdown.isEmpty == false {
                    Text("Exact from Pi RPC")
                        .font(AppTheme.Font.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                    ForEach(session.contextBreakdown) { item in
                        PiAgentContextBreakdownRow(
                            title: item.title,
                            tokens: item.tokens,
                            percent: item.percent,
                            detail: item.detail,
                            tint: tint(for: item.key)
                        )
                    }
                } else {
                    Text("Estimated")
                        .font(AppTheme.Font.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                    if estimate.rows.isEmpty {
                        PiAgentContextBreakdownRow(
                            title: "Used context",
                            tokens: session.contextTokens,
                            percent: session.contextPercent,
                            detail: nil,
                            tint: usedPercent >= 90 ? .red : (usedPercent >= 70 ? .orange : AppTheme.brandAccent)
                        )
                    } else {
                        ForEach(estimate.rows) { row in
                            PiAgentContextBreakdownRow(
                                title: row.title,
                                tokens: row.tokens,
                                percent: row.percent,
                                detail: row.detail,
                                tint: tint(for: row.key)
                            )
                        }
                    }
                    Text(estimate.note)
                        .font(AppTheme.Font.caption.italic())
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let promptComposition, promptComposition.rows.isEmpty == false {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("Prompt composition")
                            .font(AppTheme.Font.caption.weight(.bold))
                        Spacer()
                        tokenLabel(promptComposition.totalTokens, prefix: "~")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Text("Estimated from the captured Pi runtime system prompt.")
                        .font(AppTheme.Font.caption2.italic())
                        .foregroundStyle(AppTheme.mutedText)
                    ForEach(promptComposition.rows) { row in
                        PiAgentPromptCompositionRowView(
                            title: row.title,
                            tokens: row.tokens,
                            percent: row.percent,
                            tint: tint(for: row.key)
                        )
                    }
                }
            }

            if let inputTokens = session.inputTokens,
               let outputTokens = session.outputTokens,
               let toolCalls = session.toolCalls {
                Divider()
                HStack(spacing: 12) {
                    PiAgentContextStat(label: "Input", value: format(inputTokens), icon: "tugriksign.circle")
                    PiAgentContextStat(label: "Output", value: format(outputTokens), icon: "tugriksign.circle")
                    PiAgentContextStat(label: "Tools", value: "\(toolCalls)", icon: "wrench.and.screwdriver")
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func tint(for key: String) -> Color {
        switch key {
        case "systemPrompt", "system_prompt":
            return AppTheme.assistantAccent
        case "systemTools", "system_tools", "toolCalls", "tool_calls", "toolResults", "tool_results", "promptTools":
            return .blue
        case "promptSkills":
            return AppTheme.assistantAccent
        case "promptProjectContext":
            return .orange
        case "promptCore", "messages", "estimatedMessages", "estimatedInputTokens":
            return AppTheme.brandAccent
        case "estimatedOutputTokens":
            return .green
        case "estimatedCachedPromptTools", "estimatedCacheTokens":
            return .blue
        case "estimatedOtherUsedContext":
            return .orange
        case "freeSpace", "free_space", "estimatedFreeSpace":
            return .secondary
        case "autocompactBuffer", "autocompact_buffer", "estimatedOutputBuffer":
            return .gray
        default:
            return AppTheme.brandAccent
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func tokenLabel(_ value: Int, prefix: String = "") -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tugriksign.circle")
                .font(AppTheme.Font.caption2.weight(.semibold))
            Text("\(prefix)\(format(value))")
                .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
        }
    }
}

struct PiAgentContextBreakdownRow: View {
    let title: String
    let tokens: Int?
    let percent: Double?
    let detail: String?
    let tint: Color

    private var clampedPercent: Double {
        min(max(percent ?? 0, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                summaryView
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                let width = AppTheme.safeFrameDimension(proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: width * clampedPercent / 100)
                }
            }
            .frame(height: 6)
            if let detail, detail.isEmpty == false {
                Text(detail)
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        switch (tokens, percent) {
        case let (tokens?, percent?):
            HStack(spacing: 4) {
                tokenValue(tokens)
                Text("· \(formatPercent(percent))")
                    .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
            }
        case let (tokens?, nil):
            tokenValue(tokens)
        case let (nil, percent?):
            Text(formatPercent(percent))
                .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
        default:
            Text("Unavailable")
                .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func tokenValue(_ value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tugriksign.circle")
                .font(AppTheme.Font.caption2.weight(.semibold))
            Text(format(value))
                .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 100))
    }
}

struct PiAgentContextVisualRow {
    let key: String
    let title: String
    let tokens: Int?
    let percent: Double?
    let tint: Color
}

struct PiAgentContextDotGrid: View {
    let rows: [PiAgentContextVisualRow]

    private let columns = Array(repeating: GridItem(.fixed(13), spacing: 7), count: 10)
    private let totalCells = 80

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                PiAgentContextDotCellView(cell: cell)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var cells: [PiAgentContextDotCell] {
        let positiveRows = rows.filter { ($0.percent ?? 0) > 0 }
        guard positiveRows.isEmpty == false else {
            return Array(repeating: .empty, count: totalCells)
        }

        var output: [PiAgentContextDotCell] = []
        var remaining = totalCells
        for (index, row) in positiveRows.enumerated() {
            let percent = min(max(row.percent ?? 0, 0), 100)
            let requested = max(Int(((percent / 100) * Double(totalCells)).rounded()), percent > 0 ? 1 : 0)
            let count = index == positiveRows.count - 1 ? min(remaining, max(requested, 0)) : min(remaining, requested)
            guard count > 0 else { continue }
            output.append(contentsOf: Array(repeating: dotCell(for: row), count: count))
            remaining -= count
            if remaining <= 0 { break }
        }

        if output.count < totalCells {
            output.append(contentsOf: Array(repeating: .empty, count: totalCells - output.count))
        }
        return Array(output.prefix(totalCells))
    }

    private func dotCell(for row: PiAgentContextVisualRow) -> PiAgentContextDotCell {
        if row.key.localizedCaseInsensitiveContains("buffer") {
            return .hollow(row.tint)
        }
        if row.key.localizedCaseInsensitiveContains("free") {
            return .dim
        }
        return .filled(row.tint)
    }
}

struct PiAgentContextDotCell {
    enum Style {
        case filled
        case hollow
        case dim
        case empty
    }

    var style: Style
    var tint: Color

    static func filled(_ tint: Color) -> PiAgentContextDotCell { .init(style: .filled, tint: tint) }
    static func hollow(_ tint: Color) -> PiAgentContextDotCell { .init(style: .hollow, tint: tint) }
    static let dim = PiAgentContextDotCell(style: .dim, tint: AppTheme.mutedText)
    static let empty = PiAgentContextDotCell(style: .empty, tint: AppTheme.mutedText)
}

struct PiAgentContextDotCellView: View {
    let cell: PiAgentContextDotCell

    var body: some View {
        ZStack {
            switch cell.style {
            case .filled:
                Circle()
                    .fill(cell.tint.opacity(0.85))
                    .frame(width: 9, height: 9)
            case .hollow:
                Circle()
                    .stroke(cell.tint.opacity(0.82), lineWidth: 1.3)
                    .frame(width: 10, height: 10)
            case .dim:
                Circle()
                    .fill(AppTheme.mutedText.opacity(0.45))
                    .frame(width: 4, height: 4)
            case .empty:
                Circle()
                    .fill(AppTheme.mutedText.opacity(0.18))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 13, height: 13)
    }
}

struct PiAgentPromptCompositionRowView: View {
    let title: String
    let tokens: Int
    let percent: Double
    let tint: Color

    private var clampedPercent: Double {
        min(max(percent, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: "tugriksign.circle")
                            .font(AppTheme.Font.caption2.weight(.semibold))
                        Text(format(tokens))
                            .font(AppTheme.Font.caption2.monospacedDigit().weight(.semibold))
                    }
                    Text("· \(formatPercent(percent))")
                        .font(AppTheme.Font.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(AppTheme.mutedText)
            }
            GeometryReader { proxy in
                let width = AppTheme.safeFrameDimension(proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: width * clampedPercent / 100)
                }
            }
            .frame(height: 4)
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 100))
    }
}

struct PiAgentContextStat: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(AppTheme.Font.caption2.weight(.semibold))
                Text(value)
                    .font(AppTheme.Font.caption.monospacedDigit().weight(.bold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PiAgentModelStatus: View {
    let session: PiAgentSessionRecord

    var body: some View {
        HStack(spacing: 6) {
            modelIcon
            Text(modelLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(AppTheme.Font.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .appGlassCapsule()
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelLabel: String {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           let model = session.modelOverrideID ?? session.model {
            return "\(provider)/\(model)"
        }
        return "Pi default model"
    }
}

struct PiAgentThinkingStatus: View {
    let level: String?

    var body: some View {
        Label("Thinking: \(displayLevel)", systemImage: "brain.head.profile")
            .font(AppTheme.Font.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .appGlassCapsule()
    }

    private var displayLevel: String {
        guard let level, !level.isEmpty else { return "default" }
        return (level == "none" ? "off" : level).capitalized
    }
}

struct PiAgentShortcutChip: View {
    let symbol: String
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(key)
                .font(AppTheme.Font.caption2.monospaced().weight(.bold))
            Text(label)
                .fontWidth(.condensed)
        }
        .font(AppTheme.Font.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .appGlassCapsule()
    }
}

struct PiAgentRuntimeFooter: View {
    let session: PiAgentSessionRecord
    let showsSubagentsToggle: Bool
    let subagentsToggleEnabled: Bool
    let memoryToggleEnabled: Bool
    let memoryEnabled: Bool
    let openAIFastStatus: Bool?
    let onToggleMemory: () -> Void
    let onToggleSubagents: () -> Void
    let onToggleOpenAIFast: (() -> Void)?
    let onSetAsDefault: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            if let total = session.totalTokens {
                metric("\(compact(total)) tokens", icon: "tugriksign.circle")
            }
            if let cost = session.cost {
                metric(String(format: "$%.2f", cost), icon: "dollarsign.circle")
            }
            if memoryToggleEnabled {
                metricButton(
                    "memory: \(memoryEnabled ? "on" : "off")",
                    icon: SidebarItem.memory.systemImage,
                    action: onToggleMemory
                )
                .help("Draft only. Parent-session memory recall is decided when Pi starts.")
            } else {
                metric("memory: \(memoryEnabled ? "on" : "off")", icon: SidebarItem.memory.systemImage)
                    .help("Parent-session memory recall is fixed when Pi starts. Change the global memory setting in Settings for future sessions.")
            }
            if showsSubagentsToggle {
                if subagentsToggleEnabled {
                    metricButton(
                        "agents: \(session.subagentsEnabled ? "on" : "off")",
                        icon: "paperplane",
                        action: onToggleSubagents
                    )
                    .help("Draft only. This sets the current draft and the default for new sessions.")
                } else {
                    metric("agents: \(session.subagentsEnabled ? "on" : "off")", icon: "paperplane")
                        .help("Deck agents can only be changed before the first message starts Pi.")
                }
            }
            if let openAIFastStatus {
                metricButton(
                    "fast: \(openAIFastStatus ? "on" : "off")",
                    icon: openAIFastStatus ? "bolt.fill" : "bolt.slash",
                    action: { onToggleOpenAIFast?() }
                )
                .disabled(onToggleOpenAIFast == nil)
            }
            if let onSetAsDefault {
                metricButton(
                    "Set as default",
                    icon: "pin",
                    action: onSetAsDefault
                )
            }
        }
        .font(AppTheme.Font.caption)
        .foregroundStyle(AppTheme.mutedText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.18), value: memoryEnabled)
        .animation(.snappy(duration: 0.18), value: session.subagentsEnabled)
        .animation(.snappy(duration: 0.18), value: openAIFastStatus)
    }

    private func metric(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .contentTransition(.opacity)
            Text(text)
                .contentTransition(.opacity)
        }
        .lineLimit(1)
    }

    private func metricButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            metric(text, icon: icon)
                .foregroundStyle(AppTheme.brandAccent)
        }
        .buttonStyle(.plain)
        .help("Toggle \(text.split(separator: ":").first.map(String.init) ?? text)")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

struct PiAgentModelPicker: View {
    let session: PiAgentSessionRecord
    let fallbackModels: [AvailableModel]
    let disabledModelIdentifiers: Set<String>
    let defaultModel: AvailableModel?
    let isRunning: Bool
    let onRefresh: () -> Void
    let onCycle: () -> Void
    let onSelect: (PiAgentModelSelection?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                modelIcon
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .appGlassCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Model", systemImage: "cpu")
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                }

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedModelOptions, id: \.provider) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    ProviderLabel(provider: group.provider, logoSize: 14, spacing: 5)
                                        .font(AppTheme.Font.caption.weight(.bold))
                                        .fontWidth(.expanded)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 2)

                                VStack(spacing: 3) {
                                    ForEach(group.models) { model in
                                        Button {
                                            onSelect(.init(provider: model.provider, modelID: model.id))
                                            isPresented = false
                                        } label: {
                                            modelRow(
                                                title: model.id,
                                                subtitle: modelMetadataSubtitle(model),
                                                isSelected: model.provider == resolvedProvider && model.id == resolvedModelID
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 340)
            }
            .padding(12)
            .frame(width: 360)
        }
        .help(isRunning ? "Change this Pi session's model" : "Choose a model for this session before launch")
    }

    private func modelRow(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous).fill(isSelected ? AppTheme.selectionFill : Color.clear))
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = resolvedProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelOptions: [PiAgentModelOption] {
        return fallbackModels.map { model in
            PiAgentModelOption(
                provider: model.provider,
                id: model.model,
                name: nil,
                contextWindow: PiAgentContextEstimateBuilder.parseTokenCount(model.contextWindow),
                maxOutput: PiAgentContextEstimateBuilder.parseTokenCount(model.maxOutput),
                supportsThinking: model.supportsThinking,
                supportedThinkingLevels: model.supportedThinkingLevels,
                supportsImages: model.supportsImages
            )
        }
    }

    private var groupedModelOptions: [(provider: String, models: [PiAgentModelOption])] {
        Dictionary(grouping: modelOptions, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func modelMetadataSubtitle(_ model: PiAgentModelOption) -> String {
        var badges: [String] = []
        if let contextWindow = model.contextWindow { badges.append("ctx \(compactModelNumber(contextWindow))") }
        if let maxOutput = model.maxOutput { badges.append("out \(compactModelNumber(maxOutput))") }
        badges.append(model.supportsThinking == false ? "no thinking" : "thinking")
        if model.supportsImages == true { badges.append("images") }
        return badges.joined(separator: " · ")
    }

    private func compactModelNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }

    private var isUsingPiDefault: Bool { session.modelOverrideProvider == nil && session.modelOverrideID == nil }
    private var effectiveProvider: String? { session.modelOverrideProvider ?? session.modelProvider }
    private var effectiveModelID: String? { session.modelOverrideID ?? session.model }
    private var resolvedProvider: String? { effectiveProvider ?? defaultModel?.provider }
    private var resolvedModelID: String? { effectiveModelID ?? defaultModel?.model }

    private var modelLabel: String {
        if let provider = resolvedProvider, let model = resolvedModelID {
            return "\(provider)/\(model)"
        }
        return "Model"
    }
}

struct PiAgentThinkingPicker: View {
    let level: String?
    let supportedLevels: [String]
    let defaultLevel: String
    let isRunning: Bool
    let onCycle: () -> Void
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var hoveredLevel: String?
    @State private var optimisticLevel: String?

    private var isLoadingLevels: Bool { supportedLevels.isEmpty }
    private var levels: [String] { supportedLevels }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \(displayLevel.capitalized)")
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Thinking", systemImage: "brain.head.profile")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)

                if isLoadingLevels {
                    HStack(spacing: 10) {
                        AppSpinner()
                            .controlSize(.small)
                        Text("Loading")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 10)
                } else {
                    ForEach(levels, id: \.self) { candidate in
                        thinkingLevelRow(candidate)
                    }
                }
            }
            .padding(12)
            .frame(width: 220)
        }
        .help(isRunning ? "Change thinking level" : "Choose thinking level for this session before launch")
        .onChange(of: normalizedLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: defaultLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: supportedLevels) { _, _ in
            optimisticLevel = nil
        }
    }

    private func thinkingLevelRow(_ candidate: String) -> some View {
        let isSelected = candidate == resolvedLevel
        let isHovered = hoveredLevel == candidate
        let rowShape = RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous)

        return Button {
            optimisticLevel = candidate
            onSelect(candidate)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AppTheme.Font.body.weight(.semibold))
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 18, height: 18)

                Text(candidate.capitalized)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 10)
            .background(rowShape.fill(rowFill(isSelected: isSelected, isHovered: isHovered)))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredLevel = hovering ? candidate : (hoveredLevel == candidate ? nil : hoveredLevel)
        }
        .accessibilityLabel("Thinking \(candidate.capitalized)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return AppTheme.selectionFill }
        if isHovered { return AppTheme.contentSubtleFill }
        return .clear
    }

    private var normalizedLevel: String? {
        guard let level else { return nil }
        return level == "none" ? "off" : level
    }

    private var resolvedLevel: String {
        optimisticLevel ?? normalizedLevel ?? defaultLevel
    }

    private var displayLevel: String {
        if isLoadingLevels {
            return resolvedLevel.isEmpty ? "loading" : resolvedLevel
        }
        return levels.contains(resolvedLevel) ? resolvedLevel : "\(resolvedLevel) unavailable"
    }
}
