import AppKit
import SwiftUI

// Native (pure AppKit) rendering for transcript message bubbles. Replaces the
// SwiftUI card hosted in an NSHostingView for the common text rows so scrolling
// never re-runs SwiftUI layout or re-parses markdown on the layout pass. The
// chrome (rounded fill + stroke, header, hover copy button) is drawn with
// CALayer + native subviews; the body reuses the shared NativeMarkdownTextContainer.

/// Fork affordance for a user-question bubble: the single "Fork as Pi session"
/// action plus an optional list of agents for the "Fork as 1:1 agent chat…"
/// submenu. Carries closures, so the enclosing payload isn't Equatable.
struct ForkModel {
    let onForkSession: () -> Void
    let agentOptions: [ForkAgentOption]
}

struct ForkAgentOption {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
}

/// Typed payload for a native message bubble. Built once in the items pass; the
/// cell configures a `PiAgentNativeBubbleView` from it.
struct NativeBubblePayload {
    enum Role: Equatable { case user, assistant, thinking, tool, error, stderr, status, raw }
    enum CopySide: Equatable { case leading, trailing }

    var role: Role
    var headerTitle: String
    /// SF Symbol name for the header icon; `nil` renders the bundled "pi" logo.
    var iconSymbol: String?
    var markdownSource: String
    /// Small bold label above the body (e.g. "Reasoning" for thinking rows).
    var bodyPrefix: String?
    var copyText: String
    var copySide: CopySide
    /// Thread-child rows use tighter padding (12/9) than standalone cards (14/11).
    var isThreadChild: Bool
    /// User question bubbles hug their content width and sit at the trailing edge.
    var isUserHugged: Bool = false
    /// Hover-revealed fork affordance (user questions only).
    var fork: ForkModel? = nil
}

/// Native message bubble: rounded role-tinted chrome + header + markdown body +
/// hover-revealed glass copy button. Self-measures via `measuredHeight(forWidth:)`;
/// the owning cell adds the row insets and reports height to the coordinator.
final class PiAgentNativeBubbleView: NSView {
    private let bubbleLayer = CALayer()
    private let iconView = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private let markdownContainer = NativeMarkdownTextContainer()
    private let markdownApplier = MarkdownSourceApplier()

    // Hover-revealed copy (+ fork) buttons, real Liquid Glass via NSGlassEffectView,
    // grouped in a horizontal stack pinned to the leading or trailing edge.
    private let buttonStack = NSStackView()
    private let copyGlass = NSGlassEffectView()
    private let copyButton = NSButton()
    private let forkGlass = NSGlassEffectView()
    private let forkButton = NSButton()
    private var trackingArea: NSTrackingArea?

    private var payload: NativeBubblePayload?

    private let headerSpacing: CGFloat = 8
    private let prefixSpacing: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bubbleLayer)
        bubbleLayer.cornerRadius = 16
        bubbleLayer.cornerCurve = .continuous
        bubbleLayer.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = Self.headerFont
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.maximumNumberOfLines = 1
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.font = NSFont.preferredFont(forTextStyle: .caption1).bold()
        prefixLabel.textColor = .secondaryLabelColor
        prefixLabel.isHidden = true

        markdownContainer.translatesAutoresizingMaskIntoConstraints = false
        markdownContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(headerLabel)
        addSubview(prefixLabel)
        addSubview(markdownContainer)

        setupButtons()
        buildConstraints()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Fonts

    /// `.footnote` semibold, expanded width — matches the SwiftUI header.
    static let headerFont: NSFont = {
        let base = NSFont.preferredFont(forTextStyle: .footnote)
        let semibold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let expanded = NSFontDescriptor(fontAttributes: [
            .traits: [NSFontDescriptor.TraitKey.width: 0.2]
        ])
        let merged = semibold.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: 0.2]
        ])
        return NSFont(descriptor: merged, size: base.pointSize)
            ?? NSFont(descriptor: expanded, size: base.pointSize)
            ?? semibold
    }()

    // MARK: Layout

    private var hPad: CGFloat { (payload?.isThreadChild ?? false) ? 12 : 14 }
    private var vPad: CGFloat { (payload?.isThreadChild ?? false) ? 9 : 11 }

    private var leadingC: NSLayoutConstraint!
    private var trailingC: NSLayoutConstraint!
    private var topC: NSLayoutConstraint!
    private var iconLeadingC: NSLayoutConstraint!
    private var mdTopC: NSLayoutConstraint!
    private var mdBottomC: NSLayoutConstraint!
    private var prefixTopC: NSLayoutConstraint!

    private func buildConstraints() {
        iconLeadingC = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad)
        topC = iconView.topAnchor.constraint(equalTo: topAnchor, constant: vPad)
        leadingC = markdownContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad)
        trailingC = markdownContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad)
        mdBottomC = markdownContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad)
        mdTopC = markdownContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        prefixTopC = prefixLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)

        NSLayoutConstraint.activate([
            iconLeadingC, topC,
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            headerLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -hPad),
            prefixLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            leadingC, trailingC, mdTopC, mdBottomC
        ])
    }

    override func layout() {
        super.layout()
        bubbleLayer.frame = bounds
    }

    // MARK: Configure

    func configure(payload: NativeBubblePayload, width: CGFloat) {
        let roleChanged = self.payload?.role != payload.role
            || self.payload?.isThreadChild != payload.isThreadChild
        self.payload = payload

        // Padding can change with style; keep constraints in sync.
        iconLeadingC.constant = hPad
        topC.constant = vPad
        leadingC.constant = hPad
        trailingC.constant = -hPad
        mdBottomC.constant = -vPad

        // Header.
        headerLabel.stringValue = payload.headerTitle
        if let symbol = payload.iconSymbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.contentTintColor = headerColor
        } else {
            iconView.image = NSImage(named: "pi")
            iconView.image?.isTemplate = true
            iconView.contentTintColor = AppTheme.ns(AppTheme.piLogo)
        }

        // Optional body prefix (e.g. "Reasoning").
        if let prefix = payload.bodyPrefix, !prefix.isEmpty {
            prefixLabel.stringValue = prefix
            prefixLabel.isHidden = false
            mdTopC.isActive = false
            prefixTopC.isActive = true
            mdTopC = markdownContainer.topAnchor.constraint(equalTo: prefixLabel.bottomAnchor, constant: prefixSpacing)
            mdTopC.isActive = true
        } else {
            prefixLabel.isHidden = true
            prefixTopC.isActive = false
            mdTopC.isActive = false
            mdTopC = markdownContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
            mdTopC.isActive = true
        }

        // Body — routes through the shared applier (in-place streaming update).
        markdownApplier.apply(source: payload.markdownSource, to: markdownContainer)

        // Fork affordance (user questions only) sits outboard of copy.
        forkGlass.isHidden = payload.fork == nil
        configureButtonStack(side: payload.copySide, hasFork: payload.fork != nil)
        _ = roleChanged
        applyChromeColors()
    }

    // MARK: Chrome colors

    private var headerColor: NSColor {
        guard let role = payload?.role else { return .labelColor }
        return role == .assistant ? AppTheme.ns(AppTheme.piLogo) : .labelColor
    }

    private func roleBaseColor(_ role: NativeBubblePayload.Role) -> NSColor {
        switch role {
        case .user: return AppTheme.ns(AppTheme.roleUser)
        case .assistant: return AppTheme.ns(AppTheme.brandAccent)
        case .thinking: return AppTheme.ns(AppTheme.roleThinking)
        case .tool: return AppTheme.ns(AppTheme.roleTool)
        case .error: return AppTheme.ns(AppTheme.roleError)
        case .stderr: return AppTheme.ns(AppTheme.roleStderr)
        case .status, .raw: return AppTheme.ns(AppTheme.roleStatus)
        }
    }

    private func applyChromeColors() {
        guard let payload else { return }
        let neutral = payload.role == .status || payload.role == .raw
        let base = roleBaseColor(payload.role)
        let fillOpacity: CGFloat = payload.isThreadChild ? AppTheme.roleFillOpacity : AppTheme.roleFillStrongOpacity
        let fill: NSColor = neutral
            ? AppTheme.ns(AppTheme.contentSubtleFill).withAlphaComponent(0.7)
            : base.withAlphaComponent(fillOpacity)
        let stroke: NSColor = neutral
            ? AppTheme.ns(AppTheme.contentStroke)
            : base.withAlphaComponent(AppTheme.roleStrokeOpacity)

        // Resolve through the view's effective appearance so light/dark is exact.
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            bubbleLayer.backgroundColor = fill.cgColor
            bubbleLayer.borderColor = stroke.cgColor
        }
        iconView.contentTintColor = payload.iconSymbol == nil ? AppTheme.ns(AppTheme.piLogo) : headerColor
        headerLabel.textColor = headerColor
        copyButton.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        forkButton.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    // MARK: Height

    /// Bubble height for a given full content width (excludes the row insets the
    /// owning cell adds). Mirrors the SwiftUI VStack(spacing:8) + padding layout.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = max(1, width - hPad * 2)
        var h = vPad + headerRowHeight() + headerSpacing
        if let prefix = payload?.bodyPrefix, !prefix.isEmpty {
            h += ceil(prefixLabel.intrinsicContentSize.height) + prefixSpacing
        }
        h += markdownContainer.measureHeight(forWidth: inner)
        h += vPad
        return ceil(h)
    }

    private func headerRowHeight() -> CGFloat {
        max(16, ceil(headerLabel.intrinsicContentSize.height))
    }

    // MARK: Copy / fork buttons (Liquid Glass)

    private func glassIconButton(_ glass: NSGlassEffectView, _ button: NSButton, symbol: String, help: String, action: Selector) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 14
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        button.target = self
        button.action = action
        glass.contentView = button
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 28),
            glass.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupButtons() {
        glassIconButton(copyGlass, copyButton, symbol: "doc.on.doc", help: "Copy message", action: #selector(copyTapped))
        glassIconButton(forkGlass, forkButton, symbol: "arrow.trianglehead.branch", help: "Fork session…", action: #selector(forkTapped))
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alphaValue = 0
        addSubview(buttonStack)
        buttonStackTopC = buttonStack.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        buttonStackTopC.isActive = true
    }

    private var buttonStackTopC: NSLayoutConstraint!
    private var buttonStackSideC: NSLayoutConstraint?

    /// Rebuilds the button stack order/edge: leading → [fork][copy] pinned left,
    /// trailing → [copy][fork] pinned right (fork always outboard of copy).
    private func configureButtonStack(side: NativeBubblePayload.CopySide, hasFork: Bool) {
        buttonStack.arrangedSubviews.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch side {
        case .leading:
            if hasFork { buttonStack.addArrangedSubview(forkGlass) }
            buttonStack.addArrangedSubview(copyGlass)
        case .trailing:
            buttonStack.addArrangedSubview(copyGlass)
            if hasFork { buttonStack.addArrangedSubview(forkGlass) }
        }
        buttonStackSideC?.isActive = false
        switch side {
        case .leading:
            buttonStackSideC = buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        case .trailing:
            buttonStackSideC = buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        }
        buttonStackSideC?.isActive = true
    }

    @objc private func copyTapped() {
        guard let text = payload?.copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func forkTapped() {
        guard let fork = payload?.fork else { return }
        if fork.agentOptions.isEmpty {
            fork.onForkSession()
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let piItem = NSMenuItem(title: "Fork as Pi session", action: #selector(forkPiSessionSelected), keyEquivalent: "")
        piItem.target = self
        menu.addItem(piItem)
        let parent = NSMenuItem(title: "Fork as 1:1 agent chat…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, option) in fork.agentOptions.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(forkAgentSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !option.isDisabled
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: forkGlass.bounds.height + 2), in: forkGlass)
    }

    @objc private func forkPiSessionSelected() { payload?.fork?.onForkSession() }

    @objc private func forkAgentSelected(_ item: NSMenuItem) {
        guard let options = payload?.fork?.agentOptions, item.tag >= 0, item.tag < options.count else { return }
        options[item.tag].action()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setButtonsVisible(true) }
    override func mouseExited(with event: NSEvent) { setButtonsVisible(false) }

    private func setButtonsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            buttonStack.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Teardown

    func prepareForReuseIfNeeded() {
        markdownApplier.cancel()
    }
}

private extension NSFont {
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
