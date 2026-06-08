import Foundation
import Observation

@MainActor
@Observable
final class AgentUniverseCoordinator {
    weak var host: AgentUniverseHost?

    @ObservationIgnored private var cacheByProjectPath: [String: [EffectiveAgentRecord]] = [:]

    func attach(host: AgentUniverseHost) {
        self.host = host
    }

    func clearCache() {
        cacheByProjectPath.removeAll(keepingCapacity: true)
    }

    /// Resolves the `EffectiveAgentRecord` an agent-bound session was created
    /// against. Looks up the session's `agentName` in the session's project
    /// snapshot first (so a project override wins), then falls back to the
    /// global snapshot and finally the cross-project union returned by
    /// `selectableAgentUniverse`. Returns `nil` when the agent is no longer
    /// present anywhere — the runner surfaces this as an "Agent Unavailable"
    /// transcript error.
    func boundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        guard session.isAgentBound, let name = session.agentName else { return nil }
        if let scoped = host?.projectEffectiveAgents(forProjectPath: session.projectPath)?.first(where: { $0.name == name }) {
            return scoped
        }
        if let global = host?.globalEffectiveAgents.first(where: { $0.name == name }) {
            return global
        }
        return selectableAgentUniverse(forProjectPath: session.projectPath).first { $0.name == name }
    }

    /// Skill argument list (`--skill <name=path>` pairs) for a 1:1 agent chat.
    /// Reuses the subagent runner's resolver so the agent sees the same skill
    /// universe it would as a delegated child.
    func boundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        let projectRoot = agent.projectRoot ?? host?.selectedSnapshotProjectRoot ?? ""
        let snap = host?.startupSnapshot(forProjectPath: projectRoot) ?? .empty
        return try PiSkillLaunchResolver.childSkillArguments(agent: agent, snapshot: snap)
    }

    /// Every agent a session could pick for its subagent catalog: the
    /// project-effective agents plus catalog-only and library agents not
    /// otherwise assigned. Parameterized by project path so it resolves for
    /// any session, not only the currently selected project.
    ///
    /// Results are memoized per project path; the cache is cleared via
    /// `clearCache()` whenever any underlying snapshot publishes, so callers
    /// can read this on every `body` evaluation without rebuilding the catalog
    /// walk each time.
    func selectableAgentUniverse(forProjectPath path: String) -> [EffectiveAgentRecord] {
        if let cached = cacheByProjectPath[path] {
            return cached
        }
        guard let host else { return [] }
        let snap = host.startupSnapshot(forProjectPath: path)
        let effective = snap.effectiveAgents
        let effectivePaths = Set(effective.compactMap(\.sourcePath).map(standardizedPath))
        let catalogOnly = agentCatalog(forProjectPath: path)
            .filter { $0.source.kind != .builtin && $0.source.kind != .library }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .map { catalogDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let effectiveNames = Set(effective.map(\.name))
        let libraryOnly = snap.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let result = effective + catalogOnly + libraryOnly
        cacheByProjectPath[path] = result
        return result
    }

    /// The exact, deduplicated set of subagents advertised to — and delegable
    /// by — a session. Single source of truth shared by the catalog prompt,
    /// the delegation lookups, and the session resources popover. A `nil`
    /// `agentSelection` keeps the historical default of all effective agents;
    /// an explicit selection is resolved against the full universe so an agent
    /// not assigned to the project can still be included.
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord] {
        let agents: [EffectiveAgentRecord]
        if let selection = session.agentSelection {
            agents = selectableAgentUniverse(forProjectPath: session.projectPath)
                .filter { selection.contains($0.name) }
        } else {
            agents = host?.startupSnapshot(forProjectPath: session.projectPath).effectiveAgents ?? []
        }
        var seen = Set<String>()
        return agents.filter { $0.resolved.disabled != true && seen.insert($0.name).inserted }
    }

    /// Whether a session has any non-disabled agent it could run as a subagent.
    /// Fast path: a usable effective agent (builtins normally qualify) returns
    /// immediately, so the cross-project catalog scan only runs in the rare
    /// case where the project has no usable effective agents at all.
    func sessionHasSelectableAgents(_ session: PiAgentSessionRecord) -> Bool {
        if host?.startupSnapshot(forProjectPath: session.projectPath)
            .effectiveAgents.contains(where: { $0.resolved.disabled != true }) == true {
            return true
        }
        return selectableAgentUniverse(forProjectPath: session.projectPath)
            .contains { $0.resolved.disabled != true }
    }

    func catalogDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "catalog::\(record.source.kind.rawValue)::\(record.filePath)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record.source.kind == .global ? record : nil,
            projectCustom: record.source.kind == .project || record.source.kind == .legacyProject ? record : nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: record.source.kind == .global ? .globalCustom : .projectCustom
        )
    }

    func libraryDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "library::\(record.name)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: .library
        )
    }

    func agentCatalog(forProjectPath projectPath: String?) -> [AgentRecord] {
        guard let host else { return [] }
        var records = host.globalSnapshot.globalAgents + host.globalSnapshot.libraryAgents
        for projectSnapshot in host.allProjectSnapshots.values {
            records += projectSnapshot.projectAgents + projectSnapshot.legacyProjectAgents + projectSnapshot.libraryAgents
        }
        if host.selectedProjectPath == projectPath {
            records += host.snapshot.projectAgents + host.snapshot.legacyProjectAgents + host.snapshot.libraryAgents
        }
        return deduplicateByID(records)
    }

    func agentCatalog(globalSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> [AgentRecord] {
        deduplicateByID(
            globalSnapshot.globalAgents +
            globalSnapshot.libraryAgents +
            catalogProjectSnapshots.flatMap { $0.projectAgents + $0.legacyProjectAgents + $0.libraryAgents }
        )
    }

    /// The actual merge+sort. Called only from `resourceCatalog.rebuildWarningCaches()`.
    func computeAllDisplayAgents() -> [EffectiveAgentRecord] {
        guard let host else { return [] }
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in host.snapshot.effectiveAgents { byID[agent.id] = agent }
        for agent in catalogOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in libraryOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in projectAssignedLibraryAgentsForAggregateView { byID[agent.id] = agent }
        return Array(byID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func filteredAgents() -> [EffectiveAgentRecord] {
        guard let host else { return [] }
        return host.cachedAllDisplayAgents.filter { agent in
            switch host.selectedAgentFilter {
            case .all:
                return true
            case .builtin:
                return agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            case .global:
                return agent.globalCustom?.source.kind == .global
            case .project:
                return agent.projectCustom != nil
            case .overriddenBuiltins:
                return agent.builtin != nil && (agent.userOverride != nil || agent.projectOverride != nil)
            case .replacedBuiltins:
                return agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil)
            case .customOnly:
                return agent.globalCustom != nil || agent.projectCustom != nil
            case .disabled:
                return agent.resolved.disabled == true
            case .needsAttention:
                return !host.agentWarnings(for: agent).isEmpty
            }
        }
    }

    func allVisibleAgentRecords() -> [AgentRecord] {
        agentCatalog(forProjectPath: host?.selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var catalogOnlyEffectiveAgents: [EffectiveAgentRecord] {
        guard let host else { return [] }
        let effectivePaths = Set(host.snapshot.effectiveAgents.compactMap(\.sourcePath).map(standardizedPath))
        return agentCatalog(forProjectPath: host.selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .filter { $0.source.kind != .library }
            .map { catalogDisplayAgent(from: $0, projectRoot: host.snapshot.projectRoot) }
    }

    private var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        guard let host else { return [] }
        let agentsThatHideLibrary = host.snapshot.projectRoot == nil
            ? host.snapshot.effectiveAgents.filter { $0.projectCustom == nil && $0.projectOverride == nil }
            : host.snapshot.effectiveAgents
        let effectiveNames = Set(agentsThatHideLibrary.map(\.name))
        return host.snapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: host.snapshot.projectRoot) }
    }

    private var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        guard let host, host.snapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(host.snapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: host.snapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(host.projectPreferencesByPath.values.flatMap(\.assignedAgentNames))
        let libraryNames = Set(host.snapshot.libraryAgents.map(\.name))
        return assignedNames
            .filter { !effectiveNames.contains($0) && libraryNames.contains($0) }
            .compactMap { libraryByName[$0] }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }
}
