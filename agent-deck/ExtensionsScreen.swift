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
    /// Short description per candidate id (extension's leading comment), computed off-main.
    @State private var descriptionsByID: [String: String] = [:]
    @State private var isDiscovering = false
    /// Whether the local web-fetch fallback dependency is installed (filesystem
    /// check, refreshed off the render path). Drives the "Web fetch" bridge state.
    @State private var webFetchInstalled = false

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
        // Re-discover on appear, on project switch, and on toolbar Refresh. Off-main.
        .task(id: "\(viewModel.projectRootURL?.path ?? "")#\(viewModel.piExtensionsRefreshToken)") {
            await discoverCandidates()
        }
        // Re-scan conflicts + descriptions whenever the candidate set changes. Off-main.
        .task(id: candidates.map(\.id).joined()) {
            await loadRowMetadata()
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
            VStack(alignment: .leading, spacing: 5) {
                Text(bridge.displayName)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(bridge.summary)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bridge.toolNames.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let condition = bridge.condition {
                    Text(condition)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        PiExtensionSelectionRow(
                            candidate: candidate,
                            isEnabled: Binding(
                                get: { !viewModel.appSettings.disabledPiExtensionIDs.contains(candidate.id) },
                                set: { viewModel.setPiExtension(candidate, enabled: $0) }
                            ),
                            description: descriptionsByID[candidate.id],
                            conflictingToolNames: conflictsByID[candidate.id] ?? []
                        )
                        if index < candidates.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Button("All") { viewModel.setAllPiExtensions(candidates, enabled: true) }
                .controlSize(.small)
                .disabled(candidates.isEmpty || enabledCount == candidates.count)
            Button("None") { viewModel.setAllPiExtensions(candidates, enabled: false) }
                .controlSize(.small)
                .disabled(candidates.isEmpty || enabledCount == 0)
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
                .foregroundStyle(AppTheme.mutedText)
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

    private func loadRowMetadata() async {
        let snapshot = candidates
        let meta = await Task.detached(priority: .utility) { () -> (conflicts: [String: [String]], descriptions: [String: String]) in
            var conflicts: [String: [String]] = [:]
            var descriptions: [String: String] = [:]
            for candidate in snapshot {
                let found = PiExtensionConflictDetector.conflictingBridgeToolNames(for: candidate)
                if !found.isEmpty { conflicts[candidate.id] = found }
                if let description = PiExtensionDescriptionReader.leadingDescription(forFile: candidate.launchSource) {
                    descriptions[candidate.id] = description
                }
            }
            return (conflicts, descriptions)
        }.value
        conflictsByID = meta.conflicts
        descriptionsByID = meta.descriptions
    }
}

// MARK: - Rows

private struct PiExtensionSelectionRow: View {
    let candidate: PiExtensionCandidate
    @Binding var isEnabled: Bool
    /// Short description from the extension's leading comment, if any.
    var description: String?
    /// Bridge tool names detected in this extension's source that overlap with
    /// Agent Deck's built-in bridges. Empty means no detected conflict.
    var conflictingToolNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.body.weight(.semibold))
                        .fontWidth(.expanded)
                        .lineLimit(1)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        .padding(.vertical, 10)
        .help(candidate.launchSource)
    }

    private var conflictWarningText: String {
        let names = conflictingToolNames.joined(separator: ", ")
        let plural = conflictingToolNames.count == 1 ? "Tool" : "Tools"
        let verb = conflictingToolNames.count == 1 ? "is" : "are"
        return "\(plural) \(names) \(verb) also provided by an Agent Deck bridge. Agent Deck loads its bridge first, so the bridge takes precedence and this extension's version may be shadowed."
    }
}
