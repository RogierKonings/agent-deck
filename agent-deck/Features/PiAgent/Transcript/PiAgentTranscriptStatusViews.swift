import AppKit
import SwiftUI

struct PiAgentStatusTranscriptRow: View {
    let entry: PiAgentTranscriptEntry
    @State private var promptPopover: PromptPopover?
    @State private var isErrorPopoverPresented = false

    private struct PromptPopover: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    var body: some View {
        if isDividerEntry {
            compactionDivider
        } else {
            compactStatusRow
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous))
                .onTapGesture {
                    guard showsErrorPopover else { return }
                    isErrorPopoverPresented = true
                }
                .popover(item: $promptPopover, arrowEdge: .bottom) { prompt in
                    PiAgentPromptAuditPopover(title: prompt.title, text: prompt.text)
                }
                .popover(isPresented: $isErrorPopoverPresented, arrowEdge: .bottom) {
                    PiAgentErrorDetailPopover(title: entry.title, text: entry.text)
                }
        }
    }

    private var compactionDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
            HStack(spacing: 7) {
                if isCompacting {
                    AppSpinner()
                        .controlSize(.small)
                } else {
                    Image(systemName: dividerIcon)
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text(detail)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .layoutPriority(1)
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var compactStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(AppTheme.Font.caption.weight(.semibold))
            Text(detail)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(AppTheme.Font.caption2)
                .foregroundStyle(AppTheme.mutedText)
            if isCopyableToolError {
                AppCopyIconButton(
                    text: errorClipboardText,
                    help: "Copy tool error",
                    size: CGSize(width: 22, height: 22)
                )
            }
            ForEach(promptActions) { action in
                Button {
                    promptPopover = .init(title: action.title, text: action.text())
                } label: {
                    Image(systemName: action.icon)
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(action.help)
                .disabled(!action.isEnabled)
            }
        }
        .padding(.horizontal, AppTheme.Chat.cardHPadding)
        .padding(.vertical, AppTheme.Chat.cardVPadding)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(color.opacity(0.08)).stroke(color.opacity(0.16), lineWidth: 1))
    }

    private var title: String {
        if entry.title == "Compaction" { return "Context" }
        if entry.title.hasPrefix("Tool: ") { return "Tool failed" }
        return entry.title
    }

    private var isCopyableToolError: Bool {
        entry.role == .error && entry.title.hasPrefix("Tool: ")
    }

    private var errorClipboardText: String {
        let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
        return "Tool failed: \(toolName)\n\n\(entry.text)"
    }

    private var detail: String {
        let normalized = entry.text
            .replacingOccurrences(of: "Context compacted.", with: "compacted")
            .replacingOccurrences(of: "Context compacted", with: "compacted")
            .replacingOccurrences(of: "Compacting conversation context (context)…", with: "compacting…")
            .replacingOccurrences(of: "Compacting context…", with: "compacting…")
            .replacingOccurrences(of: "\n", with: " ")
        if entry.title.hasPrefix("Tool: ") {
            let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
            return "\(toolName): \(normalized)"
        }
        return normalized
    }

    private var isCompacting: Bool {
        detail.localizedCaseInsensitiveContains("compacting") && !detail.localizedCaseInsensitiveContains("compacted")
    }

    private var icon: String {
        if entry.title == "Compaction" { return "arrow.triangle.2.circlepath" }
        if entry.role == .error { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var isDividerEntry: Bool {
        entry.isDividerStatus
    }

    private var dividerIcon: String {
        PiAgentGitEventKind.from(title: entry.title)?.icon ?? "arrow.triangle.2.circlepath"
    }

    private var color: Color {
        if entry.title == "Compaction" { return .secondary }
        if entry.role == .error { return AppTheme.roleError }
        return .secondary
    }

    private var showsErrorPopover: Bool {
        entry.role == .error && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptActions: [PromptAuditAction] {
        if entry.title == "System Prompt Captured", let prompt = capturedSystemPrompt {
            return [
                PromptAuditAction(
                    title: "Final System Prompt",
                    icon: "doc.text.magnifyingglass",
                    help: "Show final system prompt captured from Pi runtime",
                    isEnabled: true,
                    text: { prompt }
                )
            ]
        }

        guard entry.title == "Subagent Started", let metadata = subagentPromptMetadata else { return [] }
        return [
            PromptAuditAction(
                title: "\(AppBrand.displayName) Authored System Prompt",
                icon: "doc.text",
                help: "Show system prompt \(AppBrand.displayName) passed to the child",
                isEnabled: true,
                text: { promptFileText(path: metadata.authoredSystemPromptPath) }
            ),
            PromptAuditAction(
                title: "Final Runtime System Prompt",
                icon: "doc.text.magnifyingglass",
                help: "Show system prompt captured from the child Pi runtime",
                isEnabled: true,
                text: { promptFileText(path: metadata.finalSystemPromptPath) }
            )
        ]
    }

    private var capturedSystemPrompt: String? {
        guard let raw = entry.rawJSON else { return nil }
        // Memoized by raw content — re-decoding on every body eval otherwise.
        return JSONParseMemo.value("capturedSystemPrompt\(JSONParseMemo.separator)\(raw)") {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let prefill = object["prefill"] as? String,
               let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
               let prompt = payload["systemPrompt"] as? String {
                return prompt
            }
            if let dataObject = object["data"] as? [String: Any],
               let prefill = dataObject["prefill"] as? String,
               let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
               let prompt = payload["systemPrompt"] as? String {
                return prompt
            }
            return object["systemPrompt"] as? String
        }
    }

    private var subagentPromptMetadata: SubagentPromptMetadata? {
        guard let raw = entry.rawJSON else { return nil }
        return JSONParseMemo.value("subagentPromptMetadata\(JSONParseMemo.separator)\(raw)") {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["agent_deck_subagent_started", "agent_deck_subagent_card"].contains(object["type"] as? String),
                  let authored = object["authoredSystemPromptPath"] as? String,
                  let final = object["finalSystemPromptPath"] as? String else { return nil }
            return SubagentPromptMetadata(authoredSystemPromptPath: authored, finalSystemPromptPath: final)
        }
    }
}

private struct PromptAuditAction: Identifiable {
    let id = UUID()
    var title: String
    var icon: String
    var help: String
    var isEnabled: Bool
    var text: () -> String
}

private struct SubagentPromptMetadata {
    var authoredSystemPromptPath: String
    var finalSystemPromptPath: String
}

/// Pinned at the top of a forked session's transcript. Shows where the session
/// was forked from, with a "View" button that pops over the snapshot of the
/// parent transcript captured at fork time. Tapping "Open Parent" selects the
/// parent session in the sidebar so the user can jump back to the source.
struct PiAgentForkOriginCard: View {
    var parentTitle: String
    var parentSessionID: UUID?
    var transcriptSnapshot: String?
    var onSelectParent: ((UUID) -> Void)?
    @State private var isSnapshotPresented = false

    var body: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Forked from")
                        Text("\u{201C}\(parentTitle)\u{201D}")
                            .fontWeight(.semibold)
                    }
                    .font(AppTheme.Font.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    if let snapshot = transcriptSnapshot, !snapshot.isEmpty {
                        Text("~\(formatPromptTokens(estimatedPromptTokens(snapshot))) of parent transcript captured")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    } else {
                        Text("Parent transcript not captured")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }

                Spacer(minLength: 0)

                if let parentSessionID, let onSelectParent {
                    Button("Open Parent") {
                        onSelectParent(parentSessionID)
                    }
                    .appSecondaryButton()
                    .controlSize(.small)
                }

                if let snapshot = transcriptSnapshot, !snapshot.isEmpty {
                    Button("View") {
                        isSnapshotPresented = true
                    }
                    .appSecondaryButton()
                    .controlSize(.small)
                    .popover(isPresented: $isSnapshotPresented, arrowEdge: .bottom) {
                        PiAgentPromptAuditPopover(title: "Forked from \u{201C}\(parentTitle)\u{201D}", text: snapshot)
                    }
                }
            }
        }
    }
}

struct PiAgentSystemPromptAuditCard: View {
    var title: String
    var subtitle: String
    var prompt: String
    @State private var isPromptPresented = false

    var body: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppTheme.Font.headline)
                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                            Text("·")
                        }
                        Image(systemName: "tugriksign.circle")
                            .font(AppTheme.Font.caption2.weight(.semibold))
                        Text("~\(formatPromptTokens(estimatedPromptTokens(prompt)))")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                    }
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }

                Spacer(minLength: 0)

                Button("View") {
                    isPromptPresented = true
                }
                .appSecondaryButton()
                .controlSize(.small)
                .popover(isPresented: $isPromptPresented, arrowEdge: .bottom) {
                    PiAgentPromptAuditPopover(title: title, text: prompt)
                }
            }
        }
    }
}

extension PiAgentTranscriptEntry {
    var nativeSubagentRunID: UUID? {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              ["agent_deck_subagent_started", "agent_deck_subagent_card"].contains(type),
              let runID = object["runID"] as? String else { return nil }
        return UUID(uuidString: runID)
    }

    /// Status entries that should span the full transcript width as a divider,
    /// not be inset to the assistant bubble width.
    var isDividerStatus: Bool {
        guard role == .status else { return false }
        if title == "Compaction" { return true }
        return PiAgentGitEventKind.from(title: title) != nil
    }
}

func estimatedPromptTokens(_ text: String) -> Int {
    guard text.isEmpty == false else { return 0 }
    return Int(ceil(Double(text.count) / 3.5))
}

func formatPromptTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 10_000 { return "\(value / 1_000)k" }
    return value.formatted()
}

func promptFileText(path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Prompt file is not available yet:\n\(path)"
}

struct PiAgentPromptAuditPopover: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(AppTheme.brandAccent)
                Text(title)
                    .font(AppTheme.Font.headline)
                Spacer(minLength: 0)
                AppCopyIconButton(
                    text: text,
                    help: "Copy prompt",
                    size: CGSize(width: 26, height: 26)
                )
            }

            ScrollView(showsIndicators: false) {
                Text(text.isEmpty ? "No prompt content captured." : text)
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 720, height: 520)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .padding(14)
    }
}

struct PiAgentErrorDetailPopover: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.roleError)
                Text(title)
                    .font(AppTheme.Font.headline)
                Spacer(minLength: 0)
                AppCopyIconButton(
                    text: text,
                    help: "Copy error",
                    size: CGSize(width: 26, height: 26)
                )
            }

            Text(text)
                .font(AppTheme.Font.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .leading)
                .foregroundStyle(.primary)
        }
        .padding(14)
    }
}
