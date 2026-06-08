import AppKit
import SwiftUI

struct PiAgentThreadDiffSummaryView: View {
    let activities: [PiAgentTranscriptActivity]
    let projectPath: String?
    @State private var rows: [Row] = []
    @State private var isLoading = true

    var body: some View {
        let changes = Self.changedFiles(from: activities)
        if !changes.isEmpty && (isLoading || !rows.isEmpty) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Text("Changes")
                        .font(AppTheme.Font.caption.weight(.semibold))
                    Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                if isLoading && rows.isEmpty {
                    Text("Preparing file changes…")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
                ForEach(rows.prefix(4)) { row in
                    PiAgentInlineDiffCard(row: row)
                }
                if rows.count > 4 {
                    Text("\(rows.count - 4) more changed file\(rows.count - 4 == 1 ? "" : "s") hidden")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(.horizontal, AppTheme.Chat.cardHPadding)
            .padding(.vertical, AppTheme.Chat.cardVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
            .task(id: Self.signature(for: changes)) { await loadRows(changes: changes) }
        }
    }

    @MainActor
    static func changedPaths(from activities: [PiAgentTranscriptActivity]) -> [String] {
        changedFiles(from: activities).map(\.path)
    }

    /// Diff rows (path + diff) for the native tool-group renderer. Mirrors
    /// `loadRows`: at most 8 files, only those with a non-empty diff.
    @MainActor
    static func diffRows(from activities: [PiAgentTranscriptActivity]) -> [Row] {
        changedFiles(from: activities).prefix(8).compactMap { change in
            change.diff.isEmpty ? nil : Row(path: change.path, diff: change.diff)
        }
    }

    @MainActor
    private static func changedFiles(from activities: [PiAgentTranscriptActivity]) -> [ChangedFile] {
        var orderedPaths: [String] = []
        var diffsByPath: [String: [String]] = [:]
        for entry in activities.flatMap(\.entries) {
            let name = normalizedToolName(PiAgentTranscriptActivity.toolName(for: entry))
            guard name == "edit" || name == "write" else { continue }
            let event = PiAgentRPCEventRenderCache.event(from: entry.rawJSON)
            guard let path = path(from: event, entry: entry) else { continue }
            if diffsByPath[path] == nil { orderedPaths.append(path) }
            if let diff = diff(from: event, toolName: name), !diff.isEmpty {
                diffsByPath[path, default: []].append(diff)
            }
        }
        return orderedPaths.map { path in
            ChangedFile(path: path, diff: diffsByPath[path, default: []].joined(separator: "\n\n"))
        }
    }

    private func loadRows(changes: [ChangedFile]) async {
        isLoading = true
        rows = changes.prefix(8).compactMap { change in
            guard !change.diff.isEmpty else { return nil }
            return Row(path: change.path, diff: change.diff)
        }
        isLoading = false
    }

    private static func normalizedToolName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".").last.map(String.init) ?? name.lowercased()
    }

    private static func path(from event: PiAgentRPCEvent?, entry: PiAgentTranscriptEntry) -> String? {
        let path = event?.args?["path"]?.stringValue
            ?? event?.args?["file_path"]?.stringValue
            ?? event?.result?["details"]?["path"]?.stringValue
            ?? event?.result?["details"]?["file_path"]?.stringValue
            ?? event?.result?["path"]?.stringValue
            ?? event?.result?["file_path"]?.stringValue
            ?? pathFromDiff(event?.result?["details"]?["diff"]?.stringValue ?? event?.result?["diff"]?.stringValue)
            ?? pathFromText(entry.text)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func diff(from event: PiAgentRPCEvent?, toolName: String) -> String? {
        let payloadDiff = event?.result?["details"]?["diff"]?.stringValue
            ?? event?.result?["diff"]?.stringValue
        if let payloadDiff = trimDiff(payloadDiff ?? "").nilIfEmpty { return payloadDiff }
        guard toolName == "edit" else { return nil }
        return trimDiff(syntheticDiff(from: event?.args) ?? "").nilIfEmpty
    }

    private static func pathFromDiff(_ diff: String?) -> String? {
        guard let diff else { return nil }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git a/") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 { return stripDiffPrefix(String(parts[3])) }
            }
            if line.hasPrefix("+++") {
                let value = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                if value != "/dev/null" { return stripDiffPrefix(value) }
            }
        }
        return nil
    }

    private static func stripDiffPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    private static let pathTextRegexes = [#"in ([^\n]+)$"#, #"to ([^\n]+)$"#, #"from ([^\n]+)$"#]
        .compactMap { try? NSRegularExpression(pattern: $0) }

    private static func pathFromText(_ text: String) -> String? {
        for regex in pathTextRegexes {
            guard let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return nil
    }

    private static func syntheticDiff(from args: JSONValue?) -> String? {
        guard let editsValue = args?["edits"] else {
            if let oldText = args?["oldText"]?.stringValue ?? args?["old_text"]?.stringValue,
               let newText = args?["newText"]?.stringValue ?? args?["new_text"]?.stringValue {
                return syntheticDiff(edits: [(oldText, newText)])
            }
            return nil
        }
        let edits: [(String, String)]
        switch editsValue {
        case let .array(values):
            edits = values.compactMap { value in
                guard let old = value["oldText"]?.stringValue ?? value["old_text"]?.stringValue,
                      let new = value["newText"]?.stringValue ?? value["new_text"]?.stringValue else { return nil }
                return (old, new)
            }
        case let .string(raw):
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            edits = decoded.compactMap { dict in
                guard let old = dict["oldText"] as? String ?? dict["old_text"] as? String,
                      let new = dict["newText"] as? String ?? dict["new_text"] as? String else { return nil }
                return (old, new)
            }
        default:
            edits = []
        }
        return syntheticDiff(edits: edits)
    }

    private static func syntheticDiff(edits: [(String, String)]) -> String? {
        guard !edits.isEmpty else { return nil }
        var lines: [String] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { lines.append("  ...") }
            lines.append(contentsOf: edit.0.split(separator: "\n", omittingEmptySubsequences: false).map { "-  \($0)" })
            lines.append(contentsOf: edit.1.split(separator: "\n", omittingEmptySubsequences: false).map { "+  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func trimDiff(_ diff: String) -> String {
        diff.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func signature(for changes: [ChangedFile]) -> String {
        changes.map { "\($0.path):\($0.diff.count)" }.joined(separator: "\u{0}")
    }

    private struct ChangedFile: Hashable {
        let path: String
        let diff: String
    }

    struct Row: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let diff: String

        var changeCountText: String {
            // Single pass: count added/removed lines without splitting + filtering twice.
            var added = 0
            var removed = 0
            for line in diff.split(separator: "\n") {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            if added == 0 && removed == 0 { return "modified" }
            return "+\(added) −\(removed)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct PiAgentInlineDiffCard: View {
    let row: PiAgentThreadDiffSummaryView.Row
    @State private var isDiffSheetPresented = false
    @State private var openTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.path.truncatedMiddle(max: 54))
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.changeCountText)
                    .font(AppTheme.Font.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
                Button {
                    openTapCount += 1
                    isDiffSheetPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: openTapCount)
                            .frame(width: 15, height: 15)
                        Text("Open")
                    }
                }
                .font(AppTheme.Font.caption2.weight(.semibold))
                .appSmallSecondaryButton()
                .help("Open full diff")
                PiAgentDiffCopyButton(text: row.diff)
            }
            PiAgentCompactDiffPreview(diffText: row.diff)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.textContentFill.opacity(0.75)))
        .sheet(isPresented: $isDiffSheetPresented) {
            PiAgentFullDiffSheet(row: row)
        }
    }
}

private struct PiAgentDiffCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 15, height: 15)
                Text("Copy")
            }
        }
        .font(AppTheme.Font.caption2.weight(.semibold))
        .appSmallSecondaryButton()
        .help(copied ? "Copied" : "Copy diff")
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            copied = false
        }
    }
}

private struct PiAgentFullDiffSheet: View {
    let row: PiAgentThreadDiffSummaryView.Row
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.path)
                    .font(AppTheme.Font.headline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(row.changeCountText)
                    .font(AppTheme.Font.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedText)
            }
            PiAgentFullDiffView(diffText: row.diff)
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 520, idealHeight: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                AppCopyTextButton(title: "Copy Diff", text: row.diff)
            }
        }
    }
}

/// Full-diff sheet content hosted by the native tool-group's "Open" action. The
/// sheet is modal (not a scroll hot path), so reusing the SwiftUI diff view here
/// is pixel-identical to the original `PiAgentFullDiffSheet` by construction.
struct PiAgentNativeFullDiffSheet: View {
    let row: PiAgentThreadDiffSummaryView.Row
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.path)
                        .font(AppTheme.Font.headline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(row.changeCountText)
                        .font(AppTheme.Font.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
                AppCopyTextButton(title: "Copy Diff", text: row.diff)
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            PiAgentFullDiffView(diffText: row.diff)
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 520, idealHeight: 680)
    }
}

struct PiAgentFullDiffView: View {
    let diffText: String
    @State private var lines: [PiAgentFullDiffLine] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    HStack(alignment: .top, spacing: 10) {
                        Text(line.gutter)
                            .font(AppTheme.Font.caption.monospaced())
                            .foregroundStyle(line.gutterColor)
                            .frame(width: 56, alignment: .trailing)
                            .textSelection(.enabled)
                        Text(line.content.isEmpty ? " " : line.content)
                            .font(AppTheme.Font.caption.monospaced())
                            .foregroundStyle(line.textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.background)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.textContentFill))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        .task(id: diffText) {
            lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map { PiAgentFullDiffLine(raw: String($0)) }
        }
    }
}

private struct PiAgentFullDiffLine: Hashable {
    let prefix: String
    let lineNumber: String
    let content: String

    init(raw: String) {
        guard let first = raw.first, first == "+" || first == "-" || first == " " else {
            prefix = raw.hasPrefix("@@") ? "…" : " "
            lineNumber = ""
            content = raw.replacingOccurrences(of: "\t", with: "   ")
            return
        }
        prefix = String(first)
        let remainder = raw.dropFirst()
        let trimmedLeading = remainder.drop(while: { $0 == " " })
        let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
        lineNumber = String(numberPart)
        let body = numberPart.isEmpty ? remainder : trimmedLeading.dropFirst(numberPart.count)
        content = String(body.drop(while: { $0 == " " })).replacingOccurrences(of: "\t", with: "   ")
    }

    var gutter: String { lineNumber.isEmpty ? prefix : "\(prefix)\(lineNumber)" }

    var background: Color {
        switch prefix {
        case "+": return AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity)
        case "-": return AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity)
        default: return Color.clear
        }
    }

    var textColor: Color {
        switch prefix {
        case "+": return AppTheme.diffAdded
        case "-": return AppTheme.diffRemoved
        default: return AppTheme.mutedText
        }
    }

    var gutterColor: Color { textColor.opacity(prefix == " " ? 0.75 : 1) }
}

private struct PiAgentCompactDiffPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diffText: String
    @State private var isExpanded = false
    /// `diffText` is a `let` on the card, so we parse once on `.onAppear`
    /// instead of re-splitting + re-filtering + re-allocating `Line`s on every
    /// body eval (this card sits inside the transcript and re-renders on every
    /// streaming token).
    @State private var parsedAllLines: [Line] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                let visible = isExpanded ? parsedAllLines : Array(parsedAllLines.prefix(10))
                ForEach(visible.indices, id: \.self) { index in
                    let line = visible[index]
                    HStack(spacing: 9) {
                        Text(line.gutter)
                            .font(AppTheme.Font.caption.monospaced().weight(.semibold))
                            .foregroundStyle(line.color)
                            .frame(width: 40, alignment: .trailing)
                        Text(line.content.isEmpty ? " " : line.content)
                            .font(AppTheme.Font.caption.monospaced())
                            .foregroundStyle(line.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .background(line.background)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous))
            if parsedAllLines.count > 10 {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(isExpanded ? "Show fewer lines" : "Show \(parsedAllLines.count - 10) more lines", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(AppTheme.Font.caption2.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
        .onAppear {
            guard parsedAllLines.isEmpty else { return }
            parsedAllLines = Self.meaningfulLines(in: diffText).map(Line.init(raw:))
        }
    }

    private static func meaningfulLines(in diffText: String) -> [String] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard !line.hasPrefix("diff --git"), !line.hasPrefix("index "), !line.hasPrefix("---"), !line.hasPrefix("+++") else { return false }
            return line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }
    }

    private struct Line: Hashable {
        let prefix: String
        let lineNumber: String
        let content: String

        init(raw: String) {
            if raw.hasPrefix("@@") {
                prefix = "…"
                lineNumber = ""
                content = raw
                return
            }
            guard let first = raw.first, first == "+" || first == "-" || first == " " else {
                prefix = " "
                lineNumber = ""
                content = raw.trimmingCharacters(in: .whitespaces)
                return
            }
            // Pi's edit diffs prefix each line with its source line number padded
            // for alignment. Split that off so it renders in its own gutter column
            // instead of as a fixed whitespace gap baked into the content.
            prefix = String(first)
            let trimmedLeading = raw.dropFirst().drop(while: { $0 == " " })
            let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
            lineNumber = String(numberPart)
            content = String(trimmedLeading.dropFirst(numberPart.count).drop(while: { $0 == " " }))
        }

        var gutter: String {
            lineNumber.isEmpty ? prefix : "\(prefix) \(lineNumber)"
        }

        var color: Color {
            switch prefix {
            case "+": return AppTheme.diffAdded
            case "-": return AppTheme.diffRemoved
            default: return AppTheme.mutedText
            }
        }

        var background: Color {
            switch prefix {
            case "+": return AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity)
            case "-": return AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity)
            default: return Color.clear
            }
        }
    }
}

