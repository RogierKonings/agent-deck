import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentSessionSearchField: View {
    var placeholder = "Search all sessions"
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .appBrandTint()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }
}

struct PiAgentAddSessionButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: "New Pi Agent session",
            action: action
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("New Pi Agent session")
    }
}

struct PiAgentAddSessionMenuButton: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let action: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: projects.isEmpty
                ? "New projectless Pi Agent session"
                : "Choose a project for the new Pi Agent session",
            action: primaryAction
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("New Pi Agent session")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PiAgentProjectPickerPopover(
                projects: orderedProjects,
                selectedProject: selectedProject,
                onSelectProject: { project in
                    isPresented = false
                    onSelectProject(project)
                }
            )
        }
    }

    private func primaryAction() {
        if projects.isEmpty {
            action()
        } else {
            isPresented.toggle()
        }
    }

    private var orderedProjects: [DiscoveredProject] {
        guard let selectedProject,
              let index = projects.firstIndex(where: { $0.id == selectedProject.id }) else { return projects }
        var ordered = projects
        ordered.remove(at: index)
        ordered.insert(selectedProject, at: 0)
        return ordered
    }
}

/// Icon-only round button surfaced next to the `+` only when the user has
/// Deck agents enabled. Opens a native `Menu` (NSMenu) listing every
/// discovered agent — tap one to launch a fresh 1:1 chat in the resolved
/// project (scoped sidebar project → most recently active → first available).
struct PiAgentChatWithAgentButton: View {
    let viewModel: AppViewModel
    @State private var resolvedProject: DiscoveredProject?
    @State private var resolvedAgents: [EffectiveAgentRecord] = []

    var body: some View {
        AppCircleIconMenu(
            style: .soft,
            tint: AppTheme.brandAccent,
            size: 30,
            symbolWeight: .bold,
            help: "Chat directly with an agent"
        ) {
            Image(systemName: "paperplane")
        } content: {
            menuContent
        }
        .accessibilityLabel("Chat with agent")
        .onAppear { refresh() }
        .onChange(of: viewModel.selectedDiscoveredProject?.path) { _, _ in refresh() }
        .onChange(of: viewModel.discoveredProjects.count) { _, _ in refresh() }
    }

    @ViewBuilder
    private var menuContent: some View {
        if let project = resolvedProject {
            Section("Start a 1:1 session with…") {
                if resolvedAgents.isEmpty {
                    Text("No agents available in \(project.repositoryDisplayName)")
                } else {
                    ForEach(resolvedAgents, id: \.name) { agent in
                        Button {
                            viewModel.startAgentSession(agent: agent, project: project, initialInstruction: nil)
                        } label: {
                            Label(agent.name, systemImage: "paperplane")
                        }
                    }
                }
            }
        } else {
            Text("No project available")
        }
    }

    private func refresh() {
        resolvedProject = resolveProject()
        guard let project = resolvedProject else {
            resolvedAgents = []
            return
        }
        resolvedAgents = viewModel.selectableAgentUniverse(forProjectPath: project.path)
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func resolveProject() -> DiscoveredProject? {
        if let scoped = viewModel.selectedDiscoveredProject { return scoped }
        let sessions = viewModel.piAgentSessionStore.sessions
        if let candidate = sessions.max(by: { $0.updatedAt < $1.updatedAt }),
           let match = viewModel.projectByPath[candidate.projectPath] {
            return match
        }
        return viewModel.discoveredProjects.first
    }
}

private struct PiAgentProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
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
                                    HStack(spacing: 6) {
                                        Text(project.repositoryDisplayName)
                                            .font(AppTheme.Font.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if project.id == selectedProject?.id {
                                            Text("Current")
                                                .font(AppTheme.Font.caption2.weight(.semibold))
                                                .foregroundStyle(AppTheme.brandAccent)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.10)))
                                        }
                                    }
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

struct PiAgentSessionRow: View, Equatable {
    let session: PiAgentSessionRecord
    let project: DiscoveredProject?
    let isSelected: Bool
    let isRunning: Bool
    let isRenaming: Bool
    let isGeneratingTitle: Bool
    let gitActivity: PiAgentSessionGitActivity
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onEndRename: () -> Void
    let onRename: (String) -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    // Equatable so `.equatable()` can short-circuit re-evaluation: the session list
    // lives inside a body that re-runs at the streaming cadence (the transcript cache
    // is an ObservableObject, so any of its published changes invalidates the whole
    // body). Comparing the value inputs lets SwiftUI skip re-laying-out every row on
    // those pulses, refreshing a row only when something it actually shows changes.
    // Closures are intentionally excluded: when the value inputs match, the retained
    // instance's closures captured the same session, so they stay correct.
    static func == (lhs: PiAgentSessionRow, rhs: PiAgentSessionRow) -> Bool {
        lhs.session == rhs.session
            // Compare the project by ONLY what the row draws — its icon (identity
            // + icon file). The full `DiscoveredProject ==` includes volatile
            // fields (e.g. gitHubRemote resolving) that churn while an agent writes
            // files; using it here made EVERY row re-render whenever the list
            // re-evaluated for an unrelated reason (a session switch, selection
            // change). Mirrors `SessionListContent.projectsVisuallyEqual`.
            && lhs.project?.id == rhs.project?.id
            && lhs.project?.iconFileURL == rhs.project?.iconFileURL
            && lhs.isSelected == rhs.isSelected
            && lhs.isRunning == rhs.isRunning
            && lhs.isRenaming == rhs.isRenaming
            && lhs.isGeneratingTitle == rhs.isGeneratingTitle
            && lhs.gitActivity == rhs.gitActivity
    }

    @State private var draftTitle = ""
    @State private var isTitleHovered = false
    @State private var isRowHovered = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    PiAgentProjectIcon(project: project, session: session)

                    titleView
                        .layoutPriority(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
            }

            if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                    Text(agentName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.8)
                }
                .font(AppTheme.Font.footnote)
                .foregroundStyle(AppTheme.mutedText)
            }

            HStack(spacing: 6) {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
            }
            .font(AppTheme.Font.footnote)
            .foregroundStyle(AppTheme.mutedText)

            if let branch = session.branchName, !branch.isEmpty {
                HStack(spacing: 6) {
                    Image("branch")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                    Text(piAgentSessionDisplayBranchName(branch))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(AppTheme.Font.footnote)
                .foregroundStyle(AppTheme.mutedText)
                .help(branch)
            }

            HStack(spacing: 8) {
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                SessionGitActivityStrip(activity: gitActivity, isSelected: isSelected)
            }
        }
        .saturation(seenAppearanceAmount)
        .opacity(seenContentOpacity)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                attentionStatusSlot
                    .opacity(isRowHovered ? 0 : 1)
                    .allowsHitTesting(false)
                deleteButton
                    .opacity(isRowHovered ? 1 : 0)
                    .allowsHitTesting(isRowHovered)
            }
            .padding(.trailing, 12)
            .animation(.easeInOut(duration: 0.15), value: isRowHovered)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isRowHovered = $0 }
        .help(statusHelp)
        .onAppear {
            draftTitle = sessionTitle
        }
        .onChange(of: session.id) { _, _ in resetRenameState() }
        .onChange(of: session.title) { _, _ in draftTitle = sessionTitle }
        .onChange(of: isTitleFocused) { _, focused in
            // Commit on blur, but skip if we're already exiting rename mode —
            // otherwise commitRename's onEndRename callback flips isRenaming,
            // which can race the focus state into an AttributeGraph cycle.
            guard !focused, isRenaming else { return }
            commitRename()
        }
        .onDisappear(perform: commitRename)
    }

    private var selectedSessionIndicator: some View {
        Circle()
            .fill(AppTheme.brandAccent.opacity(0.72))
            .frame(width: 6, height: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var isSeenInactive: Bool {
        !isSelected && !isRunning && !session.needsAttention
    }

    private var seenAppearanceAmount: Double {
        isSeenInactive ? 0.38 : 1
    }

    private var seenContentOpacity: Double {
        isSeenInactive ? 0.58 : 1
    }

    @ViewBuilder
    private var attentionStatusSlot: some View {
        ZStack(alignment: .trailing) {
            if isRunning {
                activeStatusLabel
                    .transition(.opacity)
            } else if session.needsAttention {
                needsAttentionBell
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24), value: isRunning)
        .animation(.snappy(duration: 0.24), value: session.needsAttention)
    }

    private var activeStatusLabel: some View {
        Text("ACTIVE")
            .font(AppTheme.Font.smallLabel)
            .tracking(1.2)
            .foregroundStyle(AppTheme.brandAccent.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(AppTheme.contentFill.opacity(0.72)))
            .accessibilityHidden(true)
    }

    private var needsAttentionBell: some View {
        Image(systemName: "bell.fill")
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .help("Pi Agent finished and needs review")
            .accessibilityLabel("Needs review")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(AppTheme.Font.caption.weight(.semibold))
        }
        .appSmallSecondaryButton()
        .help("Delete session")
        .accessibilityLabel("Delete session")
    }

    private var activeBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.brandAccentBright.opacity(0.10),
                AppTheme.brandAccent.opacity(0.045),
                AppTheme.brandAccentDeep.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var titleView: some View {
        if isRenaming {
            TextField("Session name", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(AppTheme.Font.footnote.weight(.semibold))
                .fontWidth(.expanded)
                .lineLimit(1)
                .frame(height: 22, alignment: .center)
                .focused($isTitleFocused)
                .onSubmit(commitRename)
                .onExitCommand { resetRenameState() }
                .onAppear {
                    draftTitle = sessionTitle
                    isTitleFocused = true
                }
        } else {
            HStack(alignment: .center, spacing: 5) {
                Text(sessionTitle)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsTightening(true)
                    .lineSpacing(-2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxHeight: 30, alignment: .center)
                    .contentTransition(.numericText())
                    .opacity(isGeneratingTitle ? 0.62 : 1)
                    .animation(isGeneratingTitle ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default, value: isGeneratingTitle)
                Image(systemName: "pencil")
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .opacity(isTitleHovered ? 0.8 : 0)
            }
            .font(AppTheme.Font.footnote.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minHeight: 22, maxHeight: 30, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isTitleHovered = $0 }
            .onTapGesture(perform: onBeginRename)
            .help("Rename session")
        }
    }

    private func resetRenameState() {
        draftTitle = sessionTitle
        onEndRename()
        // Don't write isTitleFocused = false here — the TextField will leave the
        // view tree when isRenaming flips, releasing focus naturally. Writing it
        // re-enters .onChange(of: isTitleFocused) which can self-trigger.
    }

    private func commitRename() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            draftTitle = sessionTitle
        } else if trimmedTitle != session.title {
            onRename(trimmedTitle)
        }
        onEndRename()
    }

    private var sessionTitle: String {
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.issueNumber.map { "#\($0)" } ?? "Project agent"
        }
        return session.title
    }

    private var subtitle: String {
        if let repository = session.repository {
            return repository
        }
        return session.projectName
    }

    private var statusHelp: String {
        if isRunning { return "Active" }
        return session.status.rawValue
    }

    private var statusColor: Color {
        switch session.status {
        case .running, .starting: return AppTheme.brandAccent
        case .idle, .completed: return .secondary
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct SessionGitActivityStrip: View {
    let activity: PiAgentSessionGitActivity
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            pip(kind: .commit, date: activity.lastCommit, verb: "commit")
            pip(kind: .push,   date: activity.lastPush,   verb: "push")
            pip(kind: .merge,  date: activity.lastMerge,  verb: "merge")
        }
    }

    @ViewBuilder
    private func pip(kind: PiAgentGitEventKind, date: Date?, verb: String) -> some View {
        if let date {
            icon(for: kind)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                .help("Last \(verb) at \(date.formatted(date: .omitted, time: .shortened))")
        }
    }

    @ViewBuilder
    private func icon(for kind: PiAgentGitEventKind) -> some View {
        switch kind {
        case .commit, .commitAndPush:
            Image("git-commit")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
        case .push:
            Image(systemName: "arrow.up")
        case .merge:
            Image(systemName: "arrow.triangle.merge")
        }
    }
}

private struct PiAgentSessionTelemetryStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<18, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(segmentColor(index: index))
                    .frame(width: segmentWidth(index: index), height: segmentHeight(index: index))
                    .shadow(color: AppTheme.brandAccent.opacity(activeSegment(index) ? 0.32 : 0), radius: 4, y: 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(index % 6) * 0.055), value: isActive)
            }
            Spacer(minLength: 0)
            Text("ACTIVE")
                .font(AppTheme.Font.smallLabel)
                .tracking(1.2)
                .foregroundStyle(AppTheme.brandAccent.opacity(0.72))
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }

    private func activeSegment(_ index: Int) -> Bool {
        guard !reduceMotion else { return index % 3 == 0 }
        return isActive ? index % 3 != 1 : index % 4 == 0
    }

    private func segmentColor(index: Int) -> Color {
        let baseOpacity = activeSegment(index) ? 0.78 : 0.18
        if index % 5 == 0 {
            return AppTheme.brandAccentBright.opacity(baseOpacity)
        }
        return AppTheme.brandAccent.opacity(baseOpacity)
    }

    private func segmentWidth(index: Int) -> CGFloat {
        activeSegment(index) ? CGFloat([10, 16, 7, 12, 20, 9][index % 6]) : 6
    }

    private func segmentHeight(index: Int) -> CGFloat {
        activeSegment(index) ? CGFloat([2, 3, 2, 4, 3, 2][index % 6]) : 2
    }
}

struct PiAgentProjectIcon: View {
    let project: DiscoveredProject?
    let session: PiAgentSessionRecord
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous))
        // Route through the shared ProjectIconCache so scrolling the session
        // list doesn't re-decode the same PNG per row appear. Identity is the
        // file path; same key used by ProjectIconView for the project switcher.
        .task(id: project?.iconFileURL?.path) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url = project?.iconFileURL else {
            image = nil
            return
        }
        if let cached = await ProjectIconCache.shared.cachedImage(for: url) {
            image = cached
            return
        }
        let loaded = await ProjectIconCache.shared.loadImage(for: url)
        guard url == project?.iconFileURL else { return }
        image = loaded
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous)
            .fill(AppTheme.contentSubtleFill)
            .overlay {
                Image(session.kind == .issue ? "github" : "pi")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(AppTheme.mutedText)
            }
    }
}

struct PiAgentProcessingIndicatorBar: View {
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            if let message {
                Image("pi")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppTheme.piLogo.gradient)
                    .frame(width: 14, height: 14)
                Text(message)
                    .font(AppTheme.Font.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                PiAgentTypingIndicator()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: message)
    }
}

struct PiAgentTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = phase == index
                Circle()
                    .fill(Color.secondary.opacity(isActive ? 0.78 : 0.22))
                    .frame(width: 5, height: 5)
                    .scaleEffect(reduceMotion ? 1 : (isActive ? 1.18 : 0.86))
            }
        }
        .padding(.vertical, 5)
        .task {
            // `try await Task.sleep` (no `?`) throws on cancellation, which
            // exits the loop on the same tick instead of waiting for the
            // subsequent `guard !Task.isCancelled` to fire.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(620))
                } catch {
                    return
                }
                // Pause the wake-up when the window is fully occluded so
                // background apps don't spin a 620ms timer on the cooperative
                // scheduler for every visible typing indicator.
                guard NSApp.occlusionState.contains(.visible) else {
                    continue
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityLabel("Pi is typing")
    }
}
