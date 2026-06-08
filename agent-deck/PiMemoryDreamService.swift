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
        await MainActor.run { progress("Loading \(current.count) current memories…") }

        let clusters = Self.semanticClusters(current)
        var proposals: [PiMemoryDreamProposal] = []
        var clustersReviewed = 0

        for cluster in clusters {
            clustersReviewed += 1
            await MainActor.run { progress("Reviewing cluster \(clustersReviewed)/\(clusters.count)…") }
            let mergeActions = try await reviewer.reviewClusterForMerge(cluster: cluster)
            proposals.append(contentsOf: mergeActions)
            let didMerge = mergeActions.contains { $0.action == .merge }
            if !didMerge {
                proposals.append(contentsOf: try await reviewer.synthesizeCluster(cluster: cluster))
            }
        }

        await MainActor.run { progress("Rebalancing memory weights…") }
        proposals.append(contentsOf: try await reviewer.rebalanceWeights(candidates: Self.weightCandidates(current)))

        await MainActor.run { progress("Scanning fact contradictions…") }
        proposals.append(contentsOf: try await reviewer.scanContradictions(facts: current.filter { $0.kind == .fact }))

        await MainActor.run { progress("Discovering temporal event patterns…") }
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

        await MainActor.run { progress("Prepared \(proposals.filter { $0.action != .skip }.count) actionable proposal(s).") }
        return PiMemoryDreamCycleResult(
            id: UUID().uuidString,
            startedAt: started,
            finishedAt: Date(),
            trigger: "manual",
            phase: "full",
            clustersReviewed: clustersReviewed,
            memoriesMerged: proposals.filter { $0.action == .merge }.count,
            schemasCreated: proposals.filter { $0.action == .synthesize }.count,
            weightsAdjusted: proposals.reduce(0) { $0 + $1.weightChanges.count },
            contradictionsFound: proposals.filter { $0.action == .flagContradiction }.count,
            patternsDiscovered: proposals.filter { $0.action == .discoverPattern }.count,
            proposals: proposals
        )
    }

    static func semanticClusters(_ memories: [AgentMemoryRecord]) -> [[AgentMemoryRecord]] {
        let grouped = Dictionary(grouping: memories) { memory in
            let tag = memory.tags.first?.lowercased()
            return tag ?? normalizedTopic(memory.title)
        }
        return grouped.values
            .map { $0.sorted { $0.effectiveWeight > $1.effectiveWeight } }
            .filter { $0.count >= 2 }
            .sorted { $0.count == $1.count ? ($0.first?.title ?? "") < ($1.first?.title ?? "") : $0.count > $1.count }
            .prefix(12)
            .map(Array.init)
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
    You are a memory consolidation agent. Decide whether related memories should be merged into one canonical memory or kept separate. Merge only near-duplicates, evolving facts/procedures, or repeated lessons. Return valid JSON only.
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
    You are a knowledge synthesis agent. Extract higher-level principles, checklists, or patterns from related-but-distinct memories. Return valid JSON only.
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
    You are a contradiction detector for factual memories. Find same-topic facts that cannot both be true. Return JSON only.
    """

    static func contradictionUser(facts: [AgentMemoryRecord]) -> String {
        """
        Response JSON array schema:
        [{"ids":["id1","id2"],"reasoning":"why these facts contradict","title":"short label"}]
        Return [] when there are no likely contradictions.

        Facts:
        \(memoryBlock(facts))
        """
    }

    static let temporalSystem = """
    You discover temporal patterns in event memories. Find recurring sequences, incidents, or milestones that imply a reusable insight. Return JSON only.
    """

    static func temporalUser(events: [AgentMemoryRecord]) -> String {
        """
        Response JSON schema:
        {"patterns":[{"sourceIds":["..."],"title":"...","content":"...","tags":["..."],"weight":0.3,"reasoning":"..."}]}
        Return {"patterns":[]} if there is no useful temporal pattern.

        Events:
        \(memoryBlock(events))
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
                weight: merge["weight"] as? Double ?? 0.7,
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
            weight: synthesis["weight"] as? Double ?? 0.8,
            type: AgentMemoryKind(rawValue: synthesis["type"] as? String ?? "insight") ?? .insight,
            weightChanges: [:],
            reviewerRawResponse: raw
        )]
    }

    static func parseWeights(raw: String, candidates: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let changes = Dictionary(uniqueKeysWithValues: extractArray(raw).compactMap { item -> (String, Double)? in
            guard let id = item["id"] as? String, let record = byID[id] else { return nil }
            let suggested = (item["suggestedWeight"] as? Double) ?? (item["suggestedWeight"] as? NSNumber)?.doubleValue ?? record.weight
            guard abs(suggested - record.weight) >= 0.1 else { return nil }
            return (id, max(0.3, min(1.0, suggested)))
        })
        guard !changes.isEmpty else { return [] }
        return [PiMemoryDreamProposal(id: UUID().uuidString, phase: .weightRebalance, action: .reweight, sourceMemoryIDs: Array(changes.keys), title: "Rebalance memory weights", content: "Adjust memory weights based on reviewer calibration.", reasoning: "Reviewer suggested weight updates for usage/age calibration.", tags: ["dream-cycle", "reweight"], weight: nil, type: nil, weightChanges: changes, reviewerRawResponse: raw)]
    }

    static func parseContradictions(raw: String, facts: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        let valid = Set(facts.map(\.id))
        return extractArray(raw).compactMap { item in
            let ids = (item["ids"] as? [String] ?? []).filter { valid.contains($0) }
            guard ids.count >= 2 else { return nil }
            return PiMemoryDreamProposal(id: UUID().uuidString, phase: .contradictionScan, action: .flagContradiction, sourceMemoryIDs: ids, title: item["title"] as? String ?? "Potential memory contradiction", content: item["reasoning"] as? String ?? "Potential contradiction flagged by reviewer.", reasoning: item["reasoning"] as? String ?? "Potential contradiction flagged by reviewer.", tags: ["dream-cycle", "contradiction"], weight: nil, type: nil, weightChanges: [:], contradictionPairs: [ids], reviewerRawResponse: raw)
        }
    }

    static func parseTemporal(raw: String, events: [AgentMemoryRecord]) -> [PiMemoryDreamProposal] {
        guard let obj = extractObject(raw), let patterns = obj["patterns"] as? [[String: Any]] else { return [] }
        let valid = Set(events.map(\.id))
        return patterns.compactMap { pattern in
            let ids = (pattern["sourceIds"] as? [String] ?? []).filter { valid.contains($0) }
            guard ids.count >= 2 else { return nil }
            return PiMemoryDreamProposal(id: UUID().uuidString, phase: .temporalPatterns, action: .discoverPattern, sourceMemoryIDs: ids, title: pattern["title"] as? String ?? "Temporal memory pattern", content: pattern["content"] as? String ?? "", reasoning: pattern["reasoning"] as? String ?? "Reviewer found a temporal pattern.", tags: pattern["tags"] as? [String] ?? ["dream-pattern"], weight: pattern["weight"] as? Double ?? 0.7, type: .insight, weightChanges: [:], reviewerRawResponse: raw)
        }
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
            return try FoundationModelAutomationService.generateOneShot(prompt: user, systemPrompt: system, temperature: 0.2, maxTokens: 2_000)
        }
        return try await withCheckedThrowingContinuation { continuation in
            startPiHelper(system: system, user: user) { result in continuation.resume(with: result) }
        }
    }

    private func startPiHelper(system: String, user: String, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            var assistantText = ""
            var didFinish = false
            var client: PiRPCClient?
            let runID = UUID()
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
