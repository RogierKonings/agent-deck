import AppKit
import SwiftUI
import Symbols
import os

// Native (pure AppKit) rendering for transcript message bubbles. Replaces the
// SwiftUI card hosted in an NSHostingView for the common text rows so scrolling
// never re-runs SwiftUI layout or re-parses markdown on the layout pass.
//
// Layout mirrors the SwiftUI message row exactly: a full-width row holding a
// fixed-width "card" (rounded role-tinted chrome + header + markdown) on one
// side, with the hover-revealed copy/fork glass buttons floating in the gutter
// on the other side (never overlapping the card, never affecting its height):
//   • replies   → card left-aligned at replyCap; copy floats to the RIGHT
//   • questions → card hugged width, right-aligned; fork+copy float to the LEFT

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

/// A full-width transcript row: a sized, role-tinted card plus hover-revealed
/// glass copy/fork buttons in the gutter. Self-measures via
/// `measuredHeight(forWidth:)`; the owning cell adds the row insets.
final class PiAgentNativeBubbleView: NSView {
    /// The bubble proper — rounded chrome drawn by its own layer; holds the
    /// header + markdown. Sized to `replyCap` / hugged width and aligned left
    /// (replies) or right (questions). The buttons live OUTSIDE it.
    private let cardView = NSView()
    private let iconView = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private let markdownContainer = NativeMarkdownTextContainer()
    private let markdownApplier = MarkdownSourceApplier()

    // Hover-revealed copy (+ fork) buttons, real Liquid Glass via NSGlassEffectView.
    // The glyphs are NSImageViews (not NSButtons) so we can drive the SF Symbol
    // replace transition (doc.on.doc → checkmark) exactly like SwiftUI's
    // .contentTransition(.symbolEffect(.replace)); clicks come via gestures.
    private let buttonStack = NSStackView()
    private let copyGlass = NSGlassEffectView()
    private let copyIcon = NSImageView()
    private let forkGlass = NSGlassEffectView()
    private let forkIcon = NSImageView()
    private var copiedResetWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    private var payload: NativeBubblePayload?

    private let headerSpacing: CGFloat = 8
    private let prefixSpacing: CGFloat = 6
    /// Gap between the card edge and the nearest button, matching the SwiftUI
    /// overlay (button offset 38 = 28pt button + 10pt gap).
    private let gutterGap: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 16
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.borderWidth = 1
        addSubview(cardView)

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
        // The card width is authoritative; the markdown must yield to it rather
        // than push the card wider (which would fight `cardWidthC` and let
        // AppKit break a different constraint per relayout — a source of the
        // card appearing to jump). Low compression resistance = always yields.
        markdownContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cardView.addSubview(iconView)
        cardView.addSubview(headerLabel)
        cardView.addSubview(prefixLabel)
        cardView.addSubview(markdownContainer)

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
        let merged = semibold.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: 0.2]
        ])
        return NSFont(descriptor: merged, size: base.pointSize) ?? semibold
    }()

    // MARK: Layout

    private var hPad: CGFloat { (payload?.isThreadChild ?? false) ? 12 : 14 }
    private var vPad: CGFloat { (payload?.isThreadChild ?? false) ? 9 : 11 }

    // cardView placement / size — a fixed width plus a SINGLE leading
    // constraint whose constant is recomputed from the bubble's real width each
    // layout pass (see applyCardOffset). One constraint can't over-constrain, so
    // the card can never flip sides on a relayout, and recomputing from the live
    // width means it's correct even if `configure` ran before the width settled.
    private var cardWidthC: NSLayoutConstraint!
    private var cardLeadingC: NSLayoutConstraint!
    // inner content (pinned to cardView)
    private var iconLeadingC: NSLayoutConstraint!
    private var iconTopC: NSLayoutConstraint!
    private var mdLeadingC: NSLayoutConstraint!
    private var mdTrailingC: NSLayoutConstraint!
    private var mdBottomC: NSLayoutConstraint!
    private var mdTopC: NSLayoutConstraint!
    private var prefixTopC: NSLayoutConstraint!
    private var prefixLeadingC: NSLayoutConstraint!
    private var headerTrailingC: NSLayoutConstraint!

    private func buildConstraints() {
        cardWidthC = cardView.widthAnchor.constraint(equalToConstant: 100)
        cardLeadingC = cardView.leadingAnchor.constraint(equalTo: leadingAnchor)

        iconLeadingC = iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        iconTopC = iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: vPad)
        headerTrailingC = headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -hPad)
        prefixLeadingC = prefixLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        prefixTopC = prefixLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        mdLeadingC = markdownContainer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        mdTrailingC = markdownContainer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad)
        mdBottomC = markdownContainer.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -vPad)
        // The cell imposes a fixed height (NSView-Encapsulated-Layout-Height). If a
        // measured height is even 1pt short of the markdown's required intrinsic
        // height, that fixed height vs. the required content height is unsatisfiable
        // and AppKit logs a constraint-conflict storm. Let this bottom pin yield
        // (just below required) so the fixed cell height always wins gracefully —
        // the measure is accurate, so in practice this never actually slacks.
        mdBottomC.priority = NSLayoutConstraint.Priority(999)
        mdTopC = markdownContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidthC,
            iconLeadingC, iconTopC,
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            headerLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerTrailingC,
            prefixLeadingC,
            mdLeadingC, mdTrailingC, mdTopC, mdBottomC
        ])
        // A single always-active leading constraint positions the card. Its
        // constant is recomputed from the bubble's REAL width in `layout()`
        // (replies → 0; questions → width − cardWidth, i.e. right-aligned), so
        // it never depends on the width passed to `configure` being final, and
        // there is no second edge pin that could over-constrain and flip which
        // side wins on a relayout (the "shifts on hover" bug).
        cardLeadingC.isActive = true
    }

    /// Recompute the card's leading offset from the bubble's current width so
    /// the placement is correct on every layout pass (no dependency on the
    /// `configure`-time width, no second constraint to conflict with).
    private func applyCardOffset() {
        let target = (payload?.isUserHugged ?? false)
            ? max(0, bounds.width - cardWidthC.constant)
            : 0
        if abs(cardLeadingC.constant - target) > 0.5 {
            cardLeadingC.constant = target
        }
    }

    override func layout() {
        applyCardOffset()
        super.layout()
        cardView.layer?.frame = cardView.bounds
    }

    // MARK: Card sizing

    private func cardWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        guard let payload else { return rowWidth }
        if payload.isUserHugged {
            return max(1, min(rowWidth, PiAgentBubbleWidth.huggedUser(text: payload.markdownSource, paneWidth: rowWidth)))
        }
        return max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    // MARK: Configure

    func configure(payload: NativeBubblePayload, width rowWidth: CGFloat) {
        self.payload = payload

        // Padding can change with style; keep constraints in sync.
        iconLeadingC.constant = hPad
        iconTopC.constant = vPad
        headerTrailingC.constant = -hPad
        prefixLeadingC.constant = hPad
        mdLeadingC.constant = hPad
        mdTrailingC.constant = -hPad
        mdBottomC.constant = -vPad

        // Fix the card width; the leading offset (and thus left/right alignment)
        // is applied from the real bubble width in `layout()` via applyCardOffset.
        let cardW = cardWidth(forRowWidth: rowWidth)
        cardWidthC.constant = cardW
        cardLeadingC.constant = payload.isUserHugged ? max(0, rowWidth - cardW) : 0

        // Header.
        headerLabel.stringValue = payload.headerTitle
        if let symbol = payload.iconSymbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else {
            iconView.image = NSImage(named: "pi")
            iconView.image?.isTemplate = true
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

        // Buttons: presence, order, and which gutter they float in.
        forkGlass.isHidden = payload.fork == nil
        configureButtonStack(side: payload.copySide, hasFork: payload.fork != nil)

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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardView.layer?.backgroundColor = fill.cgColor
            cardView.layer?.borderColor = stroke.cgColor
        }
        iconView.contentTintColor = payload.iconSymbol == nil ? AppTheme.ns(AppTheme.piLogo) : headerColor
        headerLabel.textColor = headerColor
        // Glass button glyphs use the primary label color — matches the SwiftUI
        // AppCopyIconButton / AppForkIconButton (.foregroundStyle(.primary)).
        copyIcon.contentTintColor = .labelColor
        forkIcon.contentTintColor = .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    // MARK: Height

    /// Row height for a given full row width (excludes the cell's row insets).
    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let inner = max(1, cardWidth(forRowWidth: rowWidth) - hPad * 2)
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

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func glassIcon(_ glass: NSGlassEffectView, _ icon: NSImageView, symbol: String, help: String, action: Selector) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 14
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.symbolImage(symbol)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone
        icon.toolTip = help
        glass.contentView = icon
        glass.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 28),
            glass.heightAnchor.constraint(equalToConstant: 28),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupButtons() {
        glassIcon(copyGlass, copyIcon, symbol: "doc.on.doc", help: "Copy message", action: #selector(copyTapped))
        glassIcon(forkGlass, forkIcon, symbol: "arrow.trianglehead.branch", help: "Fork session…", action: #selector(forkTapped))
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alphaValue = 0
        addSubview(buttonStack)
        // Vertically centered on the card — matches the SwiftUI overlay(alignment:
        // .leading/.trailing), which centers the buttons on the card's edge.
        buttonStackCenterC = buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        buttonStackCenterC.isActive = true
    }

    private var buttonStackCenterC: NSLayoutConstraint!
    private var buttonStackSideC: NSLayoutConstraint?

    /// Rebuilds the button stack order/edge and floats it in the gutter beside
    /// the card: leading copy → [fork][copy] to the LEFT of the card; trailing
    /// copy → [copy][fork] to the RIGHT of the card (fork always outboard).
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
            // Float to the LEFT of the (right-aligned) card.
            buttonStackSideC = buttonStack.trailingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: -gutterGap)
        case .trailing:
            // Float to the RIGHT of the (left-aligned) card.
            buttonStackSideC = buttonStack.leadingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: gutterGap)
        }
        buttonStackSideC?.isActive = true
    }

    @objc private func copyTapped() {
        guard let text = payload?.copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Animate doc.on.doc → checkmark and back after ~1.1s, matching the
        // SwiftUI AppCopyIconButton's .symbolEffect(.replace) + copied feedback.
        copiedResetWork?.cancel()
        if let checkmark = Self.symbolImage("checkmark") {
            copyIcon.setSymbolImage(checkmark, contentTransition: .replace)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let doc = Self.symbolImage("doc.on.doc") else { return }
            self.copyIcon.setSymbolImage(doc, contentTransition: .replace)
        }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
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

    override func mouseEntered(with event: NSEvent) { detectHoverMove("enter") { self.setButtonsVisible(true) } }
    override func mouseExited(with event: NSEvent) { detectHoverMove("exit") { self.setButtonsVisible(false) } }

    /// Movement detector for the "You bubble shifts on hover" bug. Records the
    /// card's x before the hover transition, re-checks after layout settles AND
    /// again after the reveal animation, and if the card actually moved writes a
    /// loud line to `/tmp/agentdeck-hover-shift.txt` (+ the OS log) naming the
    /// before→after x and the geometry, so a single hover tells us definitively
    /// whether it moves and which value changed. Always active for question
    /// bubbles (rare event, low noise); set `TranscriptHoverDebug` to also log
    /// the stable (no-move) cases as confirmation.
    private static let hoverLog = Logger(subsystem: "streetcoding.agent-deck", category: "HoverShift")
    private static let hoverDebug = UserDefaults.standard.bool(forKey: "TranscriptHoverDebug")

    private func detectHoverMove(_ phase: String, _ action: () -> Void) {
        let before = cardView.frame.minX
        action()
        layoutSubtreeIfNeeded()
        report(phase: "\(phase)-sync", before: before, after: cardView.frame.minX)
        // The reveal animates alpha (0.15s); re-check after it in case anything
        // shifts the card asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.report(phase: "\(phase)-async", before: before, after: self.cardView.frame.minX)
        }
    }

    private func report(phase: String, before: CGFloat, after: CGFloat) {
        let moved = abs(after - before) > 0.5
        let bf = buttonStack.frame
        let cf = cardView.frame
        // Questions float buttons LEFT of the card; replies float them RIGHT.
        // Either way the button stack must not overlap the card.
        let overCard = (payload?.copySide == .leading)
            ? bf.maxX > cf.minX + 1
            : bf.minX < cf.maxX - 1
        guard moved || overCard || Self.hoverDebug else { return }
        let tag = moved ? "⚠️ MOVED" : "stable"
        let line = "[\(phase)] \(tag) cardMinX \(Int(before))→\(Int(after)) "
            + "hugged=\(payload?.isUserHugged ?? false) side=\(String(describing: payload?.copySide)) "
            + "bubbleW=\(Int(bounds.width)) cardW=\(Int(cardWidthC.constant)) leading=\(Int(cardLeadingC.constant)) "
            + "card=[\(Int(cf.minX)),\(Int(cf.maxX))] buttons=[\(Int(bf.minX)),\(Int(bf.maxX))] "
            + (overCard ? "⚠️BUTTONS-OVER-CARD" : "buttons-in-gutter") + "\n"
        if moved {
            Self.hoverLog.error("YOU-BUBBLE-HOVER \(line, privacy: .public)")
        } else {
            Self.hoverLog.log("YOU-BUBBLE-HOVER \(line, privacy: .public)")
        }
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/agentdeck-hover-shift.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Force the hover buttons visible (used by the offscreen preview harness).
    func previewRevealButtons() { buttonStack.alphaValue = 1 }

    private func setButtonsVisible(_ visible: Bool) {
        // Settle the stack's frame BEFORE animating opacity, so the first reveal
        // fades in place instead of sliding in from x=0 (the "jumps on hover" bug).
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = false
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
