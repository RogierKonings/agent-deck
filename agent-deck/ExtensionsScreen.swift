import SwiftUI

/// Runtime → Extensions. Controls whether the user's own Pi extensions load into
/// Agent Deck sessions, with a deselectable checklist and tool-name conflict
/// warnings. Discovery runs OFF the main thread and is cached in `@State`; the
/// SwiftUI body never performs filesystem I/O.
struct ExtensionsScreen: View {
    var viewModel: AppViewModel

    /// Discovered Pi extension candidates, loaded off-main and cached. Never read
    /// via a body-time `discover()` call.
    @State private var candidates: [PiExtensionCandidate] = []
    /// Bridge tool-name overlaps per candidate id, computed off-main.
    @State private var conflictsByID: [String: [String]] = [:]
    @State private var isDiscovering = false
    /// Whether the local web-fetch fallback dependency is installed (filesystem
    /// check, refreshed off the render path). Drives the "Web fetch" bridge state.
    @State private var webFetchInstalled = false
    /// Bumped by Refresh to force a re-discovery without changing project.
    @State private var refreshToken = 0

    private var mode: PiAgentExtensionLoadingMode {
        viewModel.appSettings.piAgentExtensionLoadingMode
    }

    var body: some View {
        AppPage("Extensions", subtitle: "Which Pi extensions load into your agent sessions") {
            VStack(alignment: .leading, spacing: 20) {
                modeCard
                if mode.usesCustomPiExtensionSelection {
                    selectionCard
                }
                bridgesCard
            }
        }
        // Re-discover on appear, on project switch, and on manual Refresh. Off-main.
        .task(id: "\(viewModel.projectRootURL?.path ?? "")#\(refreshToken)") {
            await discoverCandidates()
        }
        // Re-scan for conflicts whenever the candidate set changes. Off-main.
        .task(id: candidates.map(\.id).joined()) {
            await detectConflicts()
        }
    }

    // MARK: - Mode

    private var modeCard: some View {
        AppCard(title: "Loading mode") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Extension loading mode", selection: modeBinding) {
                    ForEach(PiAgentExtensionLoadingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .appSegmentedPicker()
                .labelsHidden()

                Text(mode.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeBinding: Binding<PiAgentExtensionLoadingMode> {
        Binding(
            get: { viewModel.appSettings.piAgentExtensionLoadingMode },
            set: { viewModel.setPiAgentExtensionLoadingMode($0) }
        )
    }

    // MARK: - Agent Deck bridges (read-only, live state)

    /// The bridges that would actually load right now, evaluated against current
    /// settings + environment (mirrors `PiNativeSubagentBridgeExtensions` /
    /// `PiAgentRunnerService` inject conditions). Reactive to settings/env changes.
    private var activeBridgeIDs: Set<String> {
        let exaConfigured = viewModel.snapshot.envKeys.contains {
            $0.key == "EXA_API_KEY" && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return Set(PiNativeSubagentBridgeExtensions.injectedParentBridges(
            memoryEnabled: viewModel.appSettings.agentMemoryEnabled,
            exaConfigured: exaConfigured,
            fallbackWebFetchAvailable: webFetchInstalled,
            subagentsActive: viewModel.appSettings.nativeSubagentsEnabledForNewSessions
        ).map(\.id))
    }

    private var bridgesCard: some View {
        AppCard(title: "Agent Deck bridges") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent Deck's own extensions. They take priority over yours if a tool name clashes. State below reflects your current settings.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                let active = activeBridgeIDs
                VStack(alignment: .leading, spacing: 0) {
                    let bridges = PiNativeSubagentBridgeExtensions.bridgeDescriptors
                    ForEach(Array(bridges.enumerated()), id: \.element.id) { index, bridge in
                        bridgeRow(bridge, isActive: active.contains(bridge.id))
                        if index < bridges.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func bridgeRow(_ bridge: PiNativeSubagentBridgeExtensions.BridgeDescriptor, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(isActive ? AppTheme.brandAccent : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(bridge.displayName)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(bridge.toolNames.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let condition = bridge.condition {
                    Text(condition)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            AppLabelTag(text: isActive ? "Active" : "Off", color: isActive ? .green : .secondary)
        }
        .padding(.vertical, 12)
        .opacity(isActive ? 1 : 0.55)
    }

    // MARK: - User extension checklist

    private var selectionCard: some View {
        AppCard(title: "Your Pi extensions", trailing: { selectionToolbar }) {
            if candidates.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { candidate in
                        PiExtensionSelectionRow(
                            candidate: candidate,
                            isEnabled: Binding(
                                get: { !viewModel.appSettings.disabledPiExtensionIDs.contains(candidate.id) },
                                set: { viewModel.setPiExtension(candidate, enabled: $0) }
                            ),
                            conflictingToolNames: conflictsByID[candidate.id] ?? []
                        )
                    }
                }
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Text("\(enabledCount) of \(candidates.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("All") { viewModel.setAllPiExtensions(candidates, enabled: true) }
                .appSecondaryButton()
                .disabled(candidates.isEmpty || enabledCount == candidates.count)
            Button("None") { viewModel.setAllPiExtensions(candidates, enabled: false) }
                .appSecondaryButton()
                .disabled(candidates.isEmpty || enabledCount == 0)
            Button { refreshToken &+= 1 } label: {
                Image(systemName: "arrow.clockwise")
            }
            .appSecondaryButton()
            .disabled(isDiscovering)
        }
    }

    private var enabledCount: Int {
        candidates.filter { !viewModel.appSettings.disabledPiExtensionIDs.contains($0.id) }.count
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isDiscovering ? "Looking for Pi extensions…" : "No Pi extensions were discovered.")
                .font(.subheadline.weight(.semibold))
            Text("Agent Deck looks in ~/.pi/agent/extensions, the selected project's .pi/extensions folder, settings.json extension paths, and installed package extension directories.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Off-main loading

    private func discoverCandidates() async {
        let root = viewModel.projectRootURL
        // Cheap 2-file check; refreshed here rather than in the render path.
        webFetchInstalled = WebFetchDependencyService().status().isInstalled
        isDiscovering = true
        let found = await Task.detached(priority: .utility) {
            PiExtensionDiscoveryService().discover(projectRoot: root)
        }.value
        candidates = found
        // Drop deselection state for extensions that no longer exist.
        viewModel.prunePiExtensionSelection(to: found)
        isDiscovering = false
    }

    private func detectConflicts() async {
        let snapshot = candidates
        let detected = await Task.detached(priority: .utility) {
            var result: [String: [String]] = [:]
            for candidate in snapshot {
                let conflicts = PiExtensionConflictDetector.conflictingBridgeToolNames(for: candidate)
                if !conflicts.isEmpty {
                    result[candidate.id] = conflicts
                }
            }
            return result
        }.value
        conflictsByID = detected
    }
}

// MARK: - Rows

private struct PiExtensionSelectionRow: View {
    let candidate: PiExtensionCandidate
    @Binding var isEnabled: Bool
    /// Bridge tool names detected in this extension's source that overlap with
    /// Agent Deck's built-in bridges. Empty means no detected conflict.
    var conflictingToolNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        PiExtensionScopeBadge(candidate: candidate)
                    }
                    HStack(spacing: 5) {
                        Text(candidate.detailLabel)
                        Text("•")
                        Text(candidate.launchSource)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .appCheckbox()

            if isEnabled && !conflictingToolNames.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(conflictWarningText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    private var conflictWarningText: String {
        let names = conflictingToolNames.joined(separator: ", ")
        let plural = conflictingToolNames.count == 1 ? "Tool" : "Tools"
        let verb = conflictingToolNames.count == 1 ? "is" : "are"
        return "\(plural) \(names) \(verb) also provided by an Agent Deck bridge. Agent Deck loads its bridge first, so the bridge takes precedence and this extension's version may be shadowed."
    }
}

private struct PiExtensionScopeBadge: View {
    let candidate: PiExtensionCandidate

    var body: some View {
        Label(candidate.scopeLabel, systemImage: iconName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private var iconName: String {
        switch candidate.source.kind {
        case .project, .legacyProject:
            return "folder"
        case .package:
            return "shippingbox"
        default:
            return "globe"
        }
    }

    private var color: Color {
        switch candidate.source.kind {
        case .project, .legacyProject:
            return .cyan
        case .package:
            return .purple
        default:
            return .blue
        }
    }
}
