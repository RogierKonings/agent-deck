import Foundation

// MARK: - Optimistic settings override patches

extension AppViewModel {
    func patchDisableBuiltins(_ isDisabled: Bool?, scope: AgentEditingTarget.OverrideScope) {
        guard let targetPath = settingsJSONPath(for: scope, projectRoot: selectedProjectPath) else { return }
        patchSettings(at: targetPath) { summary in
            SettingsSummary(
                path: summary.path,
                packages: summary.packages,
                prompts: summary.prompts,
                disableBuiltins: isDisabled,
                agentOverrides: summary.agentOverrides
            )
        }
        reconcileSnapshotsFromPreferences()
    }

    func patchBuiltinOverrideRecord(
        agentName: String,
        scope: AgentEditingTarget.OverrideScope,
        overrideValues: [String: Any]?,
        explicitProjectRoot: String? = nil
    ) {
        guard let targetPath = settingsJSONPath(for: scope, projectRoot: explicitProjectRoot ?? selectedProjectPath) else { return }

        patchSettings(at: targetPath) { summary in
            var overrides = summary.agentOverrides
            if let overrideValues, !overrideValues.isEmpty {
                let jsonValues = overrideValues.compactMapValues { JSONValue.fromFoundation($0) }
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    overrides[idx] = BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: jsonValues
                    )
                } else {
                    overrides.append(BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: jsonValues
                    ))
                    overrides.sort { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }
                }
            } else if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                overrides.remove(at: idx)
            }

            return SettingsSummary(
                path: summary.path,
                packages: summary.packages,
                prompts: summary.prompts,
                disableBuiltins: summary.disableBuiltins,
                agentOverrides: overrides
            )
        }
        reconcileSnapshotsFromPreferences()
    }

    private func settingsJSONPath(for scope: AgentEditingTarget.OverrideScope, projectRoot: String?) -> String? {
        switch scope {
        case .global:
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        case .project:
            guard let projectRoot else { return nil }
            return URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path
        }
    }

    private func patchSettings(at targetPath: String, transform: (SettingsSummary) -> SettingsSummary) {
        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            var updatedSettings = snap.settings
            if let idx = updatedSettings.firstIndex(where: { $0.path == targetPath }) {
                updatedSettings[idx] = transform(updatedSettings[idx])
            } else {
                updatedSettings.append(transform(SettingsSummary(
                    path: targetPath,
                    packages: [],
                    prompts: [],
                    disableBuiltins: nil,
                    agentOverrides: []
                )))
            }
            return snapshotReplacingSettings(snap, settings: updatedSettings)
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    private func snapshotReplacingSettings(_ snap: ScanSnapshot, settings: [SettingsSummary]) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: snap.projectRoot,
            builtinAgents: snap.builtinAgents,
            globalAgents: snap.globalAgents,
            projectAgents: snap.projectAgents,
            legacyProjectAgents: snap.legacyProjectAgents,
            effectiveAgents: snap.effectiveAgents,
            libraryAgents: snap.libraryAgents,
            skills: snap.skills,
            librarySkills: snap.librarySkills,
            promptTemplates: snap.promptTemplates,
            libraryPromptTemplates: snap.libraryPromptTemplates,
            settings: settings,
            envKeys: snap.envKeys,
            warnings: snap.warnings
        )
    }
}
