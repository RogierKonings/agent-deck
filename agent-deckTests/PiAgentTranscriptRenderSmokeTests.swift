import AppKit
import SwiftUI
import XCTest
@testable import agent_deck

@MainActor
final class PiAgentTranscriptRenderSmokeTests: XCTestCase {
    override func setUp() async throws {
        PiExecutableResolver.resetCachedExecutableForTesting()
    }

    /// Programmatic `NSWindow`s default to `isReleasedWhenClosed = true`, which
    /// under ARC over-releases the window when `close()` runs. The corpse — and
    /// the `_NSWindowTransformAnimation` AppKit attaches when the window orders
    /// front — then blows up minutes later inside an unrelated test's CA commit
    /// (SIGSEGV in `-[_NSWindowTransformAnimation dealloc]`), which made the
    /// whole suite intermittently crash. Build test windows safely: no ARC
    /// double-release, no order-front animation.
    private func makeRenderWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = contentView
        window.orderFrontRegardless()
        return window
    }

    func testMarkdownHighlightingUsesThemeColorsAndToggleOnlyChangesAttributes() {
        let manager = ThemeManager.shared
        let previousTheme = manager.activeTheme
        let previousHighlighting = manager.markdownHighlightingEnabled
        defer {
            manager.apply(previousTheme)
            manager.setMarkdownHighlightingEnabled(previousHighlighting)
        }

        manager.apply(.defaultTheme)
        manager.setMarkdownHighlightingEnabled(true)
        let source = """
        # Heading

        **Strong**, *emphasis*, and `code` with [link](https://example.com).

        - Item
        1. Ordered

        > Quote

        ```swift
        let value = 1
        ```
        """
        let highlighted = TranscriptAttributedStringBuilder.attributedString(for: source)

        assertColor(
            highlighted,
            substring: "Heading",
            equals: AppTheme.ns(AppTheme.markdownHeading)
        )
        assertColor(
            highlighted,
            substring: "Strong",
            equals: AppTheme.ns(AppTheme.markdownStrong)
        )
        assertColor(
            highlighted,
            substring: "emphasis",
            equals: AppTheme.ns(AppTheme.markdownEmphasis)
        )
        assertColor(
            highlighted,
            substring: "code",
            equals: AppTheme.ns(AppTheme.markdownCode)
        )
        assertColor(
            highlighted,
            substring: "link",
            equals: AppTheme.ns(AppTheme.markdownLinkText)
        )
        assertColor(
            highlighted,
            substring: "•",
            equals: AppTheme.ns(AppTheme.markdownListMarker)
        )
        assertColor(
            highlighted,
            substring: "1.",
            equals: AppTheme.ns(AppTheme.markdownListEnumeration)
        )
        assertColor(
            highlighted,
            substring: "Quote",
            equals: AppTheme.ns(AppTheme.markdownQuote)
        )
        XCTAssertTrue(font(in: highlighted, substring: "Quote")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        assertColor(
            highlighted,
            substring: "let value = 1",
            equals: AppTheme.ns(AppTheme.markdownCode)
        )
        let headingRange = (highlighted.string as NSString).range(of: "Heading")
        XCTAssertEqual(
            highlighted.attribute(.underlineStyle, at: headingRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        manager.setMarkdownHighlightingEnabled(false)
        let neutral = TranscriptAttributedStringBuilder.attributedString(for: source)

        XCTAssertEqual(neutral.string, highlighted.string)
        XCTAssertFalse(colorsMatch(
            color(in: neutral, substring: "Heading"),
            AppTheme.ns(AppTheme.markdownHeading)
        ))
        XCTAssertFalse(colorsMatch(
            color(in: neutral, substring: "Strong"),
            AppTheme.ns(AppTheme.markdownStrong)
        ))
        XCTAssertFalse(colorsMatch(
            color(in: neutral, substring: "code"),
            AppTheme.ns(AppTheme.markdownCode)
        ))
        XCTAssertFalse(font(in: neutral, substring: "Quote")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    func testSingleLineMarkdownBlockquoteDoesNotExpandVertically() throws {
        let source = """
        The `slkiser/opencode-quota` project supports OpenCode Go, but importantly its README says:

        > OpenCode Go — Quota source: Dashboard scraping

        It does **not** use the Go API key for quota. It requires:
        """
        let host = NSHostingView(rootView: MarkdownTextView(source: source).frame(width: 620, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 1_000)

        let window = makeRenderWindow(contentView: host)
        defer { window.close() }

        runMainLoop(iterations: 6, delay: 0.02)
        host.layoutSubtreeIfNeeded()

        let height = host.fittingSize.height
        XCTAssertLessThan(
            height,
            180,
            "A single-line Markdown blockquote should render near normal paragraph height, not with a large empty vertical gap. Actual height: \(height)."
        )
    }

    func testTranscriptStackFirstPaintIsNotBlankAfterInitialBottomScroll() throws {
        let host = NSHostingView(rootView: PiAgentTranscriptFirstPaintSmokeView(
            rows: (0..<80).map { "Transcript row \($0)" }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        let window = makeRenderWindow(contentView: host)
        defer { window.close() }

        runMainLoop(iterations: 10, delay: 0.03)
        host.layoutSubtreeIfNeeded()

        let paintedSamples = try nonWhiteSampleCount(in: host)
        XCTAssertGreaterThan(
            paintedSamples,
            100,
            "Transcript first paint rendered blank. This usually means the scroll stack did not materialize rows before manual scrolling."
        )
    }

    func testTranscriptStackDoesNotBlankAfterAppendingAndBottomScroll() throws {
        let host = NSHostingView(rootView: PiAgentTranscriptAppendSmokeView())
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        let window = makeRenderWindow(contentView: host)
        defer { window.close() }

        runMainLoop(iterations: 12, delay: 0.03)
        host.layoutSubtreeIfNeeded()

        let paintedSamples = try nonWhiteSampleCount(in: host)
        XCTAssertGreaterThan(
            paintedSamples,
            100,
            "Transcript rendered blank after appending a sent-message row and scrolling to bottom."
        )
    }

    func testHiddenThinkingMergesAdjacentDiffCardsButVisibleThinkingKeepsThemSplit() {
        let sessionID = UUID()
        func editGroup(file: String) -> PiAgentThreadToolGroup {
            let entry = PiAgentTranscriptEntry(
                sessionID: sessionID, role: .tool, title: "Tool: edit", text: file
            )
            let activity = PiAgentTranscriptActivity(
                id: entry.id, name: "edit", entries: [entry], isError: false,
                compactDetail: nil, webLinks: [], subagentSummary: nil
            )
            return PiAgentThreadToolGroup(id: entry.id, entries: [entry], activities: [activity])
        }
        let thinking = PiAgentTranscriptEntry(
            sessionID: sessionID, role: .thinking, title: "Thinking", text: "Reasoning about the edit"
        )
        let g1 = editGroup(file: "A.swift")
        let g2 = editGroup(file: "B.swift")
        let thread = PiAgentTranscriptThread(
            id: UUID(), question: nil, steeringMessages: [], thinkingParts: [thinking],
            assistantMessages: [], activities: g1.activities + g2.activities,
            statuses: [], errors: [],
            children: [.toolGroup(g1), .thinking(thinking), .toolGroup(g2)]
        )

        // Thinking hidden: the two edit groups become adjacent and re-merge into one card.
        var hidden = PiAgentTranscriptVisibilitySettings()
        hidden.showThinking = false
        let merged = PiAgentTranscriptThreadCard.visibleChildren(
            of: thread, visibility: hidden, nativeSubagentRunsByID: [:]
        )
        XCTAssertEqual(merged.count, 1, "Hidden thinking must not fragment the diff cards.")
        guard case .toolGroup(let group)? = merged.first else {
            return XCTFail("Expected a single merged tool group.")
        }
        XCTAssertEqual(group.entries.count, 2)
        // Both edits re-fold into ONE `edit` activity (count 2) — as if the model had
        // made the burst without pausing — so the tool-call chips read "edit ×2", not
        // two separate "edit" chips.
        XCTAssertEqual(group.activities.count, 1)
        XCTAssertEqual(group.activities.first?.name, "edit")
        XCTAssertEqual(group.activities.first?.count, 2)
        XCTAssertEqual(group.id, g1.id, "Merged group keeps the first group's id for a stable row.")

        // Thinking visible: the separator stays, so the groups remain split.
        var shown = PiAgentTranscriptVisibilitySettings()
        shown.showThinking = true
        let split = PiAgentTranscriptThreadCard.visibleChildren(
            of: thread, visibility: shown, nativeSubagentRunsByID: [:]
        )
        XCTAssertEqual(split.count, 3, "A visible thinking block must keep the diff cards separate.")
    }

    private func runMainLoop(iterations: Int, delay: TimeInterval) {
        for _ in 0..<iterations {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(delay))
        }
    }

    private func nonWhiteSampleCount(in view: NSView) throws -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("Could not create a bitmap representation for the transcript smoke view.")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let isOpaqueEnough = color.alphaComponent > 0.1
                let isNotWhite = color.redComponent < 0.92 || color.greenComponent < 0.92 || color.blueComponent < 0.92
                if isOpaqueEnough && isNotWhite {
                    count += 1
                }
            }
        }
        return count
    }

    private func assertColor(
        _ attributed: NSAttributedString,
        substring: String,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            colorsMatch(color(in: attributed, substring: substring), expected),
            "Expected \(substring) to use \(expected).",
            file: file,
            line: line
        )
    }

    private func color(in attributed: NSAttributedString, substring: String) -> NSColor? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private func font(in attributed: NSAttributedString, substring: String) -> NSFont? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    private func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}

private struct PiAgentTranscriptFirstPaintSmokeView: View {
    let rows: [String]
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    var body: some View {
        ScrollView {
            PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                transcriptRows(rows)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color.white)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .task {
            await Task.yield()
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 40_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
        }
    }
}

private struct PiAgentTranscriptAppendSmokeView: View {
    @State private var rows = (0..<80).map { "Transcript row \($0)" }
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    var body: some View {
        ScrollView {
            PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                transcriptRows(rows)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color.white)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .task {
            await Task.yield()
            rows.append("Sent message row")
            await Task.yield()
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 40_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
        }
    }
}

@ViewBuilder
private func transcriptRows(_ rows: [String]) -> some View {
    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        Text(row)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
            .background(Color(red: 0.14, green: 0.30, blue: 0.56))
            .id("row-\(index)")
    }

    Color.clear
        .frame(height: 1)
        .id("bottom")
}
