import AppKit
import SwiftUI

enum PiAgentTranscriptCardStyle {
    case standalone
    case question
    case threadChild
}

struct PiAgentUserMessageContent: View {
    let entry: PiAgentTranscriptEntry
    var skills: [SkillRecord] = []
    var commandSlashNames: Set<String> = []
    @State private var preview: AttachmentPreview?

    private struct ParsedContent {
        let messageText: String
        let imageAttachments: [PiAgentImageAttachment]
        let legacyImageNames: [String]
        let fileAttachments: [FileAttachmentPreview]
        let folderAttachments: [FolderAttachmentPreview]
        let pasteAttachments: [PiAgentPasteAttachment]
        let issueAttachment: PiAgentIssueAttachment?
        /// `/skill:name` if the entry started with that prefix.
        let skillInvocation: String?
        /// `/foo` if the entry started with a bare-slash token (resolved at
        /// render time against `commandSlashNames` to decide whether to render
        /// the command chip — otherwise the prefix stays in `messageText`).
        let bareSlashInvocation: String?
    }

    @MainActor private static var parsedContentCache: [String: ParsedContent] = [:]
    @MainActor private static var parsedContentCacheOrder: [String] = []
    private static let parsedContentCacheLimit = 256

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !messageText.isEmpty {
                MarkdownTextView(source: messageText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasAnyChip {
                HStack(alignment: .top, spacing: 8) {
                    if let skillUse = resolvedSkillUse {
                        attachmentChip(name: skillUse.name, systemImage: "sparkles", attachment: .skill(skillUse))
                    }
                    if let commandUse = resolvedCommandUse {
                        attachmentChip(name: commandUse.name, systemImage: "terminal", attachment: .command(commandUse))
                    }
                    if let issueAttachment {
                        attachmentChip(name: "#\(issueAttachment.number) \(issueAttachment.title)", systemImage: "exclamationmark.circle", attachment: .issue(issueAttachment))
                    }
                    ForEach(imageAttachments.prefix(6)) { image in
                        attachmentChip(name: image.name, systemImage: "photo", attachment: .image(image))
                    }
                    ForEach(legacyImageNames.prefix(max(0, 6 - imageAttachments.count)), id: \.self) { name in
                        attachmentChip(name: name, systemImage: "photo", attachment: .missing(name))
                    }
                    ForEach(fileAttachments.prefix(6)) { file in
                        attachmentChip(name: file.name, systemImage: "doc.text", attachment: .file(file))
                    }
                    ForEach(folderAttachments.prefix(6)) { folder in
                        attachmentChip(name: folder.name, systemImage: "folder", attachment: .folder(folder))
                    }
                    ForEach(pasteAttachments.prefix(6)) { paste in
                        attachmentChip(name: paste.marker, systemImage: "doc.plaintext", attachment: .paste(paste))
                    }
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount)")
                            .font(AppTheme.Font.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                            .padding(8)
                            .appGlassCapsule()
                    }
                }
            }
        }
    }

    private var hasAnyChip: Bool {
        !imageAttachments.isEmpty || !legacyImageNames.isEmpty || !fileAttachments.isEmpty || !folderAttachments.isEmpty || !pasteAttachments.isEmpty || issueAttachment != nil || resolvedSkillUse != nil || resolvedCommandUse != nil
    }

    private var parsedContent: ParsedContent {
        Self.parsedContent(for: entry)
    }

    /// The visible message text after stripping inline `<file>` tags, paste
    /// markers, and folder references — i.e. what `MarkdownTextView` actually
    /// renders. Exposed so the iMessage bubble width can be measured against
    /// what's drawn, not the raw entry text (which embeds long file paths
    /// from image attachments and would otherwise saturate the width cap).
    /// Treats a `/skill:` prefix as stripped (always rendered as a chip).
    /// `commandSlashNames` lets the same stripping happen for resolved commands.
    /// When `skills` is provided, an inactive-skill body match also gets its
    /// body stripped (only the user's trailing text remains as the bubble text).
    @MainActor
    static func displayMessageText(for entry: PiAgentTranscriptEntry, skills: [SkillRecord] = [], commandSlashNames: Set<String> = []) -> String {
        let parsed = parsedContent(for: entry)
        if parsed.skillInvocation != nil { return parsed.messageText }
        if let inactive = inactiveSkillMatch(for: entry, parsed: parsed, skills: skills) {
            return inactive.remainingText
        }
        if let cmd = parsed.bareSlashInvocation {
            if commandSlashNames.contains(cmd) { return parsed.messageText }
            return parsed.messageText.isEmpty ? "/\(cmd)" : "/\(cmd) \(parsed.messageText)"
        }
        return parsed.messageText
    }

    /// Natural unwrapped width of the chip row this bubble will draw, so the
    /// bubble can grow to fit pills (within the cap) for messages with short
    /// text but wide attachments. Mirrors the chips emitted in `body`.
    @MainActor
    static func displayChipsNaturalWidth(for entry: PiAgentTranscriptEntry, skills: [SkillRecord] = [], commandSlashNames: Set<String> = []) -> CGFloat {
        let parsed = parsedContent(for: entry)
        var labels: [String] = []
        if let name = parsed.skillInvocation {
            labels.append(name)
        } else if let inactive = inactiveSkillMatch(for: entry, parsed: parsed, skills: skills) {
            labels.append(inactive.skill.name)
        }
        if let name = parsed.bareSlashInvocation, commandSlashNames.contains(name) {
            labels.append(name)
        }
        if let issue = parsed.issueAttachment {
            labels.append("#\(issue.number) \(issue.title)")
        }
        let imageNames = parsed.imageAttachments.prefix(6).map(\.name)
        labels.append(contentsOf: imageNames)
        let remainingLegacy = max(0, 6 - parsed.imageAttachments.count)
        labels.append(contentsOf: parsed.legacyImageNames.prefix(remainingLegacy))
        labels.append(contentsOf: parsed.fileAttachments.prefix(6).map(\.name))
        labels.append(contentsOf: parsed.folderAttachments.prefix(6).map(\.name))
        labels.append(contentsOf: parsed.pasteAttachments.prefix(6).map(\.marker))
        return ChipLabelWidth.rowWidth(forLabels: labels)
    }

    /// The text drawn by the bubble's MarkdownTextView. Strips the skill prefix
    /// always (since `/skill:` is unambiguous), the command prefix only when
    /// the bare slash matches an active command, and the inactive-skill body
    /// when the message text begins with a known skill's body (leaving any
    /// trailing user text).
    private var messageText: String {
        if parsedContent.skillInvocation != nil { return parsedContent.messageText }
        if let inactive = Self.inactiveSkillMatch(for: entry, parsed: parsedContent, skills: skills) {
            return inactive.remainingText
        }
        if let cmd = parsedContent.bareSlashInvocation, commandSlashNames.contains(cmd) {
            return parsedContent.messageText
        }
        return originalMessageText
    }
    /// `messageText` with any slash invocation re-prepended — used when we
    /// chose NOT to render a chip (so the slash reads as literal user text).
    private var originalMessageText: String {
        if let skill = parsedContent.skillInvocation {
            let body = parsedContent.messageText
            return body.isEmpty ? "/skill:\(skill)" : "/skill:\(skill)\n\(body)"
        }
        if let cmd = parsedContent.bareSlashInvocation {
            let body = parsedContent.messageText
            return body.isEmpty ? "/\(cmd)" : "/\(cmd) \(body)"
        }
        return parsedContent.messageText
    }
    private var imageAttachments: [PiAgentImageAttachment] { parsedContent.imageAttachments }
    private var folderAttachments: [FolderAttachmentPreview] { parsedContent.folderAttachments }
    private var fileAttachments: [FileAttachmentPreview] { parsedContent.fileAttachments }
    private var legacyImageNames: [String] { parsedContent.legacyImageNames }
    private var pasteAttachments: [PiAgentPasteAttachment] { parsedContent.pasteAttachments }
    private var issueAttachment: PiAgentIssueAttachment? { parsedContent.issueAttachment }
    /// Resolved skill chip — from `/skill:` prefix when active, or from a
    /// body match against the known skills list when inactive.
    private var resolvedSkillUse: SkillUseAttachment? {
        if let name = parsedContent.skillInvocation {
            return SkillUseAttachment(name: name, skill: skills.first { $0.name == name })
        }
        if let inactive = Self.inactiveSkillMatch(for: entry, parsed: parsedContent, skills: skills) {
            return SkillUseAttachment(name: inactive.skill.name, skill: inactive.skill)
        }
        return nil
    }

    /// Detect that the bubble's text is an inactive-skill invocation: the
    /// message text begins with a known skill's body (optionally followed
    /// by user-typed text after a blank line — the format `SlashItem.materialize`
    /// produces when the skill extension isn't loaded in Pi).
    @MainActor
    private static func inactiveSkillMatch(for entry: PiAgentTranscriptEntry, parsed: ParsedContent, skills: [SkillRecord]) -> (skill: SkillRecord, remainingText: String)? {
        guard parsed.skillInvocation == nil, parsed.bareSlashInvocation == nil else { return nil }
        let trimmed = parsed.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for skill in skills {
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, trimmed.count >= body.count else { continue }
            if trimmed == body {
                return (skill, "")
            }
            // Inactive materialize separates body and user text with `\n\n`.
            if trimmed.hasPrefix(body + "\n\n") {
                let remaining = String(trimmed.dropFirst(body.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (skill, remaining)
            }
        }
        return nil
    }
    /// Resolved command chip, only when the bare-slash prefix matches an
    /// active command for the session.
    private var resolvedCommandUse: CommandUseAttachment? {
        guard let name = parsedContent.bareSlashInvocation, commandSlashNames.contains(name) else { return nil }
        return CommandUseAttachment(name: name)
    }

    @MainActor
    private static func parsedContent(for entry: PiAgentTranscriptEntry) -> ParsedContent {
        let key = parsedContentCacheKey(for: entry)
        if let cached = parsedContentCache[key] { return cached }

        let markers = ["Attached files:", "Attached images:"]
        let firstRange = markers.compactMap { entry.text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let base = firstRange.map { String(entry.text[..<$0.lowerBound]) } ?? entry.text
        let pasteAttachments = pastes(for: entry)
        let messageWithoutPastes = removingPasteMarkers(from: base, pasteAttachments: pasteAttachments)
        let messageWithoutTagsFoldersPastes = removingFolderReferences(from: removingFileTags(from: messageWithoutPastes)).trimmingCharacters(in: .whitespacesAndNewlines)
        let (skillInvocation, bareSlashInvocation, messageText) = extractSlashInvocation(from: messageWithoutTagsFoldersPastes)
        let imageAttachments = images(for: entry)
        let issueAttachment = issue(for: entry)
        let inlineFileTags = inlineFileTags(in: entry.text)
        let folderAttachments = uniqueFolders(folderReferences(in: entry.text).map { path in
            FolderAttachmentPreview(name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent, path: path)
        })
        let payloadFiles = payloadFiles(for: entry).filter { !isImageName($0.name) }
        let payloadFileNames = Set(payloadFiles.map(\.name))
        // Fall back to the basename-only "Attached files:" list for entries
        // written before `files[]` was added to the JSON payload, or for files
        // that somehow weren't captured there. The payload entries carry the
        // real path (preview works); the listed fallbacks don't.
        let listedFiles = attachmentLines(after: "Attached files:", in: entry.text).compactMap { line -> FileAttachmentPreview? in
            guard !line.contains("<image ") else { return nil }
            guard !payloadFileNames.contains(line) else { return nil }
            return .init(name: line, path: nil)
        }
        let taggedFiles = inlineFileTags.filter { !isImageName($0.name) && !payloadFileNames.contains($0.name) }
        let fileAttachments = uniqueFiles(payloadFiles + taggedFiles + listedFiles)
        let imageLines = attachmentLines(after: "Attached images:", in: entry.text) + attachmentLines(after: "Attached files:", in: entry.text).filter { $0.contains("<image ") }
        let legacyImageNames = uniqueNames(imageLines.compactMap(imageName(from:)) + inlineFileTags.filter { isImageName($0.name) }.map(\.name)).filter { name in
            !imageAttachments.contains { $0.name == name }
        }

        let parsed = ParsedContent(
            messageText: messageText,
            imageAttachments: imageAttachments,
            legacyImageNames: legacyImageNames,
            fileAttachments: fileAttachments,
            folderAttachments: folderAttachments,
            pasteAttachments: pasteAttachments,
            issueAttachment: issueAttachment,
            skillInvocation: skillInvocation,
            bareSlashInvocation: bareSlashInvocation
        )
        parsedContentCache[key] = parsed
        parsedContentCacheOrder.append(key)
        if parsedContentCacheOrder.count > parsedContentCacheLimit {
            let overflow = parsedContentCacheOrder.count - parsedContentCacheLimit
            for oldKey in parsedContentCacheOrder.prefix(overflow) {
                parsedContentCache[oldKey] = nil
            }
            parsedContentCacheOrder.removeFirst(overflow)
        }
        return parsed
    }

    private static func parsedContentCacheKey(for entry: PiAgentTranscriptEntry) -> String {
        // User entries are immutable after insertion. Avoid hashing large attached
        // file payloads on every SwiftUI body pass for long chats.
        "\(entry.id.uuidString):\(entry.text.count):\(entry.rawJSON?.count ?? 0)"
    }

    private static func attachmentLines(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        let tail = text[range.upperBound...]
        let stop = marker == "Attached files:" ? tail.range(of: "Attached images:")?.lowerBound : nil
        let slice = stop.map { tail[..<$0] } ?? tail[...]
        return slice.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    private static func inlineFileTags(in text: String) -> [FileAttachmentPreview] {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let path = String(text[range])
            return .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
    }

    private static func imageName(from raw: String) -> String? {
        guard let range = raw.range(of: #"name=\"([^\"]+)\""#, options: .regularExpression) else { return nil }
        let match = raw[range]
        return match.replacingOccurrences(of: "name=\"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Detect a leading slash invocation produced by `SlashItem.materialize`.
    /// Returns `(skillInvocation, bareSlashInvocation, remainingMessage)`:
    /// - `/skill:name` → `(name, nil, rest)` — always treated as a skill chip.
    /// - `/foo …`     → `(nil, "foo", text-without-prefix)` — the caller decides
    ///   whether to render the chip based on the active command set; if not, the
    ///   prefix stays in the displayed message.
    private static func extractSlashInvocation(from text: String) -> (skill: String?, bareSlash: String?, remaining: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return (nil, nil, text) }
        if trimmed.hasPrefix("/skill:") {
            // `/skill:name` is followed by either whitespace/newline (then rest) or end of string.
            let afterPrefix = trimmed.dropFirst("/skill:".count)
            let nameEnd = afterPrefix.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? afterPrefix.endIndex
            let name = String(afterPrefix[..<nameEnd])
            guard !name.isEmpty else { return (nil, nil, text) }
            let remaining = String(afterPrefix[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, nil, remaining)
        }
        // Bare `/foo …` — accept names made of [A-Za-z0-9_-:], no spaces.
        let afterSlash = trimmed.dropFirst()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-:"))
        let nameEnd = afterSlash.firstIndex(where: { ch in
            guard let scalar = ch.unicodeScalars.first else { return true }
            return !allowed.contains(scalar)
        }) ?? afterSlash.endIndex
        let name = String(afterSlash[..<nameEnd])
        guard !name.isEmpty else { return (nil, nil, text) }
        let remaining = String(afterSlash[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, name, remaining)
    }

    private static func removingFileTags(from text: String) -> String {
        text.replacingOccurrences(of: #"<file name=\"[^\"]+\">[\s\S]*?</file>"#, with: "", options: .regularExpression)
    }

    private static func removingPasteMarkers(from text: String, pasteAttachments: [PiAgentPasteAttachment]) -> String {
        guard !pasteAttachments.isEmpty else { return text }
        var output = text
        for paste in pasteAttachments {
            output = output.replacingOccurrences(of: paste.marker, with: "")
        }
        return output
    }

    private static func removingFolderReferences(from text: String) -> String {
        guard !folderReferences(in: text).isEmpty else { return text }
        var output = text
        for pattern in folderReferencePatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return output
            .replacingOccurrences(of: #"^\s*-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private static func folderReferences(in text: String) -> [String] {
        let explicit = matches(pattern: #"\bfolder:\s*`([^`]+)`"#, in: text)
            + matches(pattern: #"\bfolder:\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        let bare = matches(pattern: #"^\s*`(/[^`]+)`(?=\s+-\s+|\s*$)"#, in: text)
            + matches(pattern: #"^\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        return uniquePaths(explicit) + uniqueExistingDirectories(bare)
    }

    private static var folderReferencePatterns: [String] {
        [
            #"\bfolder:\s*`[^`]+`\s*(?:-\s*)?"#,
            #"\bfolder:\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#,
            #"^\s*`/[^`]+`(?=\s+-\s+|\s*$)\s*(?:-\s*)?"#,
            #"^\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#
        ]
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func uniqueExistingDirectories(_ paths: [String]) -> [String] {
        uniquePaths(paths).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func isImageName(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func uniqueFiles(_ files: [FileAttachmentPreview]) -> [FileAttachmentPreview] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.name).inserted }
    }

    private static func uniqueFolders(_ folders: [FolderAttachmentPreview]) -> [FolderAttachmentPreview] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.path).inserted }
    }

    private struct AttachmentPayload: Decodable {
        let images: [PiAgentImageAttachment]?
        let pastes: [PiAgentPasteAttachment]?
        let issue: PiAgentIssueAttachment?
        let files: [FilePayload]?
    }

    private struct FilePayload: Decodable {
        let name: String
        let path: String
    }

    private static func attachmentPayload(for entry: PiAgentTranscriptEntry) -> AttachmentPayload? {
        guard let rawJSON = entry.rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? transcriptJSONDecoder.decode(AttachmentPayload.self, from: data)
    }

    private static func images(for entry: PiAgentTranscriptEntry) -> [PiAgentImageAttachment] {
        attachmentPayload(for: entry)?.images ?? []
    }

    private static func pastes(for entry: PiAgentTranscriptEntry) -> [PiAgentPasteAttachment] {
        attachmentPayload(for: entry)?.pastes ?? []
    }

    private static func issue(for entry: PiAgentTranscriptEntry) -> PiAgentIssueAttachment? {
        attachmentPayload(for: entry)?.issue
    }

    private static func payloadFiles(for entry: PiAgentTranscriptEntry) -> [FileAttachmentPreview] {
        (attachmentPayload(for: entry)?.files ?? []).map { FileAttachmentPreview(name: $0.name, path: $0.path) }
    }

    private var hiddenCount: Int {
        let chipCount = imageAttachments.count + legacyImageNames.count + fileAttachments.count + folderAttachments.count + pasteAttachments.count
            + (issueAttachment == nil ? 0 : 1)
            + (resolvedSkillUse == nil ? 0 : 1)
            + (resolvedCommandUse == nil ? 0 : 1)
        return max(0, chipCount - 12)
    }

    private func attachmentChip(name: String, systemImage: String, attachment: AttachmentPreview) -> some View {
        Button { preview = attachment } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(AppTheme.Font.caption2)
        }
        .appSmallSecondaryButton()
        .help("Preview \(name)")
        .popover(isPresented: Binding(
            get: { preview == attachment },
            set: { isPresented in
                if isPresented {
                    preview = attachment
                } else if preview == attachment {
                    preview = nil
                }
            }
        ), arrowEdge: .bottom) {
            AttachmentPreviewPopover(attachment: attachment)
        }
    }
}

private struct FileAttachmentPreview: Identifiable, Hashable {
    var id: String { path ?? name }
    let name: String
    let path: String?
}

private struct FolderAttachmentPreview: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

private struct SkillUseAttachment: Hashable {
    let name: String
    let skill: SkillRecord?
}

private struct CommandUseAttachment: Hashable {
    let name: String
}

private enum AttachmentPreview: Identifiable, Hashable {
    case image(PiAgentImageAttachment)
    case file(FileAttachmentPreview)
    case folder(FolderAttachmentPreview)
    case paste(PiAgentPasteAttachment)
    case issue(PiAgentIssueAttachment)
    case missing(String)
    case skill(SkillUseAttachment)
    case command(CommandUseAttachment)

    var id: String {
        switch self {
        case .image(let image): return "image-\(image.id.uuidString)"
        case .file(let file): return "file-\(file.id)"
        case .folder(let folder): return "folder-\(folder.id)"
        case .paste(let paste): return "paste-\(paste.id)-\(paste.marker)"
        case .issue(let issue): return "issue-\(issue.id)"
        case .missing(let name): return "missing-\(name)"
        case .skill(let use): return "skill-\(use.name)"
        case .command(let use): return "command-\(use.name)"
        }
    }
}

private struct AttachmentPreviewPopover: View {
    let attachment: AttachmentPreview
    @State private var filePreviewPath: String?
    @State private var filePreviewText: String?
    @State private var isLoadingFilePreview = false

    /// Single shared popover ceiling. The previous `300` cap was too tight
    /// for skill/file/issue/paste/command bodies. ScrollViews inside use
    /// `.frame(maxHeight: .infinity)` so they expand to fill this height
    /// rather than collapsing to ScrollView's tiny intrinsic; popovers whose
    /// preview body has a natural size (image, folder, missing) ignore this
    /// cap and size to content.
    private static let popoverMaxHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            previewBody
        }
        .padding(12)
        .frame(width: 420, alignment: .topLeading)
        .frame(maxHeight: Self.popoverMaxHeight)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.brandAccent)
            Text(title)
                .font(AppTheme.Font.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder private var previewBody: some View {
        switch attachment {
        case .image(let image):
            if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
            } else {
                empty("Preview is not available for this image.")
            }
        case .file(let file):
            if let path = file.path {
                filePreviewBody(path: path)
                    .task(id: path) {
                        await loadTextPreview(atPath: path)
                    }
            } else {
                empty("Preview is not available for this attachment.")
            }
        case .folder(let folder):
            folderPreviewBody(folder: folder)
        case .paste(let paste):
            pastePreviewBody(paste: paste)
        case .issue(let issue):
            issuePreviewBody(issue: issue)
        case .missing:
            empty("Preview is not available for older attachment metadata.")
        case .skill(let use):
            skillPreviewBody(use: use)
        case .command(let use):
            commandPreviewBody(use: use)
        }
    }

    private func skillPreviewBody(use: SkillUseAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description = use.skill?.description, !description.isEmpty {
                Text(description)
                    .font(AppTheme.Font.subheadline)
                    .foregroundStyle(.secondary)
            }
            ScrollView(showsIndicators: false) {
                Text(use.skill?.body.isEmpty == false
                    ? use.skill!.body
                    : (use.skill?.filePath ?? "Skill details are not available in \(AppBrand.displayName)'s current scan snapshot."))
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        }
    }

    private func commandPreviewBody(use: CommandUseAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command invocation sent to Pi.")
                .font(AppTheme.Font.subheadline)
                .foregroundStyle(.secondary)
            Text("/\(use.name)")
                .font(AppTheme.Font.code)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        }
    }

    private func pastePreviewBody(paste: PiAgentPasteAttachment) -> some View {
        ScrollView(showsIndicators: false) {
            Text(paste.text)
                .font(AppTheme.Font.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
    }

    private func issuePreviewBody(issue: PiAgentIssueAttachment) -> some View {
        let commentsText = issue.comments.map { comment in
            """
            \(comment.author) · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
            \(comment.body)
            """
        }
        .joined(separator: "\n\n")
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text(issue.repository)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Text("#\(issue.number) \(issue.title)")
                    .font(AppTheme.Font.body.weight(.semibold))
                if let author = issue.author, !author.isEmpty {
                    Text("Author: \(author)")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text("State: \(issue.state)")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if !issue.labels.isEmpty {
                    Text("Labels: \(issue.labels.joined(separator: ", "))")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text("Comments: \(issue.comments.count)")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if !issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()
                    Text(issue.body)
                        .font(AppTheme.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !issue.comments.isEmpty {
                    Divider()
                    Text(commentsText)
                        .font(AppTheme.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
    }

    @ViewBuilder private func filePreviewBody(path: String) -> some View {
        if isLoadingFilePreview || filePreviewPath != path {
            AppSpinner()
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let text = filePreviewText {
            ScrollView(showsIndicators: false) {
                Text(String(text.prefix(12_000)))
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                Text("Preview is not available for this file type.")
                Text(path)
                    .font(AppTheme.Font.code)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder private func folderPreviewBody(folder: FolderAttachmentPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(folder.path)
                .font(AppTheme.Font.code)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path, isDirectory: true)])
            }
            .appSecondaryButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadTextPreview(atPath path: String) async {
        filePreviewPath = path
        filePreviewText = nil
        isLoadingFilePreview = true
        let text = await Task.detached(priority: .utility) {
            Self.textPreview(atPath: path)
        }.value
        guard !Task.isCancelled, filePreviewPath == path else { return }
        filePreviewText = text
        isLoadingFilePreview = false
    }

    private var title: String {
        switch attachment {
        case .image(let image): return image.name
        case .file(let file): return file.name
        case .folder(let folder): return folder.name
        case .paste(let paste): return paste.marker
        case .issue(let issue): return "#\(issue.number) \(issue.title)"
        case .missing(let name): return name
        case .skill(let use): return use.skill?.name ?? use.name
        case .command(let use): return "/\(use.name)"
        }
    }

    private var icon: String {
        switch attachment {
        case .image, .missing: return "photo"
        case .file: return "doc.text"
        case .folder: return "folder"
        case .paste: return "doc.plaintext"
        case .issue: return "exclamationmark.circle"
        case .skill: return "sparkles"
        case .command: return "terminal"
        }
    }

    private nonisolated static func textPreview(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .macOSRoman)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Font.callout)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct PiAgentTranscriptCard: View {
    let entry: PiAgentTranscriptEntry
    var style: PiAgentTranscriptCardStyle = .standalone
    var skills: [SkillRecord] = []
    var commandSlashNames: Set<String> = []

    /// User questions render as messaging-style bubbles. They still show the
    /// "You" header (icon + label + hover-revealed copy button) like other
    /// cards, but the bubble itself shrinks to fit its content and is pushed
    /// right by the enclosing thread card — content inside stays left-aligned
    /// so text reads naturally.
    private var isUserBubble: Bool {
        entry.role == .user && style == .question
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 7) {
                headerIcon
                Text(headerTitle)
                    .font(AppTheme.Font.footnote.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(headerColor)
                Spacer(minLength: 0)
            }

            content
        }
        .padding(.horizontal, style == .threadChild ? AppTheme.Chat.bubbleChildHPadding : AppTheme.Chat.bubbleHPadding)
        .padding(.vertical, style == .threadChild ? AppTheme.Chat.bubbleChildVPadding : AppTheme.Chat.bubbleVPadding)
        // User bubbles size to their content (the outer thread card caps the
        // width and pushes them right). Other cards stretch full-width as
        // before. Internal alignment is always .leading so text reads naturally.
        .frame(maxWidth: isUserBubble ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.bubbleCornerRadius, style: .continuous)
                .fill(backgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.bubbleCornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerIcon: some View {
        if entry.role == .assistant {
            Image("pi")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.piLogo.gradient)
                // Rendered smaller than its 16pt slot so the filled pi mark
                // optically matches the SF Symbols the other roles use.
                .frame(width: 13, height: 13)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let subagentSummary = PiAgentSubagentSummary.cached(for: entry) {
            PiAgentSubagentTranscriptView(summary: subagentSummary)
        } else if entry.role == .tool {
            PiAgentToolTranscriptView(entry: entry)
        } else if entry.role == .thinking {
            thinkingContent
        } else if entry.role == .user {
            PiAgentUserMessageContent(entry: entry, skills: skills, commandSlashNames: commandSlashNames)
        } else if entry.role == .assistant {
            MarkdownTextView(source: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? AppTheme.Font.code : AppTheme.Font.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thinkingContent: some View {
        reasoningContent(source: entry.text)
    }

    private func reasoningContent(source: String) -> some View {
        let displayText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Reasoning")
                .font(AppTheme.Font.caption.weight(.semibold))
            MarkdownTextView(source: displayText.isEmpty ? "Pi has not emitted reasoning text yet." : displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private var headerTitle: String {
        if entry.title == "Steering" { return "Steering" }
        switch entry.role {
        case .user: return "You"
        case .assistant: return "Coding Agent"
        case .tool: return toolHeaderTitle
        default: return entry.title
        }
    }

    private var toolHeaderTitle: String {
        if entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent") {
            return "Deck agents"
        }
        if entry.title.hasPrefix("Tool: ") {
            return "Tool · " + entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    /// Single base color per role. The card's background fill, border stroke,
    /// and icon/label tint are all derived from this through AppTheme's fixed
    /// opacity scale, so a role reads consistently and adapts to light/dark.
    private var roleBase: Color {
        switch entry.role {
        case .user: return AppTheme.roleUser
        case .assistant: return AppTheme.brandAccent
        case .thinking: return AppTheme.roleThinking
        case .tool: return AppTheme.roleTool
        case .error: return AppTheme.roleError
        case .stderr: return AppTheme.roleStderr
        case .status, .raw: return AppTheme.roleStatus
        }
    }

    /// Status and raw cards sit on the neutral surface rather than a tinted role
    /// color — they are informational. Every other role (user / assistant /
    /// thinking / tool / error / stderr) takes its role base tint.
    private var usesNeutralSurface: Bool {
        entry.role == .status || entry.role == .raw
    }

    private var headerColor: Color {
        entry.role == .assistant ? AppTheme.piLogo : .primary
    }

    private var backgroundStyle: AnyShapeStyle {
        // The Pi reply bubble takes a brand-accent tint through the same
        // role-base path as the user bubble, so it reads as conversation rather
        // than another neutral tool/diff card — light and dark alike.
        if usesNeutralSurface {
            return AnyShapeStyle(AppTheme.contentSubtleFill.opacity(0.7).gradient)
        }
        let fill = style == .question ? AppTheme.roleFillStrongOpacity : AppTheme.roleFillOpacity
        return AnyShapeStyle(roleBase.opacity(fill).gradient)
    }

    private var strokeColor: Color {
        return usesNeutralSurface
            ? AppTheme.contentStroke
            : roleBase.opacity(AppTheme.roleStrokeOpacity)
    }

    private var icon: String {
        switch entry.role {
        case .user: return entry.title == "Steering" ? "arrowshape.turn.up.forward.circle" : "person.crop.circle"
        case .assistant: return "pi"
        case .thinking: return "brain.head.profile"
        case .tool: return entry.title.localizedCaseInsensitiveContains("subagent") ? "person.2.wave.2" : "hammer"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .stderr: return "terminal"
        case .raw: return "curlybraces"
        }
    }

    private var color: Color { roleBase }

    private var copyText: String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

struct PiAgentToolTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: PiAgentTranscriptEntry
    @State private var isExpanded: Bool

    init(entry: PiAgentTranscriptEntry, startsExpanded: Bool = false) {
        self.entry = entry
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 8) {
                Label(toolName, systemImage: icon)
                    .font(AppTheme.Font.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(phaseLabel)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show details") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
            }

            Text(displayText)
                .font(AppTheme.Font.code)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(isExpanded ? nil : 6)
                .textSelection(.enabled)
                .padding(AppTheme.Chat.cardVPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.7)))
        }
    }

    private var toolName: String {
        entry.title.replacingOccurrences(of: "Tool: ", with: "")
    }

    private var phaseLabel: String {
        let lower = entry.text.lowercased()
        if lower.contains("starting") || lower.contains("preparing") { return "starting" }
        if lower.contains("running") || lower.contains("0/1 done") { return "running" }
        if entry.role == .error { return "failed" }
        return "result"
    }

    private var displayText: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details emitted yet." : trimmed
    }

    private var isLong: Bool {
        displayText.count > 600 || displayText.split(separator: "\n").count > 8
    }

    private var icon: String {
        switch toolName.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        entry.role == .error ? AppTheme.roleError : AppTheme.roleTool
    }
}
