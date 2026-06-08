import Foundation
import Observation

@MainActor
@Observable
final class ResourceCatalogCoordinator {
    weak var host: ResourceCatalogHost?

    private(set) var hasCompletedInitialRefresh = false
    private(set) var hasAgentWarnings = false
    private(set) var hasSkillWarnings = false
    private(set) var hasPromptWarnings = false
    private(set) var skillWarnings: [DiagnosticWarning] = []
    private(set) var promptWarnings: [DiagnosticWarning] = []
    private(set) var skillReferenceWarnings: [SkillReferenceWarning] = []
    private(set) var skillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
    private(set) var allDisplayAgents: [EffectiveAgentRecord] = []
    private(set) var displayAgentByID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
    private(set) var displayAgentsRevision: Int = 0
    private(set) var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
    private(set) var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
    private(set) var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]

    func attach(host: ResourceCatalogHost) {
        self.host = host
    }

    func rebuildWarningCaches(markInitialRefreshComplete: Bool = false) {
        guard let host else { return }
        let allDisplayAgents = host.computeAllDisplayAgents()
        let skillWarnings = buildSkillWarnings()
        let promptWarnings = buildPromptWarnings()
        let visibilityIssuesByAgentID = buildSkillVisibilityIssuesByAgentID()
        let filteredAgents = host.catalogFilteredAgents()
        let agentNamesByID = Dictionary(uniqueKeysWithValues: filteredAgents.map { ($0.id, $0.name) })
        let skillReferenceWarnings: [SkillReferenceWarning] = visibilityIssuesByAgentID
            .flatMap { pair -> [SkillReferenceWarning] in
                guard let agentName = agentNamesByID[pair.key] else { return [] }
                return pair.value.flatMap { issue in
                    issue.missingSkills.map { missingSkill in
                        SkillReferenceWarning(agentName: agentName, project: issue.project, missingSkill: missingSkill)
                    }
                }
            }
            .sorted(by: {
                if $0.missingSkill != $1.missingSkill { return $0.missingSkill < $1.missingSkill }
                if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
                return $0.project.name < $1.project.name
            })

        var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
        for agent in filteredAgents {
            agentWarningsByID[agent.id] = computeWarnings(for: agent)
        }

        var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
        var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
        let activeProject = host.selectedDiscoveredProject
        for record in host.allVisibleSkillRecords {
            let matchingWarnings = skillWarnings.filter { warning in
                warning.id == "duplicate-skill:\(record.name)" ||
                warning.id.contains(record.filePath) ||
                warning.message.contains("`\(record.name)`") ||
                warning.message.contains(record.filePath)
            }
            let hasWarnings = !matchingWarnings.isEmpty
            warningsBySkillID[record.id] = matchingWarnings
            let globallyEnabled = host.skillIsEnabledGlobally(record)
            let isAssigned = globallyEnabled ||
                !host.assignedProjects(for: record).isEmpty ||
                !host.assignedAgents(for: record).isEmpty
            let isActive = globallyEnabled ||
                (activeProject.map { host.skill(record, isEnabledFor: $0) } ?? false)
            skillMetadataByID[record.id] = SkillListMetadata(
                isAssigned: isAssigned,
                hasWarnings: hasWarnings,
                isActiveForCurrentProject: isActive
            )
        }

        applyRebuild(
            allDisplayAgents: allDisplayAgents,
            skillWarnings: skillWarnings,
            promptWarnings: promptWarnings,
            skillVisibilityIssuesByAgentID: visibilityIssuesByAgentID,
            skillReferenceWarnings: skillReferenceWarnings,
            agentWarningsByID: agentWarningsByID,
            skillMetadataByID: skillMetadataByID,
            warningsBySkillID: warningsBySkillID,
            markInitialRefreshComplete: markInitialRefreshComplete
        )
    }

    func warnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        if let cached = agentWarningsByID[agent.id] { return cached }
        return computeWarnings(for: agent)
    }

    private func applyRebuild(
        allDisplayAgents: [EffectiveAgentRecord],
        skillWarnings: [DiagnosticWarning],
        promptWarnings: [DiagnosticWarning],
        skillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]],
        skillReferenceWarnings: [SkillReferenceWarning],
        agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]],
        skillMetadataByID: [SkillRecord.ID: SkillListMetadata],
        warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]],
        markInitialRefreshComplete: Bool
    ) {
        self.allDisplayAgents = allDisplayAgents
        displayAgentByID = Dictionary(uniqueKeysWithValues: allDisplayAgents.map { ($0.id, $0) })
        displayAgentsRevision &+= 1
        self.skillWarnings = skillWarnings
        self.promptWarnings = promptWarnings
        self.skillVisibilityIssuesByAgentID = skillVisibilityIssuesByAgentID
        self.skillReferenceWarnings = skillReferenceWarnings
        self.agentWarningsByID = agentWarningsByID
        self.skillMetadataByID = skillMetadataByID
        self.warningsBySkillID = warningsBySkillID
        hasSkillWarnings = !skillReferenceWarnings.isEmpty || !skillWarnings.isEmpty
        hasPromptWarnings = !promptWarnings.isEmpty
        hasAgentWarnings = agentWarningsByID.values.contains { !$0.isEmpty }
            || skillVisibilityIssuesByAgentID.values.contains { !$0.isEmpty }
        if markInitialRefreshComplete {
            hasCompletedInitialRefresh = true
        }
    }

    private func buildSkillWarnings() -> [DiagnosticWarning] {
        guard let host else { return [] }
        let baseWarnings = host.snapshot.warnings.filter { warning in
            warning.id.hasPrefix("malformed-skill:") || warning.message.localizedCaseInsensitiveContains("skill")
        }
        let collisionWarnings = PiSkillLaunchResolver.collisions(in: host.allVisibleSkillRecords).map { collision in
            let paths = collision.skills.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-skill:\(collision.name)", message: "Duplicate skill name `\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildPromptWarnings() -> [DiagnosticWarning] {
        guard let host else { return [] }
        let baseWarnings = host.snapshot.warnings.filter { warning in
            warning.id.hasPrefix("duplicate-prompt:")
        }
        let collisionWarnings = PiPromptTemplateLaunchResolver.collisions(in: host.allVisiblePromptTemplateRecords).map { collision in
            let paths = collision.prompts.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-prompt-template:\(collision.name)", message: "Duplicate prompt template name `/\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildSkillVisibilityIssuesByAgentID() -> [String: [AgentSkillVisibilityIssue]] {
        guard let host else { return [:] }
        var issuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
        for agent in host.catalogFilteredAgents() {
            guard !agent.resolved.skills.isEmpty else { continue }
            let explicitSkills = agent.resolved.skills
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !explicitSkills.isEmpty else { continue }

            let managedRecord = host.snapshot.libraryAgents.first { $0.name == agent.name }
                ?? agent.globalCustom
                ?? agent.projectCustom
            guard let managedRecord else { continue }

            let issues: [AgentSkillVisibilityIssue] = host.assignedProjects(for: managedRecord).compactMap { project in
                guard let projectSnapshot = host.allProjectSnapshots[project.path] else { return nil }
                let visibleSkillNames = Set(PiSkillLaunchResolver.catalog(from: projectSnapshot).map(\.name))
                let missingSkills = explicitSkills.filter { !visibleSkillNames.contains($0) }
                guard !missingSkills.isEmpty else { return nil }
                return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
            }
            if !issues.isEmpty {
                issuesByAgentID[agent.id] = issues
            }
        }
        return issuesByAgentID
    }

    private func computeWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        guard let host else { return [] }
        return host.snapshot.warnings.filter { warning in
            warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
    }
}
