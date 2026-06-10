import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionListContent: View, Equatable {
    let visibleSessions: [PiAgentSessionRecord]
    let selectedSessionIDs: Set<UUID>
    let renamingSessionID: UUID?
    let workingSessionIDs: Set<UUID>
    let generatingTitleIDs: Set<UUID>
    let activityByID: [UUID: PiAgentSessionGitActivity]
    let projectsByID: [UUID: DiscoveredProject?]

    @Binding var selection: Set<UUID>
    let onSelect: (PiAgentSessionRecord) -> Void
    let onBeginRename: (PiAgentSessionRecord) -> Void
    let onEndRename: () -> Void
    let onRename: (UUID, String) -> Void
    let onTogglePinned: (UUID) -> Void
    let onDelete: (UUID) -> Void

    static func == (lhs: SessionListContent, rhs: SessionListContent) -> Bool {
        let diff: String?
        if lhs.visibleSessions != rhs.visibleSessions { diff = "visibleSessions" }
        else if lhs.selectedSessionIDs != rhs.selectedSessionIDs { diff = "selectedSessionIDs" }
        else if lhs.renamingSessionID != rhs.renamingSessionID { diff = "renamingSessionID" }
        else if lhs.workingSessionIDs != rhs.workingSessionIDs { diff = "workingSessionIDs" }
        else if lhs.generatingTitleIDs != rhs.generatingTitleIDs { diff = "generatingTitleIDs" }
        else if lhs.activityByID != rhs.activityByID { diff = "activityByID" }
        else if !Self.projectsVisuallyEqual(lhs.projectsByID, rhs.projectsByID) { diff = "projectsByID" }
        else { diff = nil }
#if DEBUG
        if let diff {
            SessionListContent.perfLog.error("SessionListContent re-eval — input changed: \(diff, privacy: .public)")
        }
#endif
        return diff == nil
    }

    /// Compare the project map by ONLY what a row's icon actually shows — the
    /// project identity (path) and its icon file — not the whole DiscoveredProject.
    /// `viewModel.projectByPath` is reassigned wholesale on every project
    /// re-discovery, which fires constantly while an agent writes files; the
    /// re-derived projects differ in volatile fields (e.g. gitHubRemote resolving)
    /// that the session row never displays. Comparing the full value made the list
    /// re-evaluate ~30Hz (the dominant scroll-profile cost); this keeps it stable
    /// while still reacting to a project being added/removed or its icon changing.
    private static func projectsVisuallyEqual(_ lhs: [UUID: DiscoveredProject?], _ rhs: [UUID: DiscoveredProject?]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (id, lProject) in lhs {
            guard let rProject = rhs[id] else { return false }
            if lProject?.id != rProject?.id || lProject?.iconFileURL != rProject?.iconFileURL {
                return false
            }
        }
        return true
    }

#if DEBUG
    private static let perfLog = Logger(subsystem: "streetcoding.agent-deck", category: "SessionListPerf")
#endif

    var body: some View {
        AppList(
            sections: [AppListSection(id: "sessions", title: nil, items: visibleSessions)],
            selection: .multi($selection),
            cornerRadius: AppTheme.Chat.subCardCornerRadius,
            rowHorizontalPadding: 0,
            rowVerticalPadding: 0,
            listHorizontalInset: 6
        ) { session in
            row(session)
        }
        .animation(.snappy(duration: 0.24), value: visibleSessions.map(\.id))
        .bottomEdgeFade(height: 34)
    }

    @ViewBuilder
    private func row(_ session: PiAgentSessionRecord) -> some View {
        PiAgentSessionRow(
            session: session,
            project: projectsByID[session.id] ?? nil,
            isSelected: selectedSessionIDs.contains(session.id),
            isRunning: workingSessionIDs.contains(session.id),
            isRenaming: renamingSessionID == session.id,
            isGeneratingTitle: generatingTitleIDs.contains(session.id),
            gitActivity: activityByID[session.id] ?? .none,
            onSelect: { onSelect(session) },
            onBeginRename: { onBeginRename(session) },
            onEndRename: onEndRename,
            onRename: { onRename(session.id, $0) },
            onTogglePinned: { onTogglePinned(session.id) },
            onDelete: { onDelete(session.id) }
        )
        .equatable()
        .contextMenu {
            Button {
                onTogglePinned(session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                onDelete(session.id)
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected Sessions" : "Delete Session", systemImage: "trash")
            }
        }
    }
}
