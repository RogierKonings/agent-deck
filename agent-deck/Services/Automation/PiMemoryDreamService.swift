import Foundation

protocol PiMemoryDreamReviewing: Sendable {
    func reviewClusterForMerge(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal]
    func synthesizeCluster(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal]
    func rebalanceWeights(candidates: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal]
    func scanContradictions(facts: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal]
    func discoverTemporalPatterns(events: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal]
}

struct PiMemoryDreamService {
    enum DreamError: LocalizedError {
        case noReviewer
        var errorDescription: String? { "Dream requires a native reviewer/model. No reviewer was configured." }
    }

    var reviewer: PiMemoryDreamReviewing

    init(reviewer: PiMemoryDreamReviewing) {
        self.reviewer = reviewer
    }

    func propose(memories: [AgentMemoryRecord], progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> PiMemoryDreamCycleResult {
        let started = Date()
        let current = memories.filter { $0.isInjectable }
        await reportProgress("Loading \(current.count) current memories…", using: progress)

        let clusters = Self.semanticClusters(current, threshold: 0.55, maxClusters: 15, minClusterSize: 2)
        var proposals: [PiMemoryDreamProposal] = []
        var clustersReviewed = 0

        for cluster in clusters {
            clustersReviewed += 1
            await reportProgress("Reviewing cluster \(clustersReviewed)/\(clusters.count)…", using: progress)
            let mergeActions = try await reviewer.reviewClusterForMerge(cluster: cluster)
            proposals.append(contentsOf: mergeActions)
            let didMerge = mergeActions.contains { $0.action == .merge }
            if !didMerge {
                proposals.append(contentsOf: try await reviewer.synthesizeCluster(cluster: cluster))
            }
        }

        await reportProgress("Rebalancing memory weights…", using: progress)
        proposals.append(contentsOf: try await reviewer.rebalanceWeights(candidates: Self.weightCandidates(current)))

        await reportProgress("Scanning fact contradictions…", using: progress)
        proposals.append(contentsOf: try await reviewer.scanContradictions(facts: current.filter { $0.kind == .fact }))

        await reportProgress("Discovering temporal event patterns…", using: progress)
        proposals.append(contentsOf: try await reviewer.discoverTemporalPatterns(events: current.filter { $0.kind == .event }))

        if proposals.isEmpty {
            proposals.append(PiMemoryDreamProposal(
                id: UUID().uuidString,
                phase: .clusterReview,
                action: .skip,
                sourceMemoryIDs: [],
                title: "No dream mutations proposed",
                content: "Dream reviewed current memories and found no safe consolidation actions.",
                reasoning: "All phases completed without actionable merge, synthesis, reweight, contradiction, or temporal-pattern proposals.",
                tags: ["dream-cycle", "no-op"],
                weight: nil,
                type: nil,
                weightChanges: [:]
            ))
        }

        await reportProgress("Prepared \(proposals.filter { $0.action != .skip }.count) actionable proposal(s).", using: progress)
        return PiMemoryDreamCycleResult(
            id: UUID().uuidString,
            startedAt: started,
            finishedAt: Date(),
            trigger: "manual",
            phase: "full",
            clustersReviewed: clustersReviewed,
            memoriesMerged: proposals.filter { $0.action == .merge }.reduce(0) { $0 + $1.sourceMemoryIDs.count },
            schemasCreated: proposals.filter { $0.action == .synthesize }.count,
            weightsAdjusted: proposals.reduce(0) { total, proposal in total + proposal.weightChanges.count + (proposal.action == .synthesize ? proposal.sourceMemoryIDs.count : 0) },
            contradictionsFound: proposals.filter { $0.action == .flagContradiction }.count,
            patternsDiscovered: proposals.filter { $0.action == .discoverPattern }.count,
            proposals: proposals
        )
    }

    private func reportProgress(
        _ message: String,
        using progress: @escaping @MainActor (String) -> Void
    ) async {
        await MainActor.run { progress(message) }
    }

    static func semanticClusters(_ memories: [AgentMemoryRecord], threshold: Double = 0.55, maxClusters: Int = 15, minClusterSize: Int = 2) -> [[AgentMemoryRecord]] {
        let ordered = memories.sorted {
            if $0.effectiveWeight != $1.effectiveWeight { return $0.effectiveWeight > $1.effectiveWeight }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        var clusters: [[AgentMemoryRecord]] = []

        for memory in ordered {
            var bestIndex: Int?
            var bestScore = 0.0
            for index in clusters.indices {
                let similarities = clusters[index].map { semanticSimilarity(memory, $0) }
                let average = similarities.reduce(0, +) / Double(max(1, similarities.count))
                if average > bestScore {
                    bestScore = average
                    bestIndex = index
                }
            }
            if let bestIndex, bestScore >= threshold {
                clusters[bestIndex].append(memory)
            } else {
                clusters.append([memory])
            }
        }

        return clusters
            .map { $0.sorted { $0.effectiveWeight > $1.effectiveWeight } }
            .filter { $0.count >= minClusterSize }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let lhsWeight = lhs.reduce(0) { $0 + $1.effectiveWeight }
                let rhsWeight = rhs.reduce(0) { $0 + $1.effectiveWeight }
                if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
                return (lhs.first?.title ?? "") < (rhs.first?.title ?? "")
            }
            .prefix(maxClusters)
            .map(Array.init)
    }

    private static func semanticSimilarity(_ lhs: AgentMemoryRecord, _ rhs: AgentMemoryRecord) -> Double {
        let lhsTags = Set(lhs.tags.map { $0.lowercased() })
        let rhsTags = Set(rhs.tags.map { $0.lowercased() })
        let tagUnion = lhsTags.union(rhsTags)
        let tagScore = tagUnion.isEmpty ? 0 : Double(lhsTags.intersection(rhsTags).count) / Double(tagUnion.count)

        let lhsTokens = tokenSet(lhs)
        let rhsTokens = tokenSet(rhs)
        let tokenUnion = lhsTokens.union(rhsTokens)
        let tokenScore = tokenUnion.isEmpty ? 0 : Double(lhsTokens.intersection(rhsTokens).count) / Double(tokenUnion.count)

        let typeScore = lhs.kind == rhs.kind ? 0.1 : 0
        return min(1.0, (tagScore * 0.45) + (tokenScore * 0.45) + typeScore)
    }

    private static func tokenSet(_ memory: AgentMemoryRecord) -> Set<String> {
        let stopwords: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "when", "then", "than", "have", "must", "should", "memory"]
        return Set((memory.title + " " + memory.summary)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) })
    }

    static func weightCandidates(_ memories: [AgentMemoryRecord]) -> [AgentMemoryRecord] {
        memories.filter { memory in
            let ageDays = Date().timeIntervalSince(memory.createdAt) / 86_400
            return (memory.useCount >= 5 && memory.weight < 0.7) || (memory.useCount == 0 && memory.weight >= 0.7 && ageDays > 30)
        }
        .prefix(15)
        .map { $0 }
    }

    static func normalizedTopic(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .prefix(5)
            .joined(separator: "-")
    }
}

struct PiMemoryDreamPromptBuilder {
    static func memoryBlock(_ memories: [AgentMemoryRecord]) -> String {
        memories.enumerated().map { index, memory in
            """
            [\(index + 1)] ID: \(memory.id)
                Title: \(memory.title)
                Type: \(memory.kind.rawValue)
                Weight: \(String(format: "%.2f", memory.weight))
                AccessCount: \(memory.useCount)
                Tags: \(memory.tags.joined(separator: ", "))
                Content: \(memory.summary)
            """
        }.joined(separator: "\n\n")
    }

    static let mergeSystem = """
    You are a memory consolidation agent reviewing clusters of related memories.
    Merge only when memories overlap substantially in content, topic, and intent: near-duplicate wording, the same fact/procedure updated over time, the same lesson restated with minor variations, or multiple memories that clearly want to become one canonical memory. Keep sibling checklist items, distinct examples, separate milestones, and related-but-different lessons separate so schema synthesis can handle them. Return valid JSON only.
    """

    static func mergeUser(cluster: [AgentMemoryRecord]) -> String {
        """
        Response JSON schema:
        {"decision":"merge"|"keep-separate","reasoning":"...","merges":[{"sourceIds":["..."],"title":"...","content":"...","type":"fact|event|procedure|insight","weight":0.3,"tags":["..."]}]}
        When keeping separate, merges must be []. When merging, sourceIds must refer only to IDs below.

        Memories:
        \(memoryBlock(cluster))
        """
    }

    static let synthesisSystem = """
    You are a knowledge synthesis agent. Synthesize when related-but-distinct memories imply a higher-level principle, operational checklist, decision rubric, troubleshooting flow, anti-pattern, or reusable pattern that is more useful than the individual examples. Do not synthesize near-duplicates, heterogeneous clusters, or superficial tag matches. Return valid JSON only.
    """

    static func synthesisUser(cluster: [AgentMemoryRecord]) -> String {
        """
        Response JSON schema:
        {"decision":"synthesize"|"skip","reasoning":"...","synthesis":{"title":"...","content":"...","reasoning":"...","tags":["..."],"type":"fact|event|procedure|insight","weight":0.3}}
        Synthesize only when a reusable principle/checklist/pattern is clearer than the source memories.

        Memories:
        \(memoryBlock(cluster))
        """
    }

    static let weightSystem = """
    You are a memory importance evaluator. Review weights against usage and age. Return JSON only.
    """

    static func weightUser(candidates: [AgentMemoryRecord]) -> String {
        """
        Response JSON array schema:
        [{"id":"memory_id","suggestedWeight":0.3,"reasoning":"..."}]
        Only include entries whose weight should change by at least 0.1.

        Memories:
        \(memoryBlock(candidates))
        """
    }

    static let contradictionSystem = """
    You are a consistency auditor for a personal knowledge base. Identify logical contradictions, direct conflicts, or mutually exclusive claims between factual memories. Return JSON only.
    """

    static func contradictionUser(facts: [AgentMemoryRecord]) -> String {
        """
        Response format — return ONLY a valid JSON array:
        [{"factA":"id1","factB":"id2","description":"why these facts contradict","suggestedResolution":"how to resolve or reconcile them"}]
        factA and factB must be IDs from the facts below. Return [] when there are no likely contradictions.

        Facts:
        \(memoryBlock(facts))
        """
    }

    static let temporalSystem = """
    You are a pattern analyst for a personal event log. Identify recurring themes, trends, or significant chronological patterns across event memories. Return JSON only.
    """

    static func temporalUser(events: [AgentMemoryRecord]) -> String {
        let chronological = events.sorted { $0.createdAt < $1.createdAt }
        return """
        Response format — return ONLY a valid JSON array:
        [{"eventIds":["id1","id2"],"pattern":"concise description of the pattern or trend","suggestedInsight":"actionable or memorable insight derived from this pattern"}]
        eventIds must come from the events below. Return [] when there is no useful temporal pattern.

        Events in chronological order:
        \(memoryBlock(chronological))
        """
    }
}

struct PiMemoryDreamJSONParser {
    static func extractObject(_ raw: String) -> [String: Any]? {
        parseJSON(raw) as? [String: Any]
    }

    static func extractArray(_ raw: String) -> [[String: Any]] {
        parseJSON(raw) as? [[String: Any]] ?? []
    }

    private static func parseJSON(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed, fenced(trimmed), bracketed(trimmed)].compactMap { $0 }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return nil
    }

    private static func fenced(_ raw: String) -> String? {
        guard let range = raw.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) else { return nil }
        var value = String(raw[range])
        value = value.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        return value
    }

    private static func bracketed(_ raw: String) -> String? {
        if let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last { return String(raw[first...last]) }
        if let first = raw.firstIndex(of: "["), let last = raw.lastIndex(of: "]"), first < last { return String(raw[first...last]) }
        return nil
    }

    static func parseMerge(raw: String, cluster: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        guard let obj = extractObject(raw), let decision = obj["decision"] as? String else { return [skip(.clusterReview, cluster, "Could not parse merge reviewer response.", raw)] }
        if decision == "keep-separate" {
            return [skip(.clusterReview, cluster, obj["reasoning"] as? String ?? "Reviewer kept cluster separate.", raw)]
        }
        guard decision == "merge", let merges = obj["merges"] as? [[String: Any]], !merges.isEmpty else {
            return [skip(.clusterReview, cluster, "Reviewer did not return merge entries.", raw)]
        }
        let validIDs = Set(cluster.map(\.id))
        return merges.compactMap { merge in
            let sourceIds = (merge["sourceIds"] as? [String] ?? []).filter { validIDs.contains($0) }
            guard sourceIds.count >= 2 else { return nil }
            return PiMemoryDreamProposal(
                id: UUID().uuidString,
                phase: .clusterReview,
                action: .merge,
                sourceMemoryIDs: sourceIds,
                title: merge["title"] as? String ?? "Merged memory",
                content: merge["content"] as? String ?? "",
                reasoning: obj["reasoning"] as? String ?? "Reviewer recommended merge.",
                tags: merge["tags"] as? [String] ?? [],
                weight: number(merge["weight"]) ?? 0.7,
                type: AgentMemoryKind(rawValue: merge["type"] as? String ?? "insight") ?? .insight,
                weightChanges: [:],
                reviewerRawResponse: raw
            )
        }
    }

    static func parseSynthesis(raw: String, cluster: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        guard let obj = extractObject(raw), let decision = obj["decision"] as? String else { return [skip(.schemaSynthesis, cluster, "Could not parse synthesis reviewer response.", raw)] }
        guard decision == "synthesize", let synthesis = obj["synthesis"] as? [String: Any] else {
            return [skip(.schemaSynthesis, cluster, obj["reasoning"] as? String ?? "Reviewer skipped synthesis.", raw)]
        }
        return [PiMemoryDreamProposal(
            id: UUID().uuidString,
            phase: .schemaSynthesis,
            action: .synthesize,
            sourceMemoryIDs: cluster.map(\.id),
            title: synthesis["title"] as? String ?? "Synthesized memory",
            content: synthesis["content"] as? String ?? "",
            reasoning: synthesis["reasoning"] as? String ?? obj["reasoning"] as? String ?? "Reviewer recommended synthesis.",
            tags: synthesis["tags"] as? [String] ?? [],
            weight: number(synthesis["weight"]) ?? 0.8,
            type: AgentMemoryKind(rawValue: synthesis["type"] as? String ?? "insight") ?? .insight,
            weightChanges: [:],
            reviewerRawResponse: raw
        )]
    }

    static func parseWeights(raw: String, candidates: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let changes = Dictionary(uniqueKeysWithValues: extractArray(raw).compactMap { item -> (String, Double)? in
            guard let id = item["id"] as? String, let record = byID[id] else { return nil }
            let suggested = number(item["suggestedWeight"]) ?? record.weight
            guard abs(suggested - record.weight) >= 0.1 else { return nil }
            return (id, max(0.3, min(1.0, suggested)))
        })
        guard !changes.isEmpty else { return [] }
        return [PiMemoryDreamProposal(id: UUID().uuidString, phase: .weightRebalance, action: .reweight, sourceMemoryIDs: Array(changes.keys), title: "Rebalance memory weights", content: "Adjust memory weights based on reviewer calibration.", reasoning: "Reviewer suggested weight updates for usage/age calibration.", tags: ["dream-cycle", "reweight"], weight: nil, type: nil, weightChanges: changes, reviewerRawResponse: raw)]
    }

    static func parseContradictions(raw: String, facts: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        let valid = Set(facts.map(\.id))
        return extractArray(raw).compactMap { item in
            let canonicalIDs = [item["factA"] as? String, item["factB"] as? String].compactMap { $0 }.filter { valid.contains($0) }
            let compatibilityIDs = (item["ids"] as? [String] ?? []).filter { valid.contains($0) }
            let ids = canonicalIDs.count >= 2 ? canonicalIDs : compatibilityIDs
            guard ids.count >= 2 else { return nil }
            let description = item["description"] as? String ?? item["reasoning"] as? String ?? "Potential contradiction flagged by reviewer."
            let resolution = item["suggestedResolution"] as? String
            let content = [description, resolution].compactMap(nonEmpty).joined(separator: "\nResolution: ")
            return PiMemoryDreamProposal(
                id: UUID().uuidString,
                phase: .contradictionScan,
                action: .flagContradiction,
                sourceMemoryIDs: ids,
                title: item["title"] as? String ?? "Potential memory contradiction",
                content: content.isEmpty ? description : content,
                reasoning: description,
                tags: ["dream-cycle", "contradiction"],
                weight: nil,
                type: nil,
                weightChanges: [:],
                contradictionPairs: [ids],
                reviewerRawResponse: raw
            )
        }
    }

    static func parseTemporal(raw: String, events: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        let patterns: [[String: Any]]
        if let obj = extractObject(raw), let objectPatterns = obj["patterns"] as? [[String: Any]] {
            patterns = objectPatterns
        } else {
            patterns = extractArray(raw)
        }
        let valid = Set(events.map(\.id))
        return patterns.compactMap { pattern in
            let canonicalIDs = (pattern["eventIds"] as? [String] ?? []).filter { valid.contains($0) }
            let compatibilityIDs = (pattern["sourceIds"] as? [String] ?? []).filter { valid.contains($0) }
            let ids = canonicalIDs.isEmpty ? compatibilityIDs : canonicalIDs
            guard !ids.isEmpty else { return nil }
            let patternText = pattern["pattern"] as? String ?? pattern["title"] as? String ?? "Temporal memory pattern"
            let insight = pattern["suggestedInsight"] as? String ?? pattern["content"] as? String ?? patternText
            return PiMemoryDreamProposal(
                id: UUID().uuidString,
                phase: .temporalPatterns,
                action: .discoverPattern,
                sourceMemoryIDs: ids,
                title: patternText,
                content: insight,
                reasoning: pattern["reasoning"] as? String ?? patternText,
                tags: pattern["tags"] as? [String] ?? ["dream-pattern"],
                weight: number(pattern["weight"]) ?? 0.7,
                type: .insight,
                weightChanges: [:],
                reviewerRawResponse: raw
            )
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func skip(_ phase: PiMemoryDreamPhase, _ memories: [AgentMemoryRecord], _ reasoning: String, _ raw: String? = nil) -> PiMemoryDreamProposal {
        PiMemoryDreamProposal(id: UUID().uuidString, phase: phase, action: .skip, sourceMemoryIDs: memories.map(\.id), title: "Skipped \(phase.displayName)", content: reasoning, reasoning: reasoning, tags: ["dream-cycle", "skip"], weight: nil, type: nil, weightChanges: [:], reviewerRawResponse: raw)
    }
}

@MainActor
final class PiMemoryDreamLLMReviewer: PiMemoryDreamReviewing {
    enum ReviewError: LocalizedError { case emptyResponse, timedOut, processExited(Int32), rpc(String) }

    private let model: AvailableModel
    private let projectURL: URL
    private let environment: [String: String]
    private let timeoutNanoseconds: UInt64 = 45_000_000_000

    init(model: AvailableModel, projectURL: URL, environment: [String: String]) {
        self.model = model
        self.projectURL = projectURL
        self.environment = environment
    }

    func reviewClusterForMerge(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard cluster.count >= 2 else { return [PiMemoryDreamJSONParser.skip(.clusterReview, cluster, "Single-memory cluster.")] }
        let raw = try await complete(system: PiMemoryDreamPromptBuilder.mergeSystem, user: PiMemoryDreamPromptBuilder.mergeUser(cluster: cluster))
        return PiMemoryDreamJSONParser.parseMerge(raw: raw, cluster: cluster)
    }

    func synthesizeCluster(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard cluster.count >= 2 else { return [] }
        let raw = try await complete(system: PiMemoryDreamPromptBuilder.synthesisSystem, user: PiMemoryDreamPromptBuilder.synthesisUser(cluster: cluster))
        return PiMemoryDreamJSONParser.parseSynthesis(raw: raw, cluster: cluster)
    }

    func rebalanceWeights(candidates: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard !candidates.isEmpty else { return [] }
        let raw = try await complete(system: PiMemoryDreamPromptBuilder.weightSystem, user: PiMemoryDreamPromptBuilder.weightUser(candidates: candidates))
        return PiMemoryDreamJSONParser.parseWeights(raw: raw, candidates: candidates)
    }

    func scanContradictions(facts: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard facts.count >= 2 else { return [] }
        let raw = try await complete(system: PiMemoryDreamPromptBuilder.contradictionSystem, user: PiMemoryDreamPromptBuilder.contradictionUser(facts: facts))
        return PiMemoryDreamJSONParser.parseContradictions(raw: raw, facts: facts)
    }

    func discoverTemporalPatterns(events: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard events.count >= 2 else { return [] }
        let raw = try await complete(system: PiMemoryDreamPromptBuilder.temporalSystem, user: PiMemoryDreamPromptBuilder.temporalUser(events: events))
        return PiMemoryDreamJSONParser.parseTemporal(raw: raw, events: events)
    }

    private func complete(system: String, user: String) async throws -> String {
        if FoundationModelAutomationService.isFoundationModel(model) {
            return try await FoundationModelAutomationService.generateOneShot(prompt: user, systemPrompt: system, temperature: 0.2, maxTokens: 2_000)
        }
        return try await withCheckedThrowingContinuation { continuation in
            startPiHelper(system: system, user: user) { result in continuation.resume(with: result) }
        }
    }

    private func startPiHelper(system: String, user: String, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        do {
            nonisolated(unsafe) var assistantText = ""
            nonisolated(unsafe) var didFinish = false
            nonisolated(unsafe) var client: PiRPCClient?
            client = try PiRPCClient(
                cwd: projectURL,
                provider: model.provider,
                modelArgument: PiSessionTitleGenerationService.runtimeModelArgument(modelID: model.model, thinkingLevel: "off"),
                extraArguments: ["--no-session", "--no-extensions", "--no-skills", "--no-tools", "--no-context-files", "--no-prompt-templates", "--no-themes", "--system-prompt", system, "--append-system-prompt", ""],
                environment: environment,
                onEvent: { events in
                    Task { @MainActor in
                        guard !didFinish else { return }
                        for wrapped in events {
                            guard let event = wrapped.event else { continue }
                            if event.type == "response", event.success == false {
                                didFinish = true
                                client?.stop()
                                completion(.failure(ReviewError.rpc(event.error?.compactDescription ?? wrapped.rawLine)))
                                return
                            }
                            if event.type == "message_update", let assistantEvent = event.assistantMessageEvent, assistantEvent["type"]?.stringValue == "text_delta" {
                                assistantText += assistantEvent["delta"]?.stringValue ?? ""
                            }
                            if event.type == "message_end", let message = event.message {
                                let text = Self.extractAssistantText(from: message)
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { assistantText = text }
                            }
                            if event.type == "agent_end" || event.type == "turn_end" {
                                didFinish = true
                                client?.stop()
                                let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                                completion(trimmed.isEmpty ? .failure(ReviewError.emptyResponse) : .success(trimmed))
                                return
                            }
                        }
                    }
                },
                onStderr: { _ in },
                onTermination: { code in
                    Task { @MainActor in
                        guard !didFinish else { return }
                        didFinish = true
                        completion(.failure(ReviewError.processExited(code)))
                    }
                }
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !didFinish else { return }
                didFinish = true
                client?.stop()
                completion(.failure(ReviewError.timedOut))
            }
            client?.prompt(user)
        } catch {
            completion(.failure(error))
        }
    }

    private static func extractAssistantText(from message: JSONValue) -> String {
        guard let content = message["content"] else { return message["output"]?.stringValue ?? "" }
        switch content {
        case let .string(value): return value
        case let .array(blocks): return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return content.compactDescription
        }
    }
}
