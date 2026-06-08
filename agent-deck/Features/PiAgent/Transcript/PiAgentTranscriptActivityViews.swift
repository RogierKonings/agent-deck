import AppKit
import SwiftUI

struct PiAgentWebActivitySummaryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activities: [PiAgentTranscriptActivity]
    @State private var expandedRows: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(hasErrors ? AppTheme.roleError : AppTheme.mutedText)
                Text(title)
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text(callCountText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
                ForEach(displayRows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: row.icon)
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(row.isError ? AppTheme.roleError : AppTheme.mutedText)
                                .frame(width: 14)
                            Text(row.title)
                                .font(AppTheme.Font.caption.weight(.semibold))
                            if let detail = row.detail {
                                Text(detail)
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }

                        if !row.links.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(visibleLinks(for: row)) { link in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•")
                                            .foregroundStyle(AppTheme.mutedText)
                                        Text(link.title)
                                            .font(AppTheme.Font.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(link.domain)
                                            .font(AppTheme.Font.caption2)
                                            .foregroundStyle(AppTheme.mutedText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                if row.links.count > inlineLinkLimit {
                                    Button {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { toggleExpanded(row.id) }
                                    } label: {
                                        Text(expandedRows.contains(row.id) ? "Show fewer results" : "+\(row.links.count - inlineLinkLimit) more results")
                                            .font(AppTheme.Font.caption2.weight(.semibold))
                                            .foregroundStyle(AppTheme.brandAccent)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 1)
                                }
                            }
                            .padding(.leading, 21)
                        }
                    }
                }
                if hiddenCount > 0 {
                    Text("\(hiddenCount) older web update\(hiddenCount == 1 ? "" : "s") hidden")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .padding(.horizontal, AppTheme.Chat.cardHPadding)
        .padding(.vertical, AppTheme.Chat.cardVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private let inlineLinkLimit = 5

    private func visibleLinks(for row: Row) -> [PiAgentWebLink] {
        expandedRows.contains(row.id) ? row.links : Array(row.links.prefix(inlineLinkLimit))
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
    }

    private var displayRows: [Row] {
        activities.map(Row.init(activity:)).prefix(4).map { $0 }
    }

    private var hiddenCount: Int {
        max(0, activities.count - displayRows.count)
    }

    private var title: String {
        let names = Set(activities.map { $0.name.lowercased() })
        if names.count == 1, let name = names.first {
            switch name {
            case "web_search": return "Web search"
            case "fetch_content": return "Fetch content"
            case "get_search_content": return "Read web content"
            case "web_fetch": return "URL fetch"
            default: break
            }
        }
        return "Web"
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let detail: String?
        let icon: String
        let isError: Bool
        let links: [PiAgentWebLink]

        nonisolated init(activity: PiAgentTranscriptActivity) {
            id = activity.id
            title = Self.title(for: activity.name)
            detail = activity.compactDetail
            icon = Self.icon(for: activity.name)
            isError = activity.isError
            links = activity.webLinks
        }

        nonisolated private static func title(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "Search"
            case "fetch_content": return "Fetched"
            case "get_search_content": return "Read content"
            case "web_fetch": return "Fetched"
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        nonisolated private static func icon(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "magnifyingglass"
            case "fetch_content", "get_search_content", "web_fetch": return "doc.text.magnifyingglass"
            default: return "globe"
            }
        }
    }
}

struct PiAgentActivitySummaryView: View {
    let activities: [PiAgentTranscriptActivity]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasErrors ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(hasErrors ? AppTheme.roleError : AppTheme.mutedText)
            Text("Tools")
                .font(AppTheme.Font.caption.weight(.semibold))
            Text(callCountText)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activities) { activity in
                        activityChip(activity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Chat.cardHPadding)
        .padding(.vertical, AppTheme.Chat.cardVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private func activityChip(_ activity: PiAgentTranscriptActivity) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon(for: activity.name))
                .font(AppTheme.Font.caption2.weight(.semibold))
            Text(displayName(for: activity.name, count: activity.count))
                .font(AppTheme.Font.caption)
            Text("\(activity.count)")
                .font(AppTheme.Font.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(AppTheme.contentStroke.opacity(0.55)))
        }
        .foregroundStyle(activity.isError ? AppTheme.roleError : AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill((activity.isError ? AppTheme.roleError : AppTheme.contentStroke).opacity(AppTheme.roleChipOpacity)))
    }

    private func displayName(for name: String, count: Int) -> String {
        switch name.lowercased() {
        case "bash": return "Shell"
        case "read": return "File read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "set_session_plan": return "Plan"
        case "update_session_plan": return "Plan update"
        case "subagent": return count == 1 ? "Deck agent" : "Deck agents"
        case "web_search": return "Web search"
        case "fetch_content", "get_search_content", "web_fetch": return "Web content"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func icon(for name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "set_session_plan", "update_session_plan": return "checklist"
        case "subagent": return "person.2.wave.2"
        case "web_search", "fetch_content", "get_search_content", "web_fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct PiAgentActivityDetailView: View {
    let activity: PiAgentTranscriptActivity

    var body: some View {
        if let summary = activity.subagentSummary {
            PiAgentSubagentTranscriptView(summary: summary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(activity.isError ? AppTheme.roleError : AppTheme.mutedText)
                    Text(activity.name)
                        .font(AppTheme.Font.caption.weight(.semibold))
                    if activity.count > 1 {
                        Text("×\(activity.count)")
                            .font(AppTheme.Font.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                }
                ForEach(activity.entries.suffix(3)) { entry in
                    PiAgentToolTranscriptView(entry: entry, startsExpanded: false)
                }
                if activity.entries.count > 3 {
                    Text("\(activity.entries.count - 3) older updates hidden")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private var icon: String {
        switch activity.name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }
}
