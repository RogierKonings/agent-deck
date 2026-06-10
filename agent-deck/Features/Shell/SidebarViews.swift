import AppKit
import SwiftUI

struct SidebarNavigationRow: View {
    let item: SidebarItem
    var isSelected: Bool = false
    var showsWarning = false

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.rawValue)
                    .font(.callout.weight(.medium))
                if showsWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .help("This section has warnings that need attention.")
                        .accessibilityLabel("Section warning")
                }
            }
            .fontWidth(.expanded)
        } icon: {
            icon
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let asset = item.assetImageName {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundStyle(iconStyle)
        } else {
            Image(systemName: item.systemImage)
                .frame(width: 16, height: 16)
                .foregroundStyle(iconStyle)
        }
    }

    private var iconStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(AppTheme.brandAccent)
            : AnyShapeStyle(Color.secondary)
    }
}


/// Compact Pi Agent control that lives in the sidebar's bottom bar. Selection
/// is signaled primarily by the icon color (muted → brand gradient), with a
/// faint chip wash + stroke as the secondary cue. Running sessions render the
/// typing-dots animation inline; sessions needing input render a red badge in
/// the top-trailing corner. Full status copy is exposed via tooltip.
struct PiAgentSidebarChip: View {
    let isSelected: Bool
    let runningSessionCount: Int
    let needsAttentionCount: Int
    let action: () -> Void

    private var hasRunningSessions: Bool { runningSessionCount > 0 }
    private var hasAttention: Bool { needsAttentionCount > 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                (isSelected
                    ? Image(systemName: "chevron.right")
                    : Image("pi"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : Color.secondary)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                Text("Coding Agent")
                    .font(.callout.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)

                if hasRunningSessions || hasAttention {
                    HStack(spacing: 8) {
                        if hasRunningSessions {
                            PiAgentTypingIndicator()
                        }

                        if hasAttention {
                            Text(badgeText)
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, needsAttentionCount > 9 ? 5 : 4)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Capsule(style: .continuous).fill(Color.red))
                                .accessibilityLabel("\(needsAttentionCount) Pi Agent notification\(needsAttentionCount == 1 ? "" : "s")")
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isSelected)
        .help(statusText)
        .accessibilityLabel("Pi Agent")
        .accessibilityHint(accessibilityHint)
    }

    private var statusText: String {
        if hasAttention {
            let remainingRunningCount = max(0, runningSessionCount - needsAttentionCount)
            let waitingText = needsAttentionCount == 1 ? "1 waiting" : "\(needsAttentionCount) waiting"
            if remainingRunningCount > 0 {
                let runningText = remainingRunningCount == 1 ? "1 running" : "\(remainingRunningCount) running"
                return "\(waitingText) · \(runningText)"
            }
            return needsAttentionCount == 1 ? "1 session waiting" : "\(needsAttentionCount) sessions waiting"
        }

        if hasRunningSessions {
            return runningSessionCount == 1 ? "1 session running" : "\(runningSessionCount) sessions running"
        }

        return isSelected ? "Ready to code" : "Click to start coding"
    }

    private var accessibilityHint: String {
        if hasAttention {
            return needsAttentionCount == 1 ? "1 Pi Agent session is waiting" : "\(needsAttentionCount) Pi Agent sessions are waiting"
        }
        if hasRunningSessions {
            return runningSessionCount == 1 ? "1 Pi Agent session is running" : "\(runningSessionCount) Pi Agent sessions are running"
        }
        return "Open Pi Agent sessions"
    }

    private var badgeText: String {
        needsAttentionCount > 99 ? "99+" : "\(needsAttentionCount)"
    }
}


struct SidebarProjectGitHubCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var viewModel: AppViewModel
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let selectedProjectPath: String?
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject?) -> Void
    let onChooseProject: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(
                    imageURL: selectedProject?.iconFileURL,
                    symbolName: selectedProject?.fallbackSymbolName ?? "square.grid.2x2",
                    size: 34,
                    assetName: selectedProject?.projectType.assetName
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedProjectTitle)
                        .font(.body)
                        .fontWeight(.medium)
//                        .fontWidth(selectedProject != nil ? .expanded : .standard )
                        .lineLimit(1)
                    if selectedProject != nil {
                        Text(selectedProjectSubtitle)
                            .font(.callout)
                            .fontWeight(.regular)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .fontWidth(.compressed)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .appControlSurface(cornerRadius: 14)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose project")
                .accessibilityHint("Opens the project picker")
                .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                    ProjectPickerPopover(
                        projects: projects,
                        selectedProjectPath: selectedProjectPath,
                        filterText: $filterText,
                        isSearchDebouncing: isSearchDebouncing,
                        onSelectProject: { project in
                            onSelectProject(project)
                            isExpanded = false
                        }
                    )
                }
            }

            Divider()
                .opacity(0.7)

            HStack(spacing: 12) {
                SidebarGitHubAvatarView(url: avatarURL, size: 32)
                    .overlay(alignment: Alignment.bottomTrailing) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppTheme.contentFill, lineWidth: 2))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(AppTheme.mutedText)
                        .fontWidth(.compressed)
                }

                Spacer()

                Button {
                    viewModel.refreshEverything()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .appControlSurface(cornerRadius: 14)
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .accessibilityLabel("Refresh GitHub and projects")
                .disabled(viewModel.githubIsRefreshingEverything)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
        .appContentSurface(cornerRadius: 16)
    }

    private var selectedProjectTitle: String {
        if selectedProject == nil && selectedProjectPath == nil {
            return "All Projects"
        }
        if let remote = selectedProject?.gitHubRemote {
            return remote.repo
        }
        if let selectedProject {
            return selectedProject.name
        }
        if let selectedProjectPath {
            return URL(fileURLWithPath: selectedProjectPath).lastPathComponent
        }
        return "Choose Project"
    }

    private var selectedProjectSubtitle: String {
        if let remote = selectedProject?.gitHubRemote {
            return remote.owner
        }
        return selectedProject?.path ?? selectedProjectPath ?? ""
    }

    private var accountName: String {
        viewModel.currentGitHubAccount?.login ?? "GitHub"
    }

    private var statusText: String {
        if viewModel.githubIsRefreshingEverything {
            return "Refreshing…"
        }

        switch viewModel.githubConnectionState {
        case .connected:
            return "Connected"
        case .checking:
            return "Connecting…"
        case .failed:
            return "Error"
        case .available:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .disconnected:
            return "Inactive"
        }
    }

    private var statusColor: Color {
        switch viewModel.githubConnectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var avatarURL: URL? {
        guard let account = viewModel.currentGitHubAccount,
              account.host.caseInsensitiveCompare("github.com") == .orderedSame else { return nil }
        // Request a server-resized avatar (~160px) instead of the full 460px source:
        // crisper at 32pt and ~7x lighter to download.
        return URL(string: "https://avatars.githubusercontent.com/\(account.login)?s=160")
    }

}


struct ProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProjectPath: String?
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchFieldWithProgress(
                placeholder: "Search enabled projects",
                text: $filterText,
                isLoading: isSearchDebouncing,
                font: .subheadline
            )

            ScrollView {
                LazyVStack(spacing: 2) {
                    ProjectSidebarRow(
                        title: "All Projects",
                        subtitle: "Show sessions across every project",
                        symbolName: "square.grid.2x2",
                        imageURL: nil,
                        isSelected: selectedProjectPath == nil,
                        action: { select(nil) }
                    )

                    ForEach(projects) { project in
                        ProjectSidebarRow(
                            title: project.repositoryDisplayName,
                            subtitle: project.path,
                            symbolName: project.fallbackSymbolName,
                            imageURL: project.iconFileURL,
                            assetName: project.projectType.assetName,
                            isSelected: selectedProjectPath == project.path,
                            action: { select(project) }
                        )
                    }
                }
                .padding(.horizontal, 3)
            }
            .scrollIndicators(.hidden)
            .hideNativeScrollers()
            .frame(width: 360, height: 220)
        }
        .padding(14)
    }

    private func select(_ project: DiscoveredProject?) {
        // Hop to the next runloop tick: the tap fires inside a SwiftUI update
        // pass, and onSelectProject triggers @Published mutations on
        // AppViewModel that would otherwise emit "Publishing changes from
        // within view updates is not allowed".
        Task { @MainActor in
            onSelectProject(project)
        }
    }
}

struct ProjectSidebarRow: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let imageURL: URL?
    var assetName: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: 28, assetName: assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected {
            return AppTheme.brandAccent.opacity(0.22)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

struct SidebarGitHubAvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .interpolation(.high)
                            .antialiased(true)
                            .resizable()
                            .scaledToFill()
                    default:
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .padding(7)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(AppTheme.contentSubtleFill)
        )
        .clipShape(Circle())
    }
}


/// Sidebar bottom bar per Apple HIG — app-level chrome that doesn't fit in the
/// sidebar's toolbar (which would collapse into the overflow chevron). Hosts
/// the Pi Agent chip (primary entry into the Agent screen) on the left and the
/// Settings gear on the right.
struct SidebarBottomBar: View {
    var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            PiAgentSidebarChip(
                isSelected: viewModel.selectedSidebarItem == .agent,
                runningSessionCount: viewModel.piAgentRunningSessionCount,
                needsAttentionCount: viewModel.piAgentNeedsAttentionCount,
                action: { viewModel.openPiAgentScreen() }
            )

            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.medium)
                    .foregroundStyle(AppTheme.mutedText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings…")
            .accessibilityLabel("Settings")
        }
        // Whole-row tap (except over the nested Settings button) opens Pi Agent —
        // expands the click target so users don't have to land on the small chip.
        // Inner Buttons take gesture priority, so Settings still works on its own.
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.openPiAgentScreen()
        }
    }
}

