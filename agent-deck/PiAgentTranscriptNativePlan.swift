import AppKit
import SwiftUI

// Native (pure AppKit) "Plan" card for the transcript. Hosted, the plan card
// rebuilt its full SwiftUI subtree (header + per-item rows + progress ring) on
// every scroll vend inside an NSHostingView. Native, it is a dumb renderer fed a
// plain payload computed once in the items pass.
//
// Layout mirrors the SwiftUI plan card: a header (checklist glyph + "Plan" +
// short id capsule + progress ring/count) over a list of plan items, each a
// small status circle + wrapping title, separated by hairline dividers. Full
// width chrome card (NOT reply-capped).

// MARK: - Payload (plain values; the view is a dumb renderer)

struct NativePlanCardPayload {
    var title: String
    var subtitle: String
    var progressText: String
    var progressFraction: Double
    var progressColor: NSColor
    var items: [Item]

    struct Item {
        var iconSymbol: String
        var iconColor: NSColor
        /// Background tint behind the status glyph (color at a low opacity).
        var iconFill: NSColor
        var title: String
        var titleColor: NSColor
        var strikethrough: Bool
    }
}

extension NativePlanCardPayload {
    @MainActor
    static func make(event: PiSessionPlanEventRecord) -> NativePlanCardPayload {
        let items = event.items
        let doneCount = items.filter { $0.status == .done || $0.status == .skipped }.count
        let allDone = !items.isEmpty && doneCount == items.count
        let progressColor: NSColor = allDone ? .systemGreen : AppTheme.ns(AppTheme.brandAccent)

        let rows: [Item] = items.map { item in
            let color = statusColor(item.status)
            let isMuted = item.status == .done || item.status == .skipped
            return Item(
                iconSymbol: statusIcon(item.status),
                iconColor: color,
                iconFill: AppTheme.ns(statusColorSwiftUI(item.status).opacity(item.status == .todo ? 0.08 : 0.14)),
                title: item.title,
                titleColor: isMuted ? AppTheme.ns(AppTheme.mutedText) : .labelColor,
                strikethrough: isMuted
            )
        }

        return NativePlanCardPayload(
            title: "Plan",
            subtitle: String(event.planID.uuidString.prefix(8)),
            progressText: "\(doneCount)/\(items.count)",
            progressFraction: items.isEmpty ? 0 : Double(doneCount) / Double(items.count),
            progressColor: progressColor,
            items: rows
        )
    }

    private static func statusIcon(_ status: PiSessionPlanItemStatus) -> String {
        switch status {
        case .todo: return "circle"
        case .inProgress: return "smallcircle.filled.circle"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private static func statusColorSwiftUI(_ status: PiSessionPlanItemStatus) -> Color {
        switch status {
        case .todo: return AppTheme.mutedText
        case .inProgress: return .blue
        case .done: return .green
        case .blocked: return .orange
        case .skipped: return AppTheme.mutedText
        }
    }

    private static func statusColor(_ status: PiSessionPlanItemStatus) -> NSColor {
        AppTheme.ns(statusColorSwiftUI(status))
    }
}

// MARK: - Progress ring (stroke track + trimmed accent arc)

private final class PiAgentNativePlanProgressRing: NSView {
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for l in [trackLayer, arcLayer] {
            l.fillColor = NSColor.clear.cgColor
            l.lineWidth = 2.5
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        trackLayer.strokeColor = AppTheme.ns(AppTheme.contentStroke).cgColor
        // Disable implicit layer animations so a recycled cell never paints the
        // previous occupant's arc for a frame.
        for l in [trackLayer, arcLayer] {
            l.actions = ["path": NSNull(), "strokeEnd": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(fraction: Double, color: NSColor) {
        self.fraction = max(0, min(1, fraction))
        arcLayer.strokeColor = color.cgColor
        arcLayer.strokeEnd = CGFloat(self.fraction)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        trackLayer.strokeColor = AppTheme.ns(AppTheme.contentStroke).cgColor
    }

    override func layout() {
        super.layout()
        let inset = trackLayer.lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let circle = CGPath(ellipseIn: rect, transform: nil)
        for l in [trackLayer, arcLayer] {
            l.frame = bounds
            l.path = circle
        }
        // Start the arc at 12 o'clock, growing clockwise (matches the SwiftUI
        // ring: trim from 0 then rotate −90°).
        arcLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arcLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arcLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
    }
}

// MARK: - Single plan-item row (status glyph + wrapping title)

private final class PiAgentNativePlanItemView: NSView {
    private let glyphBg = NSView()
    private let glyph = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")

    private static let glyphSize: CGFloat = 20
    static let glyphColumn: CGFloat = glyphSize
    static let glyphGap: CGFloat = 9

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyphBg.translatesAutoresizingMaskIntoConstraints = false
        glyphBg.wantsLayer = true
        glyphBg.layer?.cornerRadius = Self.glyphSize / 2
        glyphBg.layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSubview(glyphBg)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        glyphBg.addSubview(glyph)

        titleLabel.font = NativeTranscriptFont.callout()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 3
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        let titleBottom = titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        titleBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            glyphBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyphBg.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphBg.widthAnchor.constraint(equalToConstant: Self.glyphSize),
            glyphBg.heightAnchor.constraint(equalToConstant: Self.glyphSize),
            glyphBg.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            glyph.centerXAnchor.constraint(equalTo: glyphBg.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphBg.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: glyphBg.trailingAnchor, constant: Self.glyphGap),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ item: NativePlanCardPayload.Item) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyphBg.layer?.backgroundColor = item.iconFill.cgColor
        }
        glyph.image = NSImage(systemSymbolName: item.iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.caption2Size, weight: .bold))
        glyph.contentTintColor = item.iconColor
        if item.strikethrough {
            titleLabel.attributedStringValue = NSAttributedString(string: item.title, attributes: [
                .font: NativeTranscriptFont.callout(),
                .foregroundColor: item.titleColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: AppTheme.ns(AppTheme.mutedText)
            ])
        } else {
            titleLabel.stringValue = item.title
            titleLabel.textColor = item.titleColor
        }
    }

    /// Inner-content height for the given available row width (excludes the row's
    /// own .vertical padding, which the card adds).
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - Self.glyphColumn - Self.glyphGap)
        titleLabel.preferredMaxLayoutWidth = textWidth
        return max(Self.glyphSize, ceil(titleLabel.intrinsicContentSize.height))
    }
}

// MARK: - Plan card view (dumb renderer)

final class PiAgentNativePlanCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()

    // Header.
    private let headerGlyphBg = NSView()
    private let headerGlyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleCapsule = NativeCardSurface()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressRing = PiAgentNativePlanProgressRing()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressCapsule = NSGlassEffectView()

    // Items.
    private let itemsStack = NSStackView()
    private var itemViews: [PiAgentNativePlanItemView] = []
    private var dividers: [NSView] = []
    private let emptyLabel = NSTextField(labelWithString: "No active plan items")

    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 12
    private let headerToList: CGFloat = 10
    private let itemVPad: CGFloat = 7        // SwiftUI .padding(.vertical, 7) per item
    private let dividerLeadingInset: CGFloat = 30
    private var lastPayload: NativePlanCardPayload?

    private var surfaceWidthC: NSLayoutConstraint!
    private var itemsTopC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = AppTheme.Chat.cardCornerRadius
        addSubview(surface)

        // Header glyph: checklist in a tinted circle.
        headerGlyphBg.translatesAutoresizingMaskIntoConstraints = false
        headerGlyphBg.wantsLayer = true
        headerGlyphBg.layer?.cornerRadius = 11
        headerGlyphBg.layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        headerGlyph.translatesAutoresizingMaskIntoConstraints = false
        headerGlyph.imageScaling = .scaleNone
        headerGlyph.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
        headerGlyphBg.addSubview(headerGlyph)
        surface.addSubview(headerGlyphBg)

        titleLabel.font = NativeTranscriptFont.callout(.semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(titleLabel)

        // Short-id capsule (monospaced).
        subtitleLabel.font = NativeTranscriptFont.captionMono(.medium)
        subtitleLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleCapsule.translatesAutoresizingMaskIntoConstraints = false
        subtitleCapsule.cardCornerRadius = 7
        subtitleCapsule.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.72))
        subtitleCapsule.strokeColor = .clear
        subtitleCapsule.addSubview(subtitleLabel)
        subtitleCapsule.setContentHuggingPriority(.required, for: .horizontal)
        subtitleCapsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        surface.addSubview(subtitleCapsule)

        // Progress capsule (glass): ring + count.
        progressRing.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = NativeTranscriptFont.caption2(.semibold)
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        let progressStack = NSStackView(views: [progressRing, progressLabel])
        progressStack.orientation = .horizontal
        progressStack.spacing = 5
        progressStack.alignment = .centerY
        progressStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        progressCapsule.translatesAutoresizingMaskIntoConstraints = false
        progressCapsule.cornerRadius = 11
        progressCapsule.contentView = progressStack
        progressCapsule.setContentHuggingPriority(.required, for: .horizontal)
        surface.addSubview(progressCapsule)

        emptyLabel.font = NativeTranscriptFont.callout()
        emptyLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        surface.addSubview(emptyLabel)

        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = 0
        surface.addSubview(itemsStack)

        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        itemsTopC = itemsStack.topAnchor.constraint(equalTo: headerGlyphBg.bottomAnchor, constant: headerToList)
        let itemsBottom = itemsStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        itemsBottom.priority = NSLayoutConstraint.Priority(999)
        let emptyBottom = emptyLabel.bottomAnchor.constraint(lessThanOrEqualTo: surface.bottomAnchor, constant: -pad)
        emptyBottom.priority = NSLayoutConstraint.Priority(998)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,

            headerGlyphBg.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            headerGlyphBg.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            headerGlyphBg.widthAnchor.constraint(equalToConstant: 22),
            headerGlyphBg.heightAnchor.constraint(equalToConstant: 22),
            headerGlyph.centerXAnchor.constraint(equalTo: headerGlyphBg.centerXAnchor),
            headerGlyph.centerYAnchor.constraint(equalTo: headerGlyphBg.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: headerGlyphBg.trailingAnchor, constant: 9),
            titleLabel.firstBaselineAnchor.constraint(equalTo: subtitleLabel.firstBaselineAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerGlyphBg.centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleCapsule.leadingAnchor, constant: 5),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleCapsule.trailingAnchor, constant: -5),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleCapsule.topAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleCapsule.bottomAnchor, constant: -2),
            subtitleCapsule.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            subtitleCapsule.centerYAnchor.constraint(equalTo: headerGlyphBg.centerYAnchor),

            progressCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: subtitleCapsule.trailingAnchor, constant: 8),
            progressCapsule.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            progressCapsule.centerYAnchor.constraint(equalTo: headerGlyphBg.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 13),
            progressRing.heightAnchor.constraint(equalToConstant: 13),

            itemsTopC,
            itemsStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            itemsStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            itemsBottom,

            emptyLabel.topAnchor.constraint(equalTo: headerGlyphBg.bottomAnchor, constant: headerToList),
            emptyLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            emptyLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            emptyBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativePlanCardPayload, width rowWidth: CGFloat) {
        lastPayload = payload
        surface.fillColor = AppTheme.ns(AppTheme.contentFill)
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        surfaceWidthC.constant = max(1, rowWidth)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            headerGlyphBg.layer?.backgroundColor = AppTheme.ns(AppTheme.brandAccent.opacity(0.13)).cgColor
        }
        headerGlyph.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        titleLabel.stringValue = payload.title
        subtitleLabel.stringValue = payload.subtitle
        progressLabel.stringValue = payload.progressText
        progressLabel.textColor = payload.progressColor
        progressRing.configure(fraction: payload.progressFraction, color: payload.progressColor)

        rebuildItems(payload.items)
        needsLayout = true
    }

    private func rebuildItems(_ items: [NativePlanCardPayload.Item]) {
        let isEmpty = items.isEmpty
        emptyLabel.isHidden = !isEmpty
        itemsStack.isHidden = isEmpty
        itemsTopC.isActive = !isEmpty

        // Reuse item views when the count matches; otherwise rebuild the stack.
        if itemViews.count != items.count {
            itemsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            itemViews.removeAll()
            dividers.removeAll()
            for index in items.indices {
                if index > 0 {
                    let divider = NSView()
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    divider.wantsLayer = true
                    divider.layer?.backgroundColor = AppTheme.ns(AppTheme.contentStroke).withAlphaComponent(0.45).cgColor
                    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                    itemsStack.addArrangedSubview(divider)
                    divider.widthAnchor.constraint(equalTo: itemsStack.widthAnchor, constant: -dividerLeadingInset).isActive = true
                    divider.leadingAnchor.constraint(equalTo: itemsStack.leadingAnchor, constant: dividerLeadingInset).isActive = true
                    dividers.append(divider)
                }
                let row = PiAgentNativePlanItemView()
                itemsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: itemsStack.widthAnchor).isActive = true
                itemViews.append(row)
            }
        }
        for (i, item) in items.enumerated() {
            itemViews[i].configure(item)
        }
    }

    // MARK: Measure

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let cardW = max(1, rowWidth)
        let inner = max(1, cardW - pad * 2)
        let headerH: CGFloat = 22   // header glyph circle is the tallest element
        var h = pad + headerH + headerToList

        if let items = lastPayload?.items, !items.isEmpty {
            for (i, row) in itemViews.enumerated() where i < items.count {
                if i > 0 { h += 1 } // divider
                // Each item carries .padding(.vertical, 7) above and below.
                h += itemVPad + row.measuredHeight(forWidth: inner) + itemVPad
            }
        } else {
            emptyLabel.preferredMaxLayoutWidth = inner
            h += ceil(emptyLabel.intrinsicContentSize.height)
        }
        h += pad
        return ceil(h)
    }

    // MARK: Settle (paint at final geometry on first draw after reuse)

    override func viewWillDraw() {
        settleLayoutImmediately()
        super.viewWillDraw()
    }

    func settleLayoutImmediately() {
        surface.layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSubtreeIfNeeded()
        surface.layoutSubtreeIfNeeded()
        CATransaction.commit()
        surface.layer?.removeAllAnimations()
    }

    func prepareForReuseIfNeeded() {}
}
