import Foundation

import AppKit
import Foundation

// MARK: - Context estimates

struct PiAgentContextBreakdownItem: Identifiable, Codable, Hashable {
    var id: String { key }

    var key: String
    var title: String
    var tokens: Int?
    var percent: Double?
    var detail: String?

    init(key: String, title: String, tokens: Int?, percent: Double?, detail: String? = nil) {
        self.key = key
        self.title = title
        self.tokens = tokens
        self.percent = percent
        self.detail = detail
    }
}

struct PiAgentContextBreakdownEstimateRow: Identifiable, Hashable {
    enum Source: String, Hashable {
        case estimated
        case rpcAggregate
    }

    var id: String { key }

    var key: String
    var title: String
    var tokens: Int?
    var percent: Double?
    var detail: String?
    var source: Source
}

struct PiAgentContextBreakdownEstimate: Hashable {
    var rows: [PiAgentContextBreakdownEstimateRow]
    var note: String
}

struct PiAgentPromptCompositionRow: Identifiable, Hashable {
    var id: String { key }

    var key: String
    var title: String
    var tokens: Int
    var percent: Double
}

struct PiAgentPromptCompositionEstimate: Hashable {
    var rows: [PiAgentPromptCompositionRow]
    var totalTokens: Int
}

private extension NSRange {
    var locationOrNil: Int? { location == NSNotFound ? nil : location }
}

struct PiAgentContextEstimateBuilder {
    static func build(
        session: PiAgentSessionRecord,
        transcript: [PiAgentTranscriptEntry],
        fallbackModels: [AvailableModel] = []
    ) -> PiAgentContextBreakdownEstimate {
        _ = fallbackModels
        guard let contextWindow = positive(session.contextWindow) else {
            return PiAgentContextBreakdownEstimate(
                rows: [],
                note: "Estimated rows need RPC context totals before \(AppBrand.displayName) can derive a useful breakdown."
            )
        }

        let usedTokens = max(session.contextTokens ?? 0, 0)
        let inputTokens = max(session.inputTokens ?? 0, 0)
        let outputTokens = max(session.outputTokens ?? 0, 0)
        let cacheTokens = max((session.cacheReadTokens ?? 0) + (session.cacheWriteTokens ?? 0), 0)

        var rows: [PiAgentContextBreakdownEstimateRow] = []
        var accountedUsedTokens = 0

        func clampedToRemainingUsed(_ tokens: Int) -> Int {
            min(max(tokens, 0), max(usedTokens - accountedUsedTokens, 0))
        }

        if inputTokens > 0 {
            let tokens = clampedToRemainingUsed(inputTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedInputTokens",
                title: "Prompt input",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if outputTokens > 0 {
            let tokens = clampedToRemainingUsed(outputTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedOutputTokens",
                title: "Model output",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if cacheTokens > 0 {
            let tokens = clampedToRemainingUsed(cacheTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedCacheTokens",
                title: "Cache read/write",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if accountedUsedTokens == 0 {
            let rawMessageTokens = estimatedTranscriptTokens(transcript)
            let messageTokens = min(rawMessageTokens, usedTokens)
            if messageTokens > 0 || rawMessageTokens > 0 {
                accountedUsedTokens += messageTokens
                rows.append(.init(
                    key: "estimatedMessages",
                    title: "Visible transcript",
                    tokens: messageTokens,
                    percent: percent(messageTokens, of: contextWindow),
                    detail: rawMessageTokens > messageTokens
                        ? "Estimated from visible user, assistant, tool, and thinking transcript entries; clamped to RPC used tokens."
                        : "Estimated from visible user, assistant, tool, and thinking transcript entries.",
                    source: .estimated
                ))
            }
        }

        let otherUsedTokens = max(usedTokens - accountedUsedTokens, 0)
        if otherUsedTokens > 0 {
            rows.append(.init(
                key: "estimatedOtherUsedContext",
                title: "Unattributed used context",
                tokens: otherUsedTokens,
                percent: percent(otherUsedTokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        let freeTokens = max(contextWindow - usedTokens, 0)
        rows.append(.init(
            key: "estimatedFreeSpace",
            title: "Free space",
            tokens: freeTokens,
            percent: percent(freeTokens, of: contextWindow),
            detail: nil,
            source: .estimated
        ))

        return PiAgentContextBreakdownEstimate(
            rows: rows,
            note: "Estimated from Pi RPC token totals; exact prompt, tool, and message categories aren’t exposed."
        )
    }

    static func buildPromptComposition(systemPrompt: String?) -> PiAgentPromptCompositionEstimate? {
        guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), systemPrompt.isEmpty == false else {
            return nil
        }

        let prompt = systemPrompt as NSString
        let lower = systemPrompt.lowercased() as NSString
        let fullLength = prompt.length
        let totalTokens = estimatedPromptTokens(systemPrompt)
        guard totalTokens > 0 else { return nil }

        let skillsRange = blockRange(
            in: lower,
            startMarker: "<available_skills>",
            endMarker: "</available_skills>"
        )
        let toolsStart = lower.range(of: "available tools:").locationOrNil
        let projectStart = lower.range(of: "# project context").locationOrNil
        let skillsStart = skillsRange?.location

        func nextBoundary(after start: Int, candidates: [Int?]) -> Int {
            candidates.compactMap { $0 }.filter { $0 > start }.min() ?? fullLength
        }

        var ranges: [(key: String, title: String, range: NSRange)] = []
        if let toolsStart {
            ranges.append((
                "promptTools",
                "Tool descriptions",
                NSRange(location: toolsStart, length: nextBoundary(after: toolsStart, candidates: [projectStart, skillsStart]) - toolsStart)
            ))
        }
        if let projectStart {
            ranges.append((
                "promptProjectContext",
                "Project context",
                NSRange(location: projectStart, length: nextBoundary(after: projectStart, candidates: [skillsStart]) - projectStart)
            ))
        }
        if let skillsRange {
            ranges.append(("promptSkills", "Skill catalog", skillsRange))
        }

        let firstSectionStart = [toolsStart, projectStart, skillsStart].compactMap { $0 }.min() ?? fullLength
        if firstSectionStart > 0 {
            ranges.append(("promptCore", "Core instructions", NSRange(location: 0, length: firstSectionStart)))
        }

        var rows = ranges.compactMap { item -> PiAgentPromptCompositionRow? in
            guard item.range.location >= 0,
                  item.range.length > 0,
                  NSMaxRange(item.range) <= fullLength else { return nil }
            let tokens = estimatedPromptTokens(prompt.substring(with: item.range))
            guard tokens > 0 else { return nil }
            return .init(key: item.key, title: item.title, tokens: tokens, percent: percent(tokens, of: totalTokens))
        }

        let accounted = rows.reduce(0) { $0 + $1.tokens }
        let otherTokens = max(totalTokens - accounted, 0)
        if otherTokens > 50 {
            rows.append(.init(
                key: "promptOther",
                title: "Other prompt content",
                tokens: otherTokens,
                percent: percent(otherTokens, of: totalTokens)
            ))
        }

        rows.sort { $0.tokens > $1.tokens }
        return .init(rows: rows, totalTokens: totalTokens)
    }

    static func parseTokenCount(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else { return nil }
        let multiplier: Double
        let numberText: String
        if trimmed.hasSuffix("k") {
            multiplier = 1_000
            numberText = String(trimmed.dropLast())
        } else if trimmed.hasSuffix("m") {
            multiplier = 1_000_000
            numberText = String(trimmed.dropLast())
        } else {
            multiplier = 1
            numberText = trimmed.replacingOccurrences(of: ",", with: "")
        }
        guard let number = Double(numberText.replacingOccurrences(of: ",", with: "")) else { return nil }
        return max(Int((number * multiplier).rounded()), 0)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func percent(_ tokens: Int, of contextWindow: Int) -> Double {
        guard contextWindow > 0 else { return 0 }
        return min(max((Double(max(tokens, 0)) / Double(contextWindow)) * 100, 0), 100)
    }

    private static func estimatedTranscriptTokens(_ transcript: [PiAgentTranscriptEntry]) -> Int {
        transcript.reduce(0) { total, entry in
            guard isProviderVisibleEstimateRole(entry.role) else { return total }
            let text = transcriptTextForEstimate(entry)
            guard text.isEmpty == false else { return total }
            return total + Int(ceil(Double(text.count) / 4.0))
        }
    }

    private static func estimatedPromptTokens(_ text: String) -> Int {
        guard text.isEmpty == false else { return 0 }
        return Int(ceil(Double(text.count) / 3.5))
    }

    private static func blockRange(in text: NSString, startMarker: String, endMarker: String) -> NSRange? {
        let start = text.range(of: startMarker)
        guard start.location != NSNotFound else { return nil }
        let endSearch = NSRange(location: NSMaxRange(start), length: text.length - NSMaxRange(start))
        let end = text.range(of: endMarker, options: [], range: endSearch)
        guard end.location != NSNotFound else {
            return NSRange(location: start.location, length: text.length - start.location)
        }
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    private static func isProviderVisibleEstimateRole(_ role: PiAgentTranscriptRole) -> Bool {
        switch role {
        case .user, .assistant, .tool, .thinking:
            return true
        case .status, .error, .stderr, .raw:
            return false
        }
    }

    private static func transcriptTextForEstimate(_ entry: PiAgentTranscriptEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.role == .tool else { return text }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return text }
        if text.isEmpty { return title }
        return "\(title)\n\(text)"
    }

}
