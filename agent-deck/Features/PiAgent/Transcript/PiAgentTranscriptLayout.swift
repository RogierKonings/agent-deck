import AppKit
import SwiftUI

// MARK: - Dynamic bubble width

/// The transcript pane's current content width, published by the AppKit table
/// cell host (`TranscriptTableCellView.configure`). Chat bubbles read this to
/// size themselves as a fraction of the pane — no `GeometryReader`, no extra
/// measurement pass: it is the same width the cell already applies via
/// `.frame(width:)`, so it is stable and only changes on an actual resize.
private struct TranscriptContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 880
}

extension EnvironmentValues {
    var transcriptContentWidth: CGFloat {
        get { self[TranscriptContentWidthKey.self] }
        set { self[TranscriptContentWidthKey.self] = newValue }
    }
}

/// Chat-bubble width policy
///
/// User (question) bubbles **hug their content**: a short message gets a small
/// bubble. This is cheap and jump-free — a user message is immutable once sent,
/// so its width is measured exactly once (then served from cache) and never
/// changes afterwards (user messages never stream).
///
/// Agent reply / tool / plan cards use a **fixed width** (a clamped fraction of
/// the pane, so it degrades gracefully on a narrow window). They never
/// re-measure and never change width while a response streams in — preserving
/// the transcript's "only the bottom child grows, and only vertically"
/// zero-jumpiness design. Tune `replyCapMax` to taste.
@MainActor
enum PiAgentBubbleWidth {
    // Agent reply / tool / plan card width — fixed, content-independent.
    static let replyCapMultiplier: CGFloat = 0.72
    static let replyCapMax: CGFloat = 720

    // User (question) bubble — hugs the message text, within these bounds.
    static let userCapMultiplier: CGFloat = 0.62
    static let userCapMax: CGFloat = 720
    static let userMinWidth: CGFloat = 120
    static let userChrome: CGFloat = 34   // card h-padding (14*2) + a little slack

    /// Fixed width for an agent reply / tool / plan card.
    static func replyCap(for paneWidth: CGFloat) -> CGFloat {
        min(paneWidth * replyCapMultiplier, replyCapMax)
    }

    /// Content-hugging width for a user (question) bubble. Pure arithmetic plus
    /// one cached text measurement — see `MessageTextWidth`.
    ///
    /// `pillsWidth` is the natural unwrapped width of the attachment chip row
    /// (file/skill/command/paste/issue/image chips) — measured at the call
    /// site so a short message with wide pills still grows to fit them
    /// (within the same cap). Pass 0 when there are no chips.
    static func huggedUser(text: String, pillsWidth: CGFloat = 0, paneWidth: CGFloat) -> CGFloat {
        let cap = min(paneWidth * userCapMultiplier, userCapMax)
        // Fenced code renders in a monospace font this measurement can't model;
        // let those messages fill the cap rather than risk wrapping code.
        if text.contains("```") { return cap }
        let textNatural = MessageTextWidth.naturalWidth(of: text)
        let natural = max(textNatural, pillsWidth) + userChrome
        return min(cap, max(natural, min(userMinWidth, cap)))
    }
}

/// Measurement of an attachment chip label in `.caption2`, used by the bubble
/// width calculation so chips can grow the bubble to fit (within the cap).
/// Per-chip width is capped — a single huge filename can't blow the bubble;
/// the chip will middle-truncate beyond that ceiling.
@MainActor
enum ChipLabelWidth {
    private static var cache: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let limit = 256
    private static let attributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.preferredFont(forTextStyle: .caption2)]
    /// Width contribution per chip beyond its label: icon + spacing + glass-capsule
    /// horizontal padding (small button style).
    static let chipChrome: CGFloat = 38
    /// Per-chip cap. Beyond this the chip middle-truncates inside itself instead of
    /// stretching the whole bubble.
    static let perChipMax: CGFloat = 130
    /// HStack inter-chip gap (matches the body HStack spacing).
    static let chipGap: CGFloat = 8

    static func labelWidth(of text: String) -> CGFloat {
        if let cached = cache[text] { return cached }
        let width = (text as NSString).size(withAttributes: attributes).width
        let result = ceil(width)
        cache[text] = result
        order.append(text)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    /// One chip's width = label (capped) + icon/spacing/padding chrome.
    static func chipWidth(for label: String) -> CGFloat {
        min(labelWidth(of: label), perChipMax) + chipChrome
    }

    /// Sum of chip widths plus inter-chip gaps.
    static func rowWidth(forLabels labels: [String]) -> CGFloat {
        guard !labels.isEmpty else { return 0 }
        let chips = labels.map { chipWidth(for: $0) }.reduce(0, +)
        return chips + chipGap * CGFloat(labels.count - 1)
    }
}

/// Cheap, cached measurement of a message's natural (unwrapped) text width —
/// the width below which the body text would begin to wrap. This lets chat
/// bubbles size to their content WITHOUT touching the markdown view's own
/// (carefully tuned) layout / height-measurement path.
@MainActor
enum MessageTextWidth {
    private static var cache: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let limit = 256
    // Bounds work for pathologically long lines; far above any real bubble cap.
    private static let ceiling: CGFloat = 5000
    private static let attributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.preferredFont(forTextStyle: .body)]

    /// Width of the widest line of `text` in the body font. Measures the raw
    /// markdown source, so syntax characters bias the result slightly wide —
    /// the safe direction (a bubble never ends up narrower than its text).
    static func naturalWidth(of text: String) -> CGFloat {
        if let cached = cache[text] { return cached }
        var widest: CGFloat = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let width = (String(line) as NSString).size(withAttributes: attributes).width
            if width > widest { widest = width }
            if widest >= ceiling { break }
        }
        let result = min(ceil(widest), ceiling)
        cache[text] = result
        order.append(text)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}

/// Hover-driven copy-button wrapper for thread messages. Used by
/// `PiAgentTranscriptThreadCard` to place a glass copy button beside user
/// bubbles and assistant cards.
///
/// CRITICAL: the copy button is an `.overlay` on the card, NOT a sibling in
/// the row's HStack. Overlays never contribute to their host's layout size,
/// so the row the AppKit table measures is byte-for-byte the long-stable
/// `HStack { card; Spacer }` layout — adding/removing/animating the copy
/// button cannot change a row's measured height. (A previous version put the
/// button in the HStack; that changed what the offscreen measurement cell
/// saw and reintroduced the card-overlap bug.)
///
/// The button floats into the 60pt `Spacer` gap via `.offset`. `@State` is
/// per-row, so each row tracks its own hover with no cross-row coupling.
/// One option in the fork "Fork as 1:1 agent chat…" submenu. The action is
/// pre-bound to the entry + agent so `ThreadMessageRow` stays agnostic to
/// the upstream session/viewModel types.
struct ForkAgentMenuItem {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
}

