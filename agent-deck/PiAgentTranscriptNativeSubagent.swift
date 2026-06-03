import AppKit
import SwiftUI

// Native (pure AppKit) single-run subagent ("Deck agent") card. This is the
// dominant scroll-hang source in subagent-heavy sessions: hosted, its markdown
// task preview rebuilt its whole NSTextView tree (inside an NSHostingView, with
// SwiftUI's sizeThatFits machinery on top) every scroll vend. Native, the card
// reuses ONE markdown container across vends and only rebuilds on content change.
//
// Parallel-mode runs (a grid of child tiles) still render hosted for now; this
// covers the single-agent case.

// MARK: - Payload (computed in the items pass; the view is a dumb renderer)

struct NativeSubagentCardPayload {
    var agentName: String
    var shortRunID: String
    var fullRunID: String
    var statusText: String
    var statusColor: NSColor
    var isActive: Bool
    var avatarURL: URL?
    var task: String
    var metrics: [Metric]
    var showGraph: Bool
    var canOpenSystemPrompt: Bool
    var systemPromptText: () -> String
    var detailRows: [(String, String)]
    var canReveal: Bool
    // Actions
    var onStop: () -> Void
    var onTranscript: () -> Void
    var onReveal: () -> Void
    var onGraph: () -> Void

    struct Metric { var icon: String; var text: String }
}

extension NativeSubagentCardPayload {
    /// Build the single-run payload from a run record. Mirrors PiNativeSubagentRunCard's
    /// computed vars (status color, compact metadata, detail rows, artifact checks).
    @MainActor
    static func make(
        run: PiSubagentRunRecord,
        imageStore: AgentImageStore,
        onStop: @escaping () -> Void,
        onTranscript: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onGraph: @escaping () -> Void
    ) -> NativeSubagentCardPayload {
        let artifactDir = run.child?.artifactDirectory ?? run.artifactDirectory
        let sysPromptURL = URL(fileURLWithPath: artifactDir).appendingPathComponent("final-system-prompt.md")
        let canOpenSysPrompt = FileManager.default.fileExists(atPath: sysPromptURL.path)

        let duration = run.child?.durationMs ?? run.durationMs
        let tokens: Int? = run.child?.totalTokens ?? {
            let t = run.children?.compactMap(\.totalTokens) ?? []
            return t.isEmpty ? nil : t.reduce(0, +)
        }()
        let tools: Int? = run.child?.toolCount ?? {
            let c = run.children?.compactMap(\.toolCount) ?? []
            return c.isEmpty ? nil : c.reduce(0, +)
        }()
        let model = nonEmpty(run.model ?? run.child?.model ?? run.children?.compactMap(\.model).first)
        let thinking = nonEmpty(run.thinking)

        var metrics: [Metric] = []
        if let duration { metrics.append(.init(icon: "timer", text: formattedDuration(duration))) }
        if let tokens { metrics.append(.init(icon: "tugriksign.circle", text: compactNumber(tokens))) }
        if let tools { metrics.append(.init(icon: "wrench.and.screwdriver", text: "\(tools)")) }
        if let model { metrics.append(.init(icon: "cpu", text: model)) }
        if let thinking { metrics.append(.init(icon: "brain.head.profile", text: thinking)) }

        var detailRows: [(String, String)] = [("Deck agent ID", run.id.uuidString)]
        if let duration { detailRows.append(("Duration", formattedDuration(duration))) }
        if let tokens { detailRows.append(("Tokens", compactNumber(tokens))) }
        if let tools { detailRows.append(("Tools", "\(tools)")) }
        if let model { detailRows.append(("Model", model)) }
        if let thinking { detailRows.append(("Thinking", thinking)) }
        if let outcome = run.expectedOutcome {
            detailRows.append(("Outcome", outcome.displayName + (run.requestedOutputPath.map { " · \($0)" } ?? "")))
        }
        if let reads = run.readFirstPaths, !reads.isEmpty {
            detailRows.append(("Read first", reads.joined(separator: ", ")))
        }
        if run.isWorktreeIsolated == true {
            detailRows.append(("Worktree status", (run.worktreeStatus ?? .active).rawValue))
        }

        return NativeSubagentCardPayload(
            agentName: run.agentName,
            shortRunID: String(run.id.uuidString.prefix(8)),
            fullRunID: run.id.uuidString,
            statusText: run.status.rawValue.capitalized,
            statusColor: statusColor(run.status),
            isActive: run.status.isActive,
            avatarURL: imageStore.imageURL(for: run.agentName),
            task: run.task,
            metrics: metrics,
            showGraph: run.children?.isEmpty == false,
            canOpenSystemPrompt: canOpenSysPrompt,
            systemPromptText: {
                (try? String(contentsOf: sysPromptURL, encoding: .utf8)) ?? "System prompt unavailable."
            },
            detailRows: detailRows,
            canReveal: !run.artifactDirectory.isEmpty,
            onStop: onStop,
            onTranscript: onTranscript,
            onReveal: onReveal,
            onGraph: onGraph
        )
    }

    /// True when this run renders as a parallel grid (handled by the hosted card),
    /// false for the single-agent card ported here.
    static func isParallel(_ run: PiSubagentRunRecord) -> Bool {
        run.mode == .parallel && (run.children?.isEmpty == false)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func statusColor(_ status: PiSubagentRunStatus) -> NSColor {
        switch status {
        case .queued, .starting, .running: return .systemBlue
        case .blocked: return .systemOrange
        case .completed: return .systemGreen
        case .failed: return .systemRed
        case .stopped, .disconnected: return .secondaryLabelColor
        }
    }

    private static func formattedDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

// MARK: - Activity glyph (avatar + rotating ring when active)

private final class PiAgentNativeSubagentGlyph: NSView {
    private let bgLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let avatar = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bgLayer)
        layer?.addSublayer(strokeLayer)
        layer?.addSublayer(ringLayer)
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.lineWidth = 1
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
        ringLayer.strokeStart = 0
        ringLayer.strokeEnd = 0.22
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 14
        avatar.layer?.masksToBounds = true
        addSubview(avatar)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(color: NSColor, isActive: Bool, avatarURL: URL?) {
        bgLayer.fillColor = color.withAlphaComponent(isActive ? 0.12 : 0.08).cgColor
        strokeLayer.strokeColor = color.withAlphaComponent(isActive ? 0.30 : 0.16).cgColor
        ringLayer.strokeColor = color.cgColor
        ringLayer.isHidden = !isActive
        if let nsImage = AgentImageLoader.image(at: avatarURL) {
            avatar.image = nsImage
            avatar.contentTintColor = nil
        } else {
            avatar.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            avatar.contentTintColor = color
        }
        if isActive { startSpin() } else { ringLayer.removeAnimation(forKey: "spin") }
        needsLayout = true
    }

    private func startSpin() {
        guard ringLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 6
        spin.repeatCount = .infinity
        ringLayer.add(spin, forKey: "spin")
    }

    override func layout() {
        super.layout()
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        bgLayer.path = circle
        strokeLayer.path = circle
        bgLayer.frame = bounds; strokeLayer.frame = bounds
        ringLayer.frame = bounds
        ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Native subagent card view

final class PiAgentNativeSubagentRunCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let glyph = PiAgentNativeSubagentGlyph()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let taskHeader = NSTextField(labelWithString: "TASK")
    private let markdownContainer = NativeMarkdownTextContainer()
    private let markdownApplier = MarkdownSourceApplier()
    private let buttonStack = NSStackView()

    private var payload: NativeSubagentCardPayload?
    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 16
    private let headerToTask: CGFloat = 14
    private let taskHeaderToBody: CGFloat = 6

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 16
        addSubview(surface)

        nameLabel.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [nameLabel, metaLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2

        let headerStack = NSStackView(views: [glyph, titleStack, NSView(), buttonStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 11
        headerStack.alignment = .centerY
        headerStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // "TASK" eyebrow label — small, tracked-out, muted.
        taskHeader.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        taskHeader.textColor = AppTheme.ns(AppTheme.mutedText).withAlphaComponent(0.85)

        markdownContainer.translatesAutoresizingMaskIntoConstraints = false

        surface.addSubview(headerStack)
        surface.addSubview(taskHeader)
        surface.addSubview(markdownContainer)

        let mdBottom = markdownContainer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        mdBottom.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),

            headerStack.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            headerStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            headerStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),

            taskHeader.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: headerToTask),
            taskHeader.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),

            markdownContainer.topAnchor.constraint(equalTo: taskHeader.bottomAnchor, constant: taskHeaderToBody),
            markdownContainer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            markdownContainer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            mdBottom
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeSubagentCardPayload, width rowWidth: CGFloat) {
        self.payload = payload
        surface.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.55))
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        glyph.configure(color: payload.statusColor, isActive: payload.isActive, avatarURL: payload.avatarURL)
        nameLabel.stringValue = payload.agentName
        metaLabel.attributedStringValue = metaLine(payload)
        markdownApplier.apply(source: payload.task, to: markdownContainer)
        rebuildButtons(payload)
        needsLayout = true
    }

    /// "● Completed · 1s · 2.3k · 5 tools · gpt-5" — status word colored, the rest muted.
    private func metaLine(_ payload: NativeSubagentCardPayload) -> NSAttributedString {
        let muted = AppTheme.ns(AppTheme.mutedText)
        let caption = NativeTranscriptFont.caption()
        let captionSemi = NativeTranscriptFont.caption(.semibold)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: payload.statusColor, .font: NSFont.systemFont(ofSize: 8)]))
        result.append(NSAttributedString(string: payload.statusText, attributes: [.foregroundColor: payload.statusColor, .font: captionSemi]))
        let tail = payload.metrics.map(\.text)
        if !tail.isEmpty {
            result.append(NSAttributedString(string: "  ·  " + tail.joined(separator: "  ·  "), attributes: [.foregroundColor: muted, .font: caption]))
        }
        return result
    }

    private func rebuildButtons(_ payload: NativeSubagentCardPayload) {
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonStack.addArrangedSubview(iconButton("info.circle", "Run details", #selector(showDetails(_:))))
        if payload.showGraph {
            buttonStack.addArrangedSubview(iconButton("point.3.connected.trianglepath.dotted", "Graph", #selector(openGraph)))
        }
        let sys = iconButton("doc.text.magnifyingglass", "Final runtime system prompt", #selector(showSystemPrompt(_:)))
        sys.isEnabled = payload.canOpenSystemPrompt
        buttonStack.addArrangedSubview(sys)
        buttonStack.addArrangedSubview(iconButton("text.bubble", "Open transcript", #selector(openTranscript)))
        if payload.isActive {
            let stop = iconButton("stop.circle.fill", "Stop", #selector(stop))
            stop.contentTintColor = .systemRed
            buttonStack.addArrangedSubview(stop)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let b = NSButton(image: image ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .smallSquare
        b.imagePosition = .imageOnly
        b.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        b.toolTip = help
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: Actions

    @objc private func stop() { payload?.onStop() }
    @objc private func openTranscript() { payload?.onTranscript() }
    @objc private func openGraph() { payload?.onGraph() }

    @objc private func showDetails(_ sender: NSButton) {
        guard let payload else { return }
        let vc = PiAgentNativeKeyValuePopover(title: "Run details", rows: payload.detailRows, revealAction: payload.canReveal ? payload.onReveal : nil)
        let pop = NSPopover(); pop.behavior = .transient; pop.contentViewController = vc
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func showSystemPrompt(_ sender: NSButton) {
        guard let payload else { return }
        let pop = NSPopover(); pop.behavior = .transient
        pop.contentViewController = PiAgentNativeTextPopoverController(title: "Final Runtime System Prompt", text: payload.systemPromptText())
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    // MARK: Measure

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let innerWidth = max(1, rowWidth - pad * 2)
        let nameH = ceil(nameLabel.intrinsicContentSize.height)
        let metaH = ceil(metaLabel.intrinsicContentSize.height)
        let headerH = max(36, nameH + 3 + metaH)
        let taskHeaderH = ceil(taskHeader.intrinsicContentSize.height)
        let markdownH = markdownContainer.measureHeight(forWidth: innerWidth)
        return ceil(pad + headerH + headerToTask + taskHeaderH + taskHeaderToBody + markdownH + pad)
    }

    func prepareForReuseIfNeeded() { markdownApplier.cancel() }
}

// MARK: - Native key/value popover (run details)

final class PiAgentNativeKeyValuePopover: NSViewController {
    private let titleText: String
    private let rows: [(String, String)]
    private let revealAction: (() -> Void)?

    init(title: String, rows: [(String, String)], revealAction: (() -> Void)?) {
        self.titleText = title; self.rows = rows; self.revealAction = revealAction
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let title = NSTextField(labelWithString: titleText)
        title.font = NSFont.preferredFont(forTextStyle: .headline)
        stack.addArrangedSubview(title)

        for (k, v) in rows {
            let key = NSTextField(labelWithString: k)
            key.font = NativeTranscriptFont.caption(.semibold)
            key.textColor = AppTheme.ns(AppTheme.mutedText)
            key.setContentHuggingPriority(.required, for: .horizontal)
            let val = NSTextField(labelWithString: v)
            val.font = NativeTranscriptFont.caption()
            val.isSelectable = true
            val.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [key, val])
            row.orientation = .horizontal
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        if revealAction != nil {
            let reveal = NSButton(title: "Reveal Run Folder", target: self, action: #selector(revealTapped))
            reveal.bezelStyle = .rounded
            reveal.controlSize = .small
            stack.addArrangedSubview(reveal)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 430)
        ])
        view = container
    }

    @objc private func revealTapped() { revealAction?() }
}
