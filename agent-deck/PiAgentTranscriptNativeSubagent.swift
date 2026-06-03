import AppKit
import SwiftUI

// Native (pure AppKit) subagent ("Deck agent") cards — the dominant scroll-hang
// source in subagent-heavy sessions. Hosted, the markdown task previews rebuilt
// their whole NSTextView trees (inside NSHostingView + SwiftUI layout) on every
// scroll vend. Native, they reuse persistent markdown containers and rebuild only
// on content change.
//
// One reusable unit — the "agent block" (glyph · name+outcome · status/metrics ·
// icon actions · capped/expandable task). Single runs render one block in a card;
// parallel runs render a header + a vertical stack of agent cards inside ONE
// outer card (same outline), so they read as a group. No box-in-box-in-box.

// MARK: - Agent block payload

struct NativeAgentBlockPayload {
    var agentName: String
    var statusText: String
    var statusColor: NSColor
    var isActive: Bool
    var avatarURL: URL?
    var outcomePill: String?
    var task: String
    var metrics: [Metric]
    var actions: [Action]

    struct Metric { var icon: String; var text: String }
    struct Action {
        var symbol: String
        var help: String
        var isEnabled: Bool = true
        var isDestructive: Bool = false
        var run: (NSButton) -> Void
    }
}

struct NativeSubagentParallelPayload {
    var title: String          // "Parallel agents"
    var count: Int
    var statusText: String
    var statusColor: NSColor
    var children: [NativeAgentBlockPayload]
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
        avatar.layer?.cornerRadius = 13
        avatar.layer?.masksToBounds = true
        addSubview(avatar)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            avatar.widthAnchor.constraint(equalToConstant: 26),
            avatar.heightAnchor.constraint(equalToConstant: 26),
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
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            avatar.contentTintColor = color
        }
        if isActive { startSpin() } else { ringLayer.removeAnimation(forKey: "spin") }
        needsLayout = true
    }

    private func startSpin() {
        guard ringLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = 2 * Double.pi
        spin.duration = 6; spin.repeatCount = .infinity
        ringLayer.add(spin, forKey: "spin")
    }

    override func layout() {
        super.layout()
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        bgLayer.path = circle; strokeLayer.path = circle
        bgLayer.frame = bounds; strokeLayer.frame = bounds
        ringLayer.frame = bounds
        ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Capped + expandable markdown

/// Markdown that renders to a max height when collapsed (bottom fade + "Show more"
/// toggle) and full height when expanded. Self-measures; the toggle drives the
/// re-measure hook so the row re-tiles.
final class PiAgentNativeExpandableMarkdown: NSView {
    private let clipView = NSView()
    private let container = NativeMarkdownTextContainer()
    private let applier = MarkdownSourceApplier()
    private let fadeLayer = CAGradientLayer()
    private let toggle = NSButton()

    private var clipHeightC: NSLayoutConstraint!
    private(set) var isExpanded = false
    var collapsedCap: CGFloat = 150
    var fadeColor: NSColor = .clear
    var onToggle: (() -> Void)?

    private var currentSource: String?
    private var measuredContentHeight: CGFloat = 0
    private var capped = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        addSubview(clipView)
        container.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(container)
        fadeLayer.isHidden = true
        fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        clipView.layer?.addSublayer(fadeLayer)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isBordered = false
        toggle.bezelStyle = .inline
        toggle.font = NativeTranscriptFont.caption(.semibold)
        toggle.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        toggle.target = self
        toggle.action = #selector(toggleTapped)
        toggle.isHidden = true
        addSubview(toggle)
        clipHeightC = clipView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipHeightC,
            container.topAnchor.constraint(equalTo: clipView.topAnchor),
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            toggle.topAnchor.constraint(equalTo: clipView.bottomAnchor, constant: 4),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(source: String) {
        if source != currentSource { isExpanded = false; currentSource = source }
        applier.apply(source: source, to: container)
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        measuredContentHeight = container.measureHeight(forWidth: width)
        capped = measuredContentHeight > collapsedCap + 24
        let visible = (isExpanded || !capped) ? measuredContentHeight : collapsedCap
        clipHeightC.constant = visible
        toggle.isHidden = !capped
        toggle.title = isExpanded ? "Show less" : "Show more"
        let toggleH = capped ? ceil(toggle.intrinsicContentSize.height) + 4 : 0
        return ceil(visible + toggleH)
    }

    override func layout() {
        super.layout()
        let showFade = capped && !isExpanded
        fadeLayer.isHidden = !showFade
        if showFade {
            fadeLayer.frame = CGRect(x: 0, y: clipView.bounds.height - 30, width: clipView.bounds.width, height: 30)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fadeLayer.colors = [fadeColor.withAlphaComponent(0).cgColor, fadeColor.cgColor]
            }
        }
    }

    @objc private func toggleTapped() { isExpanded.toggle(); onToggle?() }
    func cancel() { applier.cancel() }
}

// MARK: - Reusable agent block

/// One agent's block: glyph + name (+ outcome pill) + status·metrics line + icon
/// actions on the right, then the capped/expandable task. No inner box.
final class PiAgentNativeAgentBlockView: NSView {
    private let glyph = PiAgentNativeSubagentGlyph()
    private let nameLabel = NSTextField(labelWithString: "")
    private let outcomePill = NSTextField(labelWithString: "")
    private let outcomeCapsule = NativeCardSurface()
    private let metaLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()
    let task = PiAgentNativeExpandableMarkdown()

    private var actions: [NativeAgentBlockPayload.Action] = []
    var onToggle: (() -> Void)? { didSet { task.onToggle = onToggle } }

    private let headerToTask: CGFloat = 12

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        outcomePill.font = NativeTranscriptFont.caption2(.medium)
        outcomePill.textColor = AppTheme.ns(AppTheme.mutedText)
        outcomePill.translatesAutoresizingMaskIntoConstraints = false
        outcomeCapsule.translatesAutoresizingMaskIntoConstraints = false
        outcomeCapsule.cardCornerRadius = 5
        outcomeCapsule.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.7))
        outcomeCapsule.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        outcomeCapsule.addSubview(outcomePill)
        outcomeCapsule.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            outcomePill.leadingAnchor.constraint(equalTo: outcomeCapsule.leadingAnchor, constant: 6),
            outcomePill.trailingAnchor.constraint(equalTo: outcomeCapsule.trailingAnchor, constant: -6),
            outcomePill.topAnchor.constraint(equalTo: outcomeCapsule.topAnchor, constant: 2),
            outcomePill.bottomAnchor.constraint(equalTo: outcomeCapsule.bottomAnchor, constant: -2)
        ])

        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, outcomeCapsule])
        nameRow.orientation = .horizontal
        nameRow.spacing = 7
        nameRow.alignment = .centerY
        let titleStack = NSStackView(views: [nameRow, metaLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2

        let headerStack = NSStackView(views: [glyph, titleStack, NSView(), buttonStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .centerY

        addSubview(headerStack)
        addSubview(task)

        let taskBottom = task.bottomAnchor.constraint(equalTo: bottomAnchor)
        taskBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            task.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: headerToTask),
            task.leadingAnchor.constraint(equalTo: leadingAnchor),
            task.trailingAnchor.constraint(equalTo: trailingAnchor),
            taskBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ payload: NativeAgentBlockPayload, fadeColor: NSColor) {
        glyph.configure(color: payload.statusColor, isActive: payload.isActive, avatarURL: payload.avatarURL)
        nameLabel.stringValue = payload.agentName
        if let outcome = payload.outcomePill, !outcome.isEmpty {
            outcomePill.stringValue = outcome
            outcomeCapsule.isHidden = false
        } else {
            outcomeCapsule.isHidden = true
        }
        metaLabel.attributedStringValue = metaLine(payload)
        task.fadeColor = fadeColor
        task.configure(source: payload.task)
        rebuildButtons(payload.actions)
    }

    private func metaLine(_ payload: NativeAgentBlockPayload) -> NSAttributedString {
        let muted = AppTheme.ns(AppTheme.mutedText)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: payload.statusColor, .font: NSFont.systemFont(ofSize: 8)]))
        result.append(NSAttributedString(string: payload.statusText, attributes: [.foregroundColor: payload.statusColor, .font: NativeTranscriptFont.caption(.semibold)]))
        let tail = payload.metrics.map(\.text)
        if !tail.isEmpty {
            result.append(NSAttributedString(string: "  ·  " + tail.joined(separator: "  ·  "), attributes: [.foregroundColor: muted, .font: NativeTranscriptFont.caption()]))
        }
        return result
    }

    private func rebuildButtons(_ payloadActions: [NativeAgentBlockPayload.Action]) {
        actions = payloadActions
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, action) in actions.enumerated() {
            let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            let b = NSButton(image: image ?? NSImage(), target: self, action: #selector(actionTapped(_:)))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.tag = i
            b.isEnabled = action.isEnabled
            b.contentTintColor = action.isDestructive ? .systemRed : AppTheme.ns(AppTheme.mutedText)
            b.toolTip = action.help
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttonStack.addArrangedSubview(b)
        }
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag].run(sender)
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let nameH = ceil(nameLabel.intrinsicContentSize.height)
        let metaH = ceil(metaLabel.intrinsicContentSize.height)
        let headerH = max(34, nameH + 3 + metaH)
        let taskH = task.measuredHeight(forWidth: width)
        return ceil(headerH + headerToTask + taskH)
    }

    func cancel() { task.cancel() }
}

// MARK: - Single subagent card

final class PiAgentNativeSubagentRunCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let block = PiAgentNativeAgentBlockView()
    var onIntrinsicHeightChange: (() -> Void)?
    private let pad: CGFloat = 16

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 16
        addSubview(surface)
        block.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }
        surface.addSubview(block)
        let blockBottom = block.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        blockBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            block.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            block.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            block.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            blockBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeAgentBlockPayload, width rowWidth: CGFloat) {
        let fill = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.55))
        surface.fillColor = fill
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        block.configure(payload, fadeColor: fill)
        needsLayout = true
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        ceil(pad + block.measuredHeight(forWidth: max(1, rowWidth - pad * 2)) + pad)
    }

    func prepareForReuseIfNeeded() { block.cancel() }
}

// MARK: - Parallel subagent card (one outline, stacked agent cards)

final class PiAgentNativeSubagentParallelCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let headerLabel = NSTextField(labelWithString: "")
    private let childStack = NSStackView()
    private var blocks: [PiAgentNativeAgentBlockView] = []
    private var childSurfaces: [NativeCardSurface] = []
    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 16
    private let childPad: CGFloat = 14
    private let childSpacing: CGFloat = 10

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 16
        addSubview(surface)

        headerLabel.lineBreakMode = .byTruncatingTail
        childStack.translatesAutoresizingMaskIntoConstraints = false
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = childSpacing
        surface.addSubview(headerLabel)
        surface.addSubview(childStack)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let stackBottom = childStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        stackBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLabel.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            headerLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            headerLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            childStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            childStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            childStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            stackBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeSubagentParallelPayload, width rowWidth: CGFloat) {
        surface.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.45))
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        headerLabel.attributedStringValue = headerLine(payload)

        // Rebuild child cards if the count changed; otherwise reconfigure in place.
        if blocks.count != payload.children.count {
            childStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            blocks.removeAll(); childSurfaces.removeAll()
            for _ in payload.children {
                let card = NativeCardSurface()
                card.translatesAutoresizingMaskIntoConstraints = false
                card.cardCornerRadius = 12
                let blk = PiAgentNativeAgentBlockView()
                blk.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }
                card.addSubview(blk)
                let b = blk.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -childPad)
                b.priority = NSLayoutConstraint.Priority(999)
                NSLayoutConstraint.activate([
                    blk.topAnchor.constraint(equalTo: card.topAnchor, constant: childPad),
                    blk.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: childPad),
                    blk.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -childPad),
                    b
                ])
                childStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
                blocks.append(blk); childSurfaces.append(card)
            }
        }
        let childFill = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.7))
        for (i, child) in payload.children.enumerated() {
            childSurfaces[i].fillColor = childFill
            childSurfaces[i].strokeColor = AppTheme.ns(AppTheme.contentStroke)
            blocks[i].configure(child, fadeColor: childFill)
        }
        needsLayout = true
    }

    private func headerLine(_ payload: NativeSubagentParallelPayload) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: payload.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]))
        result.append(NSAttributedString(string: "  ·  \(payload.count)", attributes: [
            .font: NativeTranscriptFont.caption(.semibold),
            .foregroundColor: AppTheme.ns(AppTheme.mutedText)
        ]))
        result.append(NSAttributedString(string: "   " + payload.statusText, attributes: [
            .font: NativeTranscriptFont.caption(.semibold),
            .foregroundColor: payload.statusColor
        ]))
        return result
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let headerH = max(20, ceil(headerLabel.intrinsicContentSize.height))
        let childInner = max(1, rowWidth - pad * 2 - childPad * 2)
        var h = pad + headerH + 12
        for (i, blk) in blocks.enumerated() {
            if i > 0 { h += childSpacing }
            h += childPad + blk.measuredHeight(forWidth: childInner) + childPad
        }
        h += pad
        return ceil(h)
    }

    func prepareForReuseIfNeeded() { blocks.forEach { $0.cancel() } }
}

// MARK: - Factories (computed in the items pass; views are dumb renderers)

enum NativeSubagentFactory {
    static func isParallel(_ run: PiSubagentRunRecord) -> Bool {
        run.mode == .parallel && (run.children?.isEmpty == false)
    }

    static func statusColor(_ status: PiSubagentRunStatus) -> NSColor {
        switch status {
        case .queued, .starting, .running: return .systemBlue
        case .blocked: return .systemOrange
        case .completed: return .systemGreen
        case .failed: return .systemRed
        case .stopped, .disconnected: return .secondaryLabelColor
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func formattedDuration(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func compactNumber(_ v: Int) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
        if v >= 1_000 { return "\(v / 1_000)k" }
        return "\(v)"
    }

    static func metrics(duration: Int?, tokens: Int?, tools: Int?, model: String?, thinking: String?) -> [NativeAgentBlockPayload.Metric] {
        var m: [NativeAgentBlockPayload.Metric] = []
        if let duration { m.append(.init(icon: "timer", text: formattedDuration(duration))) }
        if let tokens { m.append(.init(icon: "tugriksign.circle", text: compactNumber(tokens))) }
        if let tools { m.append(.init(icon: "wrench.and.screwdriver", text: "\(tools)")) }
        if let model = nonEmpty(model) { m.append(.init(icon: "cpu", text: model)) }
        if let thinking = nonEmpty(thinking) { m.append(.init(icon: "brain.head.profile", text: thinking)) }
        return m
    }

    static func showTextPopover(title: String, text: String, from sender: NSButton) {
        let pop = NSPopover(); pop.behavior = .transient
        pop.contentViewController = PiAgentNativeTextPopoverController(title: title, text: text)
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

extension NativeAgentBlockPayload {
    /// Single-run block built from a run record.
    @MainActor
    static func makeSingle(
        run: PiSubagentRunRecord,
        imageStore: AgentImageStore,
        onStop: @escaping () -> Void,
        onTranscript: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) -> NativeAgentBlockPayload {
        let artifactDir = run.child?.artifactDirectory ?? run.artifactDirectory
        let sysPromptURL = URL(fileURLWithPath: artifactDir).appendingPathComponent("final-system-prompt.md")
        let canSys = FileManager.default.fileExists(atPath: sysPromptURL.path)

        let duration = run.child?.durationMs ?? run.durationMs
        let tokens = run.child?.totalTokens ?? sum(run.children?.compactMap(\.totalTokens))
        let tools = run.child?.toolCount ?? sum(run.children?.compactMap(\.toolCount))
        let model = run.model ?? run.child?.model ?? run.children?.compactMap(\.model).first

        var detailRows: [(String, String)] = [("Deck agent ID", run.id.uuidString)]
        if let duration { detailRows.append(("Duration", NativeSubagentFactory.formattedDuration(duration))) }
        if let tokens { detailRows.append(("Tokens", NativeSubagentFactory.compactNumber(tokens))) }
        if let tools { detailRows.append(("Tools", "\(tools)")) }
        if let model = NativeSubagentFactory.nonEmpty(model) { detailRows.append(("Model", model)) }
        if let thinking = NativeSubagentFactory.nonEmpty(run.thinking) { detailRows.append(("Thinking", thinking)) }
        if let outcome = run.expectedOutcome {
            detailRows.append(("Outcome", outcome.displayName + (run.requestedOutputPath.map { " · \($0)" } ?? "")))
        }
        let canReveal = !run.artifactDirectory.isEmpty

        var actions: [Action] = [
            Action(symbol: "info.circle", help: "Run details") { sender in
                let pop = NSPopover(); pop.behavior = .transient
                pop.contentViewController = PiAgentNativeKeyValuePopover(title: "Run details", rows: detailRows, revealAction: canReveal ? onReveal : nil)
                pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            },
            Action(symbol: "doc.text.magnifyingglass", help: "Final runtime system prompt", isEnabled: canSys) { sender in
                let text = (try? String(contentsOf: sysPromptURL, encoding: .utf8)) ?? "System prompt unavailable."
                NativeSubagentFactory.showTextPopover(title: "Final Runtime System Prompt", text: text, from: sender)
            },
            Action(symbol: "text.bubble", help: "Open transcript") { _ in onTranscript() }
        ]
        if run.status.isActive {
            actions.append(Action(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in onStop() })
        }

        return NativeAgentBlockPayload(
            agentName: run.agentName,
            statusText: run.status.rawValue.capitalized,
            statusColor: NativeSubagentFactory.statusColor(run.status),
            isActive: run.status.isActive,
            avatarURL: imageStore.imageURL(for: run.agentName),
            outcomePill: run.expectedOutcome?.displayName,
            task: run.task,
            metrics: NativeSubagentFactory.metrics(duration: duration, tokens: tokens, tools: tools, model: model, thinking: run.thinking),
            actions: actions
        )
    }

    private static func sum(_ values: [Int]?) -> Int? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

extension NativeSubagentParallelPayload {
    @MainActor
    static func make(
        run: PiSubagentRunRecord,
        imageStore: AgentImageStore,
        onOpenChildTranscript: @escaping (UUID) -> Void,
        onStopChild: @escaping (UUID) -> Void
    ) -> NativeSubagentParallelPayload {
        let children = (run.children ?? []).map { child -> NativeAgentBlockPayload in
            let task = NativeSubagentFactory.nonEmpty(child.task)
                ?? NativeSubagentFactory.nonEmpty(child.summary ?? child.error)
                ?? "No task captured."
            let sysURL = URL(fileURLWithPath: child.artifactDirectory ?? "").appendingPathComponent("final-system-prompt.md")
            let canSys = (child.artifactDirectory?.isEmpty == false) && FileManager.default.fileExists(atPath: sysURL.path)

            var actions: [NativeAgentBlockPayload.Action] = [
                .init(symbol: "doc.text.magnifyingglass", help: "Final runtime system prompt", isEnabled: canSys) { sender in
                    let text = (try? String(contentsOf: sysURL, encoding: .utf8)) ?? "System prompt unavailable."
                    NativeSubagentFactory.showTextPopover(title: "Final Runtime System Prompt", text: text, from: sender)
                }
            ]
            if let execID = child.executionRunID {
                actions.append(.init(symbol: "text.bubble", help: "Open transcript") { _ in onOpenChildTranscript(execID) })
                if child.status.isActive {
                    actions.append(.init(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in onStopChild(execID) })
                }
            }

            return NativeAgentBlockPayload(
                agentName: child.agentName,
                statusText: child.status.rawValue.capitalized,
                statusColor: NativeSubagentFactory.statusColor(child.status),
                isActive: child.status.isActive,
                avatarURL: imageStore.imageURL(for: child.agentName),
                outcomePill: child.expectedOutcome?.displayName,
                task: task,
                metrics: NativeSubagentFactory.metrics(duration: child.durationMs, tokens: child.totalTokens, tools: child.toolCount, model: child.model, thinking: nil),
                actions: actions
            )
        }
        return NativeSubagentParallelPayload(
            title: "Parallel agents",
            count: children.count,
            statusText: run.status.rawValue.capitalized,
            statusColor: NativeSubagentFactory.statusColor(run.status),
            children: children
        )
    }
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
