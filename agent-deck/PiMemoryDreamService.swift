import Foundation

struct PiMemoryDreamService {
    func propose(memories: [AgentMemoryRecord], progress: @escaping @MainActor (String) -> Void = { _ in }) async -> PiMemoryDreamCycleResult {
        let started = Date()
        await progress("Loading current memories…")
        let current = memories.filter { $0.isInjectable }
        await progress("Clustering \(current.count) memories…")

        var proposals: [PiMemoryDreamProposal] = []
        let groups = Dictionary(grouping: current) { record in
            normalizedKey(record.title)
        }.values.filter { $0.count >= 2 }
        for group in groups.prefix(6) {
            let sorted = group.sorted { $0.effectiveWeight > $1.effectiveWeight }
            let title = sorted.first?.title ?? "Merged memory"
            let content = sorted.map { "- \($0.title): \($0.summary)" }.joined(separator: "\n")
            proposals.append(PiMemoryDreamProposal(
                id: UUID().uuidString,
                action: .merge,
                sourceMemoryIDs: sorted.map(\.id),
                title: title,
                content: content,
                reasoning: "Dream cycle found multiple current memories with the same normalized title/topic.",
                tags: Array(Set(sorted.flatMap(\.tags))).sorted(),
                weight: min(1.0, max(0.7, sorted.map(\.weight).max() ?? 0.7)),
                type: sorted.first?.kind ?? .insight,
                weightChanges: [:]
            ))
        }

        await progress("Reviewing weights…")
        let reweights = Dictionary(uniqueKeysWithValues: current.filter { $0.useCount >= 2 && $0.weight < 0.9 }.prefix(8).map { record in
            (record.id, min(1.0, record.weight + 0.1))
        })
        if !reweights.isEmpty {
            proposals.append(PiMemoryDreamProposal(
                id: UUID().uuidString,
                action: .reweight,
                sourceMemoryIDs: Array(reweights.keys),
                title: "Rebalance frequently used memories",
                content: "Increase weights for memories repeatedly reinforced or recalled.",
                reasoning: "Canonical effective weight includes access boosts; this proposal persists a small base-weight increase for repeatedly useful memories.",
                tags: ["dream-cycle", "reweight"],
                weight: nil,
                type: nil,
                weightChanges: reweights
            ))
        }

        await progress("Looking for patterns…")
        let tagGroups = Dictionary(grouping: current.flatMap { record in record.tags.map { ($0, record) } }, by: { $0.0 })
        if let cluster = tagGroups.values.first(where: { $0.count >= 3 }) {
            let source = Array(cluster.map(\.1).prefix(6))
            proposals.append(PiMemoryDreamProposal(
                id: UUID().uuidString,
                action: .discoverPattern,
                sourceMemoryIDs: source.map(\.id),
                title: "Pattern: \(cluster[0].0)",
                content: source.map { "- \($0.title)" }.joined(separator: "\n"),
                reasoning: "Dream cycle found a repeated tag across current memories.",
                tags: ["dream-pattern", cluster[0].0],
                weight: 0.7,
                type: .insight,
                weightChanges: [:]
            ))
        }

        await progress(proposals.isEmpty ? "No useful mutations found." : "Prepared \(proposals.count) proposal(s).")
        return PiMemoryDreamCycleResult(
            id: UUID().uuidString,
            startedAt: started,
            finishedAt: Date(),
            trigger: "manual",
            phase: "native-deterministic",
            clustersReviewed: groups.count,
            memoriesMerged: proposals.filter { $0.action == .merge }.count,
            schemasCreated: proposals.filter { $0.action == .synthesize }.count,
            weightsAdjusted: reweights.count,
            contradictionsFound: proposals.filter { $0.action == .flagContradiction }.count,
            patternsDiscovered: proposals.filter { $0.action == .discoverPattern }.count,
            proposals: proposals
        )
    }

    private func normalizedKey(_ value: String) -> String {
        let pieces = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        return pieces.prefix(5).joined(separator: "-")
    }
}
