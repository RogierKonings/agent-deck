import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentSubagentPopover: View {
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Deck agents", systemImage: "paperplane")
                    .font(AppTheme.Font.body.weight(.medium))
                Spacer(minLength: 24)
                Toggle("Deck agents", isOn: $isEnabled)
                    .appSwitch()
                    .labelsHidden()
            }
            Text(isEnabled ? "Parent Pi can delegate to Deck agents when useful." : "Deck agent tools are not exposed to this session.")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct PiAgentFileAttachmentChip: View {
    let file: PiAgentFileAttachment
    let onRemove: () -> Void

    var body: some View {
        PiAgentPathAttachmentChip(
            title: file.url.lastPathComponent.isEmpty ? file.url.path : file.url.lastPathComponent,
            path: file.url.path,
            systemImage: "doc.text",
            onRemove: onRemove
        )
    }
}

struct PiAgentFolderAttachmentChip: View {
    let folder: PiAgentFolderAttachment
    let onRemove: () -> Void

    var body: some View {
        PiAgentPathAttachmentChip(
            title: folder.url.lastPathComponent.isEmpty ? folder.url.path : folder.url.lastPathComponent,
            path: folder.url.path,
            systemImage: "folder",
            onRemove: onRemove
        )
    }
}

struct PiAgentIssueAttachmentChip: View {
    let issue: PiAgentIssueAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image("github")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(AppTheme.mutedText)
            Text("#\(issue.number) \(issue.title)")
                .lineLimit(1)
                .truncationMode(.head)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(AppTheme.Font.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .appGlassCapsule()
        .help(issue.repository)
    }
}

struct PiAgentIssuePickerPopover: View {
    var viewModel: AppViewModel
    let onSelect: (PiAgentIssueAttachment) -> Void

    @State private var query = ""
    @State private var isLoading = false
    @State private var loadingIssueID: String?
    @State private var errorText: String?

    private var items: [GitHubWorkItem] {
        let source = viewModel.githubComposerIssueItems
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return source }
        let needle = query.lowercased()
        return source.filter { item in
            item.title.lowercased().contains(needle)
            || item.repository.lowercased().contains(needle)
            || "#\(item.number)".contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach GitHub Issue")
                .font(AppTheme.Font.headline)

            AppTextField(text: $query, placeholder: "Search visible issues")

            if let errorText {
                Text(errorText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.orange)
            }

            if items.isEmpty {
                Text(emptyStateText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 400, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items.prefix(20)) { item in
                            ZStack(alignment: .topTrailing) {
                                GitHubIssueListRow(
                                    item: item,
                                    isSelected: false,
                                    onSelect: { attach(item) }
                                )
                                if loadingIssueID == item.id && isLoading {
                                    AppSpinner()
                                        .controlSize(.small)
                                        .padding(12)
                                }
                            }
                            .disabled(isLoading)
                        }
                    }
                }
                .defaultScrollAnchor(.top)
                .frame(width: 420, height: 320)
            }
        }
        .padding(12)
        .onAppear {
            viewModel.ensureComposerIssuesLoaded()
        }
    }

    private var emptyStateText: String {
        if !viewModel.githubConnectionState.isConnected {
            return "Connect GitHub first to attach an issue."
        }
        if viewModel.selectedGitHubProject?.gitHubRemote != nil {
            return viewModel.githubIsLoadingProjectBoard
                ? "Loading issues for the selected repository…"
                : "No issues loaded for the selected repository yet."
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching issues."
        }
        return "Select a GitHub project to attach one of its issues."
    }

    private func attach(_ item: GitHubWorkItem) {
        isLoading = true
        loadingIssueID = item.id
        errorText = nil
        viewModel.fetchPiAgentIssueAttachment(for: item) { result in
            isLoading = false
            loadingIssueID = nil
            switch result {
            case .success(let issue):
                onSelect(issue)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}

struct PiAgentPathAttachmentChip: View {
    let title: String
    let path: String
    let systemImage: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.brandAccent)
            Text(title)
                .lineLimit(1)
                .truncationMode(.head)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(AppTheme.Font.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .appGlassCapsule()
        .help(path)
    }
}

struct PiAgentImageAttachmentThumbnail: View {
    let image: PiAgentImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.thumbnailCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Chat.thumbnailCornerRadius, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image attachment")
            .offset(x: 6, y: -6)
        }
        .help("\(image.name) · \(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))")
    }
}

enum PiAgentComposerImageLoader {
    nonisolated private static let maxDimension: CGFloat = 2_000
    nonisolated private static let maxEncodedBytes = Int(4.5 * 1024 * 1024)

    nonisolated static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [PiAgentImageAttachment] {
        var attachments: [PiAgentImageAttachment] = []
        let urls = fileURLs(from: pasteboard)
        attachments.append(contentsOf: urls.compactMap(imageAttachment(fromFileURL:)))
        if let data = pasteboard.data(forType: .png), let attachment = imageAttachment(data: data, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        } else if let data = pasteboard.data(forType: .tiff), let pngData = pngData(fromImageData: data), let attachment = imageAttachment(data: pngData, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        }
        return attachments
    }

    nonisolated static func loadImages(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment]) -> Void) {
        loadDropItems(from: providers) { attachments, _ in completion(attachments) }
    }

    nonisolated static func loadDropItems(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment], [URL]) -> Void) {
        let group = DispatchGroup()
        let accumulator = DropItemAccumulator()

        for provider in providers {
            var didScheduleFile = false
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didScheduleFile = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = fileURL(fromProviderItem: item)
                    if let url, let image = imageAttachment(fromFileURL: url) {
                        accumulator.appendImage(image)
                    } else {
                        accumulator.appendFile(url)
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !didScheduleFile {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let png = pngData(fromImageData: data) ?? data
                    accumulator.appendImage(imageAttachment(data: png, name: "dropped-image.png", mimeType: "image/png", fileReference: "dropped-image.png"))
                }
            }
        }

        group.notify(queue: .main) {
            let result = accumulator.result()
            completion(result.attachments, result.files)
        }
    }

    private final class DropItemAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var attachments: [PiAgentImageAttachment] = []
        nonisolated(unsafe) private var files: [URL] = []

        nonisolated init() {}

        nonisolated func appendImage(_ attachment: PiAgentImageAttachment?) {
            guard let attachment else { return }
            lock.lock()
            attachments.append(attachment)
            lock.unlock()
        }

        nonisolated func appendFile(_ url: URL?) {
            guard let url else { return }
            lock.lock()
            files.append(url)
            lock.unlock()
        }

        nonisolated func result() -> (attachments: [PiAgentImageAttachment], files: [URL]) {
            lock.lock()
            let attachments = attachments
            let files = files
            lock.unlock()

            var seen = Set<String>()
            return (attachments, files.filter { seen.insert($0.path).inserted })
        }
    }

    nonisolated private static func fileURL(fromProviderItem item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let value = item as? String {
            return value.hasPrefix("file:") ? URL(string: value) : URL(fileURLWithPath: value)
        }
        if let value = item as? NSString {
            let string = value as String
            return string.hasPrefix("file:") ? URL(string: string) : URL(fileURLWithPath: string)
        }
        return nil
    }

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: read)
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    nonisolated static func imageAttachment(fromFileURL url: URL) -> PiAgentImageAttachment? {
        guard let mimeType = mimeType(for: url), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return imageAttachment(data: data, name: url.lastPathComponent, mimeType: mimeType, fileReference: url.path)
    }

    nonisolated static func imageAttachment(data: Data, name: String, mimeType: String, fileReference: String? = nil) -> PiAgentImageAttachment? {
        guard let processed = processLikePiCLI(data: data, mimeType: mimeType) else { return nil }
        return PiAgentImageAttachment(
            name: name,
            mimeType: processed.mimeType,
            data: processed.data.base64EncodedString(),
            sizeBytes: processed.data.count,
            fileReference: fileReference ?? name,
            dimensionNote: processed.dimensionNote
        )
    }

    @MainActor
    static func previewImage(for attachment: PiAgentImageAttachment) -> NSImage? {
        let key = previewCacheKey(for: attachment)
        if let cached = previewImageCache.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: attachment.data), let image = NSImage(data: data) else { return nil }
        previewImageCache.setObject(image, forKey: key)
        return image
    }

    @MainActor private static let previewImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    @MainActor private static func previewCacheKey(for attachment: PiAgentImageAttachment) -> NSString {
        var hasher = Hasher()
        hasher.combine(attachment.data)
        return "\(attachment.id.uuidString):\(attachment.data.count):\(hasher.finalize())" as NSString
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    nonisolated private static func processLikePiCLI(data: Data, mimeType: String) -> (data: Data, mimeType: String, dimensionNote: String?)? {
        let encodedSize = data.base64EncodedString().utf8.count
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = image.pixelSize
        if originalSize.width <= maxDimension,
           originalSize.height <= maxDimension,
           encodedSize < maxEncodedBytes,
           ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) {
            return (data, mimeType, nil)
        }

        let scale = min(maxDimension / max(originalSize.width, 1), maxDimension / max(originalSize.height, 1), 1)
        var targetSize = CGSize(width: max(1, floor(originalSize.width * scale)), height: max(1, floor(originalSize.height * scale)))
        while targetSize.width >= 1 && targetSize.height >= 1 {
            if let resized = resizedBitmap(from: image, targetSize: targetSize) {
                let candidates = encodedCandidates(from: resized)
                if let candidate = candidates.first(where: { $0.data.base64EncodedString().utf8.count < maxEncodedBytes }) {
                    let dimensionNote = formatDimensionNote(original: originalSize, displayed: targetSize)
                    return (candidate.data, candidate.mimeType, dimensionNote)
                }
            }
            if targetSize.width == 1 && targetSize.height == 1 { break }
            targetSize = CGSize(width: max(1, floor(targetSize.width * 0.75)), height: max(1, floor(targetSize.height * 0.75)))
        }
        return nil
    }

    nonisolated private static func encodedCandidates(from rep: NSBitmapImageRep) -> [(data: Data, mimeType: String)] {
        var candidates: [(Data, String)] = []
        if let png = rep.representation(using: .png, properties: [:]) { candidates.append((png, "image/png")) }
        for quality in [0.80, 0.85, 0.70, 0.55, 0.40] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                candidates.append((jpeg, "image/jpeg"))
            }
        }
        return candidates.sorted(by: { (lhs: (data: Data, mimeType: String), rhs: (data: Data, mimeType: String)) in
            lhs.data.count < rhs.data.count
        })
    }

    nonisolated private static func resizedBitmap(from image: NSImage, targetSize: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    nonisolated private static func formatDimensionNote(original: CGSize, displayed: CGSize) -> String? {
        guard original != displayed else { return nil }
        let scale = original.width / max(displayed.width, 1)
        return "[Image: original \(Int(original.width))x\(Int(original.height)), displayed at \(Int(displayed.width))x\(Int(displayed.height)). Multiply coordinates by \(String(format: "%.2f", scale)) to map to original image.]"
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    nonisolated var pixelSize: CGSize {
        if let rep = representations.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}
