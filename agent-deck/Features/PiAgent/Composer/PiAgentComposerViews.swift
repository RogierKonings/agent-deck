import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentComposerBox: View {
    private let maxImages = 8

    @Binding var text: String
    @Binding var pasteAttachments: [PiAgentPasteAttachment]
    @Binding var nextPasteID: Int
    @Binding var images: [PiAgentImageAttachment]
    @Binding var files: [PiAgentFileAttachment]
    @Binding var folders: [PiAgentFolderAttachment]
    @Binding var issueAttachment: PiAgentIssueAttachment?
    @Binding var attachmentError: String?
    @Binding var inputMode: PiAgentInputMode
    let isRunning: Bool
    let isDisabled: Bool
    let placeholder: String
    let canSend: Bool
    let canCreateSession: Bool
    let createSessionProjects: [DiscoveredProject]
    let onFiles: ([URL]) -> Void
    let onFolders: ([URL]) -> Void
    let viewModel: AppViewModel
    let footerSession: PiAgentSessionRecord?
    let transcript: [PiAgentTranscriptEntry]
    let supportedThinkingLevels: [String]
    let metricsSession: PiAgentSessionRecord?
    /// Picked `/`-suggestion (skill / prompt / command). Rendered as a glass
    /// capsule chip above the editor; included in the send payload by the
    /// caller, not by this view.
    var slashSelection: SlashItem? = nil
    var onRemoveSlashSelection: () -> Void = {}
    let onSend: () -> Void
    let onStop: () -> Void
    let onCreateSession: () -> Void
    let onCreateSessionForProject: (DiscoveredProject) -> Void
    let onClear: () -> Void
    var suggestionKeyBridge: ComposerSuggestionKeyBridge = ComposerSuggestionKeyBridge()
    @State private var isDropTargeted = false
    @State private var isIssuePickerPresented = false
    // Memoized: whether the runtime footer shows the subagents toggle. Resolving
    // it (`sessionHasSelectableAgents`) reads the project-scan snapshots; calling
    // it inline in `body` registered those as observation dependencies, so the
    // whole composer re-rendered on every background project re-scan during a
    // streaming session. Computed off the hot path in `.onChange` instead.
    @State private var showsSubagentsToggle = true
    // Non-worktree sessions don't carry `branchName`; resolve the project's
    // current branch off the body hot path via `.task(id:)`.
    @State private var resolvedBranch: String?

    private var displayedBranch: String? {
        if let direct = metricsSession?.branchName, !direct.isEmpty { return direct }
        return resolvedBranch
    }

    private var branchRevealURL: URL? {
        guard let session = metricsSession else { return nil }
        return URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if slashSelection != nil || !images.isEmpty || !files.isEmpty || !folders.isEmpty || issueAttachment != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let slashSelection {
                            PiAgentSlashSelectionChip(item: slashSelection, onRemove: onRemoveSlashSelection)
                        }
                        if let issueAttachment {
                            PiAgentIssueAttachmentChip(issue: issueAttachment) {
                                self.issueAttachment = nil
                            }
                        }
                        ForEach(images) { image in
                            PiAgentImageAttachmentThumbnail(image: image) {
                                images.removeAll { $0.id == image.id }
                            }
                        }
                        ForEach(files) { file in
                            PiAgentFileAttachmentChip(file: file) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                        ForEach(folders) { folder in
                            PiAgentFolderAttachmentChip(folder: folder) {
                                folders.removeAll { $0.id == folder.id }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(AppTheme.Font.body)
                        .foregroundStyle(AppTheme.mutedText.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                PiAgentDropSafeTextEditor(
                    text: $text,
                    pasteAttachments: $pasteAttachments,
                    nextPasteID: $nextPasteID,
                    onDropTargeted: { isDropTargeted = $0 },
                    onImages: addImages,
                    onFiles: onFiles,
                    onFolders: onFolders,
                    onUnsupportedDrop: { attachmentError = "Drop images, files, or folders." },
                    onSend: onSend,
                    onClear: onClear,
                    isDisabled: isDisabled,
                    suggestionKeyBridge: suggestionKeyBridge,
                    onDictationUnavailable: {
                        attachmentError = "Dictation is unavailable. Enable Dictation in System Settings > Keyboard, then try again."
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(minHeight: 92, maxHeight: 132)
                .bottomEdgeFade(height: 18)
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                if let footerSession {
                    HStack(spacing: 10) {
                        PiAgentComposerFooterBar(
                            session: footerSession,
                            viewModel: viewModel,
                            transcript: transcript,
                            supportedThinkingLevels: supportedThinkingLevels
                        )
                        composerActionControls

                        Spacer(minLength: 18)
                        PiAgentSendButton(isRunning: isRunning, canSend: canSend && !isDisabled, sendAction: onSend, stopAction: onStop)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                } else if canCreateSession {
                    HStack(spacing: 10) {
                        Spacer(minLength: 18)
                        PiAgentCreateSessionFromComposerButton(
                            projects: createSessionProjects,
                            action: onCreateSession,
                            onSelectProject: onCreateSessionForProject
                        )
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if let branch = displayedBranch, let revealURL = branchRevealURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                        } label: {
                            HStack(spacing: 3) {
                                Image("branch")
                                    .font(AppTheme.Font.caption2.weight(.semibold))
                                Text(piAgentSessionDisplayBranchName(branch))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                        }
                        .buttonStyle(.plain)
                        .help("\(branch)\n\(revealURL.path)")
                    }

                    if let metricsSession {
                        PiAgentRuntimeFooter(
                            session: metricsSession,
                            showsSubagentsToggle: showsSubagentsToggle,
                            subagentsToggleEnabled: metricsSession.status == .draft,
                            memoryToggleEnabled: metricsSession.status == .draft,
                            memoryEnabled: viewModel.appSettings.agentMemoryEnabled,
                            openAIFastStatus: openAIFastStatus(for: metricsSession),
                            onToggleMemory: {
                                viewModel.setAgentMemoryEnabled(!viewModel.appSettings.agentMemoryEnabled)
                            },
                            onToggleSubagents: {
                                viewModel.setSubagentsEnabledForSelectedDraftAndNewSessions(!metricsSession.subagentsEnabled)
                            },
                            onToggleOpenAIFast: openAIFastToggleAction(for: metricsSession),
                            onSetAsDefault: setAsDefaultAction(for: metricsSession)
                        )
                        // Resolve the toggle's visibility off the body hot path.
                        // The session's agent universe is effectively static for
                        // its lifetime, so refreshing on session-id change is enough.
                        .onChange(of: metricsSession.id, initial: true) {
                            showsSubagentsToggle = viewModel.sessionHasSelectableAgents(metricsSession)
                        }
                    }

                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .appContentSurface(cornerRadius: AppTheme.Chat.composerCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                .stroke(isDropTargeted ? AppTheme.brandAccent.opacity(0.7) : Color.clear, lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay {
            if isDropTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                        .fill(AppTheme.brandAccent.opacity(0.10))
                        .allowsHitTesting(false)
            }
            if isDisabled {
                RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                    .fill(AppTheme.contentFill.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 7)
        .onPasteCommand(of: [.png, .jpeg, .tiff, .gif, .webP, .fileURL]) { _ in
            addImages(PiAgentComposerImageLoader.imagesFromPasteboard())
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff, .gif, .webP, .image], isTargeted: $isDropTargeted) { providers in
            // Defer NSItemProvider loading off the drop callback so AppKit can
            // finish the drag-IPC teardown (kDragIPCLeaveApplication) before
            // we trigger more drag IPC inside loadItem.
            DispatchQueue.main.async {
                PiAgentComposerImageLoader.loadDropItems(from: providers) { attachments, files in
                    let folderURLs = files.filter { PiAgentFolderAttachment(url: $0) != nil }
                    let fileURLs = files.filter { PiAgentFolderAttachment(url: $0) == nil }
                    if attachments.isEmpty && fileURLs.isEmpty && folderURLs.isEmpty {
                        attachmentError = "Drop images, files, or folders."
                    } else {
                        addImages(attachments)
                        onFiles(fileURLs)
                        onFolders(folderURLs)
                    }
                }
            }
            return true
        }
        .task {
            viewModel.ensureComposerIssuesLoaded()
        }
        .task(id: metricsSession?.id) {
            // For worktree-on sessions `branchName` is set at creation; for
            // worktree-off sessions resolve the project's current branch via git.
            // Runs off the body path; refreshed on session-id change.
            guard let session = metricsSession else {
                resolvedBranch = nil
                return
            }
            if let direct = session.branchName, !direct.isEmpty {
                resolvedBranch = nil
                return
            }
            let url = URL(fileURLWithPath: session.projectPath, isDirectory: true)
            let branch = try? await GitRepositoryService().currentBranch(in: url)
            guard !Task.isCancelled else { return }
            resolvedBranch = (branch?.isEmpty == false && branch != "HEAD") ? branch : nil
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous))
    }

    private var composerActionControls: some View {
        AppControlGroup(spacing: 6) {
            if viewModel.githubConnectionState.isConnected && viewModel.selectedGitHubProject?.gitHubRemote != nil {
                Button {
                    isIssuePickerPresented.toggle()
                } label: {
                    Image("github")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .appGlassCircle()
                }
                .buttonStyle(.plain)
                .help("Attach GitHub issue")
                .accessibilityLabel("Attach GitHub issue")
                .popover(isPresented: $isIssuePickerPresented, arrowEdge: .bottom) {
                    PiAgentIssuePickerPopover(
                        viewModel: viewModel,
                        onSelect: { issue in
                            issueAttachment = issue
                            attachmentError = nil
                            isIssuePickerPresented = false
                        }
                    )
                }
            }

            Button(action: attachImagesFromOpenPanel) {
                Image(systemName: "paperclip")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 24, height: 24)
                    .appGlassCircle()
            }
            .buttonStyle(.plain)
            .help("Attach files")
            .accessibilityLabel("Attach files")
            .accessibilityHint("Attach images, text files, or local file paths")
        }
    }

    private func attachImagesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let folderURLs = panel.urls.filter { PiAgentFolderAttachment(url: $0) != nil }
        let fileURLs = panel.urls.filter { PiAgentFolderAttachment(url: $0) == nil }
        let imageAttachments = fileURLs.compactMap { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) }
        let files = fileURLs.filter { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) == nil }
        addImages(imageAttachments)
        onFiles(files)
        onFolders(folderURLs)
    }

    private func openAIFastStatus(for session: PiAgentSessionRecord) -> Bool? {
        openAIFastModel(for: session).map { viewModel.appSettings.openAIFastModeModelIdentifiers.contains($0.identifier) }
    }

    private func openAIFastToggleAction(for session: PiAgentSessionRecord) -> (() -> Void)? {
        guard let model = openAIFastModel(for: session) else { return nil }
        return {
            viewModel.setOpenAIFastMode(model, isEnabled: !viewModel.isOpenAIFastModeEnabled(model))
        }
    }

    private func openAIFastModel(for session: PiAgentSessionRecord) -> AvailableModel? {
        let fallback = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let modelID = session.modelOverrideID ?? session.model ?? fallback?.model
        guard PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: provider, modelID: modelID) else { return nil }
        let baseModelID = modelID?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let identifier = "\(provider ?? "")/\(baseModelID)"
        return viewModel.availableModels.first { $0.identifier == identifier }
            ?? viewModel.enabledAvailableModels.first { $0.identifier == identifier }
    }

    private func currentModel(for session: PiAgentSessionRecord) -> AvailableModel? {
        let fallback = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let modelID = session.modelOverrideID ?? session.model ?? fallback?.model
        // Strip thinking suffix (e.g. "gpt-5.2:high" → "gpt-5.2") before lookup
        let baseModelID = modelID?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let identifier = "\(provider ?? "")/\(baseModelID)"
        return viewModel.availableModels.first { $0.identifier == identifier }
            ?? viewModel.enabledAvailableModels.first { $0.identifier == identifier }
    }

    private func setAsDefaultAction(for session: PiAgentSessionRecord) -> (() -> Void)? {
        let model = currentModel(for: session)
        let thinkingLevel = session.thinkingLevel
        let defaultModel = viewModel.defaultPiAgentModel()
        let defaultThinking = viewModel.piRuntimeDefaultThinkingLevel()
        let modelDiffers = model?.identifier != defaultModel?.identifier
        let resolvedThinking = thinkingLevel ?? defaultThinking
        let thinkingDiffers = resolvedThinking != defaultThinking
        guard modelDiffers || thinkingDiffers else { return nil }
        return { [weak viewModel] in
            if let model {
                viewModel?.setDefaultPiAgentModel(model)
            }
            if let level = thinkingLevel {
                viewModel?.setDefaultPiAgentThinkingLevel(level)
            }
        }
    }

    private func addImages(_ newImages: [PiAgentImageAttachment]) {
        guard !newImages.isEmpty else { return }
        attachmentError = nil
        var next = images
        for image in newImages {
            if next.count >= maxImages {
                attachmentError = "Pi supports up to \(maxImages) images per message."
                break
            }
            if !next.contains(where: { $0.data == image.data }) {
                next.append(image)
            }
        }
        images = next
    }
}

struct PiAgentDropSafeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var pasteAttachments: [PiAgentPasteAttachment]
    @Binding var nextPasteID: Int
    var onDropTargeted: (Bool) -> Void
    var onImages: ([PiAgentImageAttachment]) -> Void
    var onFiles: ([URL]) -> Void
    var onFolders: ([URL]) -> Void
    var onUnsupportedDrop: () -> Void
    var onSend: () -> Void
    var onClear: () -> Void
    var isDisabled: Bool
    var suggestionKeyBridge: ComposerSuggestionKeyBridge
    var onDictationUnavailable: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = DropSafeNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = !isDisabled
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? DropSafeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func startSystemDictation(in textView: NSTextView, onUnavailable: @escaping () -> Void) {
        textView.window?.makeFirstResponder(textView)
        DispatchQueue.main.async {
            guard NSApp.sendAction(Selector(("startDictation:")), to: nil, from: textView) else {
                onUnavailable()
                return
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, DropSafeNSTextViewDropHandler, DropSafeNSTextViewKeyHandler {
        var parent: PiAgentDropSafeTextEditor
        // Tracks the last value pushed to SwiftUI so draggingUpdated (which fires
        // on every mouse move during drag) doesn't write the same value over and
        // over. Each write re-renders the parent and re-registers its .onDrop,
        // which collides with AppKit's drag IPC → kDragIPCWithinWindow reentrancy.
        private var lastReportedDropTargeted: Bool = false

        init(parent: PiAgentDropSafeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func setDropTargeted(_ targeted: Bool) {
            guard lastReportedDropTargeted != targeted else { return }
            lastReportedDropTargeted = targeted
            // Defer to next runloop so AppKit finishes the drag-IPC message that
            // triggered us before SwiftUI mutates state and re-registers drops.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onDropTargeted(targeted)
            }
        }

        func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
            let images = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
            let droppedURLs = PiAgentComposerImageLoader.fileURLs(from: pasteboard).filter { url in
                PiAgentFolderAttachment(url: url) != nil || PiAgentComposerImageLoader.imageAttachment(fromFileURL: url) == nil
            }
            let folders = droppedURLs.filter { PiAgentFolderAttachment(url: $0) != nil }
            let files = droppedURLs.filter { PiAgentFolderAttachment(url: $0) == nil }
            if images.isEmpty && files.isEmpty && folders.isEmpty {
                parent.onUnsupportedDrop()
                return false
            }
            parent.onImages(images)
            parent.onFiles(files)
            parent.onFolders(folders)
            return true
        }

        func handleTextPaste(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
            guard let rawText = pasteboard.string(forType: .string), !rawText.isEmpty else { return false }
            let normalizedText = PiAgentPasteMarkerCodec.normalizedText(from: rawText)
            guard PiAgentPasteMarkerCodec.shouldCollapse(normalizedText) else { return false }

            let pasteID = parent.nextPasteID
            parent.nextPasteID += 1
            let marker = PiAgentPasteMarkerCodec.marker(id: pasteID, text: normalizedText)
            parent.pasteAttachments.append(.init(id: pasteID, marker: marker, text: normalizedText))

            textView.insertText(marker, replacementRange: textView.selectedRange())
            parent.text = textView.string
            return true
        }

        func send() {
            guard !parent.isDisabled else { return }
            parent.onSend()
        }

        func clear() {
            guard !parent.isDisabled else { return }
            parent.onClear()
        }

        func suggestionsActive() -> Bool {
            parent.suggestionKeyBridge.isActive
        }

        func moveSuggestionHighlight(by delta: Int) {
            parent.suggestionKeyBridge.onMove(delta)
        }

        func acceptSuggestionHighlight() -> Bool {
            parent.suggestionKeyBridge.onAccept()
        }

        func dismissSuggestions() {
            parent.suggestionKeyBridge.onDismiss()
        }

        func startDictation(in textView: NSTextView) {
            guard !parent.isDisabled else { return }
            parent.startSystemDictation(in: textView, onUnavailable: parent.onDictationUnavailable)
        }
    }
}

@MainActor
protocol DropSafeNSTextViewDropHandler: AnyObject {
    func setDropTargeted(_ targeted: Bool)
    func handleDrop(_ pasteboard: NSPasteboard) -> Bool
    func handleTextPaste(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool
}

@MainActor
protocol DropSafeNSTextViewKeyHandler: AnyObject {
    func send()
    func clear()
    /// Whether the composer suggestion panel is currently shown. When true, the
    /// text view routes arrows/Tab/Return/Escape to the suggestion handlers below.
    func suggestionsActive() -> Bool
    func moveSuggestionHighlight(by delta: Int)
    /// Returns true if a highlighted suggestion was accepted (and the event consumed).
    func acceptSuggestionHighlight() -> Bool
    func dismissSuggestions()
    func startDictation(in textView: NSTextView)
}

@MainActor
final class DropSafeNSTextView: NSTextView {
    weak var dropHandler: DropSafeNSTextViewDropHandler?
    weak var keyHandler: DropSafeNSTextViewKeyHandler?
    private var lastEscapeAt: TimeInterval?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHandler?.setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHandler?.setDropTargeted(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        dropHandler?.setDropTargeted(false)
        return dropHandler?.handleDrop(sender.draggingPasteboard) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let isReturn = characters == "\r" || characters == "\n"
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])

        if characters.lowercased() == "d", modifiers == .option {
            keyHandler?.startDictation(in: self)
            return
        }

        // While the suggestion panel is open, navigation keys drive the panel
        // instead of the caret / send action.
        if keyHandler?.suggestionsActive() == true {
            switch event.keyCode {
            case 126: keyHandler?.moveSuggestionHighlight(by: -1); return  // up arrow
            case 125: keyHandler?.moveSuggestionHighlight(by: 1); return   // down arrow
            case 53: keyHandler?.dismissSuggestions(); return              // escape
            case 48: if keyHandler?.acceptSuggestionHighlight() == true { return }  // tab
            default: break
            }
            if isReturn && modifiers.isEmpty, keyHandler?.acceptSuggestionHighlight() == true {
                return
            }
        }

        if isReturn && modifiers.isEmpty {
            keyHandler?.send()
            return
        }
        if isReturn && (modifiers.contains(.shift) || modifiers.contains(.command) || modifiers.contains(.option)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }
        if event.keyCode == 53 {
            let now = event.timestamp
            if let lastEscapeAt, now - lastEscapeAt < 0.6 {
                keyHandler?.clear()
                self.lastEscapeAt = nil
                return
            }
            self.lastEscapeAt = now
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if acceptsDrop(pasteboard), dropHandler?.handleDrop(pasteboard) == true {
            return
        }
        if dropHandler?.handleTextPaste(pasteboard, in: self) == true {
            return
        }
        super.paste(sender)
    }

    private func acceptsDrop(_ pasteboard: NSPasteboard) -> Bool {
        !PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard).isEmpty || !PiAgentComposerImageLoader.fileURLs(from: pasteboard).isEmpty
    }
}

