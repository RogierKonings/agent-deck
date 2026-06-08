import AppKit
import Foundation
import SwiftUI

/// A single sRGB color stored as plain components so it can be persisted in the
/// `AppSettings` JSON and round-tripped through SwiftUI's `ColorPicker`.
struct ThemeColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Convenience for preset literals expressed in 0–255 component space.
    init(_ red255: Int, _ green255: Int, _ blue255: Int) {
        self.red = Double(red255) / 255
        self.green = Double(green255) / 255
        self.blue = Double(blue255) / 255
    }

    /// Normalizes whatever color space `ColorPicker` hands back into sRGB so the
    /// stored components stay comparable and stable across edits.
    init(color: Color) {
        let srgbWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? srgbWhite
        self.red = Double(resolved.redComponent)
        self.green = Double(resolved.greenComponent)
        self.blue = Double(resolved.blueComponent)
    }

    enum CodingKeys: String, CodingKey {
        case red, green, blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 0
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// `#RRGGBB` — used to feed the WKWebView markdown CSS.
    var hexString: String {
        func channel(_ value: Double) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    /// Linear mix toward `other`. `amount` 0 keeps self, 1 becomes `other`.
    func mixed(with other: ThemeColor, amount: Double) -> ThemeColor {
        let t = min(max(amount, 0), 1)
        return ThemeColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    func lightened(by amount: Double) -> ThemeColor {
        mixed(with: ThemeColor(255, 255, 255), amount: amount)
    }

    func darkened(by amount: Double) -> ThemeColor {
        mixed(with: ThemeColor(0, 0, 0), amount: amount)
    }
}

/// A user-selectable color theme. Only the curated tokens below are stored —
/// gradient/derived shades are computed from `accent` (see `ThemeManager`) so a
/// custom theme always stays internally consistent.
struct Theme: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Built-in presets are read-only; custom themes can be edited and deleted.
    var isBuiltIn: Bool
    var accent: ThemeColor      // brand accent — buttons, selection, links
    var assistant: ThemeColor   // user-facing secondary accent (for example, user transcript bubbles)
    var thinking: ThemeColor    // thinking bubbles
    var tool: ThemeColor        // tool-call bubbles
    var error: ThemeColor       // error bubbles + removed diff lines
    var stderr: ThemeColor      // stderr bubbles
    var diffAdded: ThemeColor   // added diff lines
    // Source-kind tags for library lists (agents, prompts, skills): one hue per
    // origin so a row's avatar tint signals where the item came from.
    var sourceBuiltin: ThemeColor   // bundled / package-shipped
    var sourceLibrary: ThemeColor   // user's library (cross-project)
    var sourceProject: ThemeColor   // project-scoped / assigned
    // Canvas tokens — the theme drives the neutral surfaces, not just accents, so
    // each theme has its own background personality instead of one shared gray-black.
    // These are dark-family values (the app forces a dark appearance, so foreground
    // text/icons stay light); a full light theme would also need themed foregrounds.
    var background: ThemeColor      // window / app canvas
    var surface: ThemeColor         // panels, cards, sidebar, list rows
    var stroke: ThemeColor          // borders / separators (opacity applied by AppTheme)

    init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool,
        accent: ThemeColor,
        assistant: ThemeColor,
        thinking: ThemeColor,
        tool: ThemeColor,
        error: ThemeColor,
        stderr: ThemeColor,
        diffAdded: ThemeColor,
        sourceBuiltin: ThemeColor,
        sourceLibrary: ThemeColor,
        sourceProject: ThemeColor,
        background: ThemeColor = ThemeColor(30, 30, 32),
        surface: ThemeColor = ThemeColor(40, 40, 43),
        stroke: ThemeColor = ThemeColor(92, 92, 99)
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.accent = accent
        self.assistant = assistant
        self.thinking = thinking
        self.tool = tool
        self.error = error
        self.stderr = stderr
        self.diffAdded = diffAdded
        self.sourceBuiltin = sourceBuiltin
        self.sourceLibrary = sourceLibrary
        self.sourceProject = sourceProject
        self.background = background
        self.surface = surface
        self.stroke = stroke
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, accent, assistant, thinking, tool, error, stderr, diffAdded
        case sourceBuiltin, sourceLibrary, sourceProject
        case background, surface, stroke
    }

    /// Per-field decode-if-present so a custom theme stored by an older build
    /// stays valid if tokens are added later.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Theme.defaultTheme
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        accent = try container.decodeIfPresent(ThemeColor.self, forKey: .accent) ?? fallback.accent
        assistant = try container.decodeIfPresent(ThemeColor.self, forKey: .assistant) ?? fallback.assistant
        thinking = try container.decodeIfPresent(ThemeColor.self, forKey: .thinking) ?? fallback.thinking
        tool = try container.decodeIfPresent(ThemeColor.self, forKey: .tool) ?? fallback.tool
        error = try container.decodeIfPresent(ThemeColor.self, forKey: .error) ?? fallback.error
        stderr = try container.decodeIfPresent(ThemeColor.self, forKey: .stderr) ?? fallback.stderr
        diffAdded = try container.decodeIfPresent(ThemeColor.self, forKey: .diffAdded) ?? fallback.diffAdded
        sourceBuiltin = try container.decodeIfPresent(ThemeColor.self, forKey: .sourceBuiltin) ?? fallback.sourceBuiltin
        sourceLibrary = try container.decodeIfPresent(ThemeColor.self, forKey: .sourceLibrary) ?? fallback.sourceLibrary
        sourceProject = try container.decodeIfPresent(ThemeColor.self, forKey: .sourceProject) ?? fallback.sourceProject
        background = try container.decodeIfPresent(ThemeColor.self, forKey: .background) ?? fallback.background
        surface = try container.decodeIfPresent(ThemeColor.self, forKey: .surface) ?? fallback.surface
        stroke = try container.decodeIfPresent(ThemeColor.self, forKey: .stroke) ?? fallback.stroke
    }
}

extension Theme {
    /// The exact dark-mode palette the app shipped with before themes existed —
    /// see `AppTheme` in `DesignSystem.swift`. UUIDs of built-in themes are fixed
    /// literals so a stored selection stays valid across app updates.
    static let defaultTheme = Theme(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Default",
        isBuiltIn: true,
        accent: ThemeColor(100, 210, 255),
        assistant: ThemeColor(186, 110, 238),
        thinking: ThemeColor(140, 151, 232),
        tool: ThemeColor(221, 168, 78),
        error: ThemeColor(229, 116, 108),
        stderr: ThemeColor(224, 138, 178),
        diffAdded: ThemeColor(86, 201, 138),
        sourceBuiltin: ThemeColor(240, 165, 90),
        sourceLibrary: ThemeColor(190, 130, 235),
        sourceProject: ThemeColor(100, 200, 130),
        background: ThemeColor(30, 30, 32),
        surface: ThemeColor(40, 40, 43),
        stroke: ThemeColor(92, 92, 99)
    )

    static let ember = Theme(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Ember",
        isBuiltIn: true,
        accent: ThemeColor(255, 138, 76),
        assistant: ThemeColor(245, 130, 90),
        thinking: ThemeColor(230, 165, 95),
        tool: ThemeColor(225, 175, 80),
        error: ThemeColor(232, 92, 88),
        stderr: ThemeColor(230, 128, 150),
        diffAdded: ThemeColor(120, 198, 128),
        sourceBuiltin: ThemeColor(240, 160, 80),
        sourceLibrary: ThemeColor(190, 140, 220),
        sourceProject: ThemeColor(130, 195, 130),
        background: ThemeColor(33, 29, 27),
        surface: ThemeColor(45, 39, 36),
        stroke: ThemeColor(106, 94, 86)
    )

    static let forest = Theme(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: "Forest",
        isBuiltIn: true,
        accent: ThemeColor(96, 200, 140),
        assistant: ThemeColor(120, 200, 150),
        thinking: ThemeColor(128, 188, 170),
        tool: ThemeColor(210, 180, 100),
        error: ThemeColor(228, 116, 108),
        stderr: ThemeColor(216, 140, 165),
        diffAdded: ThemeColor(96, 205, 130),
        sourceBuiltin: ThemeColor(220, 175, 95),
        sourceLibrary: ThemeColor(175, 145, 220),
        sourceProject: ThemeColor(100, 205, 135),
        background: ThemeColor(25, 32, 28),
        surface: ThemeColor(35, 44, 39),
        stroke: ThemeColor(86, 104, 92)
    )

    static let violet = Theme(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        name: "Violet",
        isBuiltIn: true,
        accent: ThemeColor(180, 130, 245),
        assistant: ThemeColor(190, 120, 240),
        thinking: ThemeColor(150, 140, 235),
        tool: ThemeColor(220, 165, 95),
        error: ThemeColor(230, 110, 120),
        stderr: ThemeColor(225, 135, 185),
        diffAdded: ThemeColor(110, 200, 150),
        sourceBuiltin: ThemeColor(225, 165, 95),
        sourceLibrary: ThemeColor(190, 130, 240),
        sourceProject: ThemeColor(115, 200, 145),
        background: ThemeColor(30, 26, 37),
        surface: ThemeColor(41, 35, 51),
        stroke: ThemeColor(102, 90, 120)
    )

    static let monoSlate = Theme(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        name: "Mono Slate",
        isBuiltIn: true,
        accent: ThemeColor(140, 160, 185),
        assistant: ThemeColor(150, 165, 190),
        thinking: ThemeColor(135, 150, 180),
        tool: ThemeColor(180, 165, 140),
        error: ThemeColor(200, 130, 130),
        stderr: ThemeColor(190, 145, 165),
        diffAdded: ThemeColor(140, 180, 150),
        sourceBuiltin: ThemeColor(195, 165, 130),
        sourceLibrary: ThemeColor(165, 145, 180),
        sourceProject: ThemeColor(145, 180, 150),
        background: ThemeColor(29, 31, 34),
        surface: ThemeColor(40, 43, 48),
        stroke: ThemeColor(98, 103, 112)
    )

    static let tokyoNight = Theme(
        id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
        name: "Tokyo Night",
        isBuiltIn: true,
        accent: ThemeColor(122, 162, 247),
        assistant: ThemeColor(187, 154, 247),
        thinking: ThemeColor(125, 207, 255),
        tool: ThemeColor(224, 175, 104),
        error: ThemeColor(247, 118, 142),
        stderr: ThemeColor(255, 158, 100),
        diffAdded: ThemeColor(115, 218, 202),
        sourceBuiltin: ThemeColor(224, 175, 104),
        sourceLibrary: ThemeColor(187, 154, 247),
        sourceProject: ThemeColor(115, 218, 202),
        background: ThemeColor(26, 27, 38),
        surface: ThemeColor(36, 40, 59),
        stroke: ThemeColor(65, 72, 104)
    )

    static let nord = Theme(
        id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        name: "Nord",
        isBuiltIn: true,
        accent: ThemeColor(136, 192, 208),
        assistant: ThemeColor(180, 142, 173),
        thinking: ThemeColor(129, 161, 193),
        tool: ThemeColor(235, 203, 139),
        error: ThemeColor(191, 97, 106),
        stderr: ThemeColor(208, 135, 112),
        diffAdded: ThemeColor(163, 190, 140),
        sourceBuiltin: ThemeColor(235, 203, 139),
        sourceLibrary: ThemeColor(180, 142, 173),
        sourceProject: ThemeColor(163, 190, 140),
        background: ThemeColor(46, 52, 64),
        surface: ThemeColor(59, 66, 82),
        stroke: ThemeColor(76, 86, 106)
    )

    static let catppuccinMocha = Theme(
        id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
        name: "Catppuccin Mocha",
        isBuiltIn: true,
        accent: ThemeColor(137, 180, 250),
        assistant: ThemeColor(203, 166, 247),
        thinking: ThemeColor(116, 199, 236),
        tool: ThemeColor(249, 226, 175),
        error: ThemeColor(243, 139, 168),
        stderr: ThemeColor(250, 179, 135),
        diffAdded: ThemeColor(166, 227, 161),
        sourceBuiltin: ThemeColor(249, 226, 175),
        sourceLibrary: ThemeColor(203, 166, 247),
        sourceProject: ThemeColor(166, 227, 161),
        background: ThemeColor(30, 30, 46),
        surface: ThemeColor(49, 50, 68),
        stroke: ThemeColor(69, 71, 90)
    )

    static let vortex = Theme(
        id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
        name: "Vortex",
        isBuiltIn: true,
        accent: ThemeColor(0, 229, 255),
        assistant: ThemeColor(255, 0, 212),
        thinking: ThemeColor(114, 100, 255),
        tool: ThemeColor(255, 200, 50),
        error: ThemeColor(255, 70, 95),
        stderr: ThemeColor(230, 120, 200),
        diffAdded: ThemeColor(60, 245, 140),
        sourceBuiltin: ThemeColor(255, 185, 55),
        sourceLibrary: ThemeColor(200, 120, 255),
        sourceProject: ThemeColor(50, 225, 195),
        background: ThemeColor(8, 10, 24),
        surface: ThemeColor(16, 20, 40),
        stroke: ThemeColor(48, 56, 88)
    )

    static let crimson = Theme(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        name: "Crimson",
        isBuiltIn: true,
        accent: ThemeColor(255, 85, 85),
        assistant: ThemeColor(255, 125, 105),
        thinking: ThemeColor(235, 130, 130),
        tool: ThemeColor(235, 185, 75),
        error: ThemeColor(240, 65, 70),
        stderr: ThemeColor(230, 115, 150),
        diffAdded: ThemeColor(115, 200, 135),
        sourceBuiltin: ThemeColor(235, 175, 70),
        sourceLibrary: ThemeColor(200, 135, 230),
        sourceProject: ThemeColor(105, 205, 145),
        background: ThemeColor(28, 18, 20),
        surface: ThemeColor(40, 26, 30),
        stroke: ThemeColor(108, 70, 76)
    )

    static let sunburst = Theme(
        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        name: "Sunburst",
        isBuiltIn: true,
        accent: ThemeColor(255, 210, 50),
        assistant: ThemeColor(255, 155, 95),
        thinking: ThemeColor(245, 185, 75),
        tool: ThemeColor(205, 175, 85),
        error: ThemeColor(238, 85, 80),
        stderr: ThemeColor(232, 140, 135),
        diffAdded: ThemeColor(150, 215, 105),
        sourceBuiltin: ThemeColor(245, 195, 65),
        sourceLibrary: ThemeColor(185, 140, 225),
        sourceProject: ThemeColor(100, 210, 160),
        background: ThemeColor(28, 24, 16),
        surface: ThemeColor(42, 34, 22),
        stroke: ThemeColor(102, 88, 66)
    )

    static let harleq = Theme(
        id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
        name: "Harleq",
        isBuiltIn: true,
        accent: ThemeColor(65, 150, 255),
        assistant: ThemeColor(230, 50, 200),
        thinking: ThemeColor(160, 80, 255),
        tool: ThemeColor(255, 195, 0),
        error: ThemeColor(255, 65, 75),
        stderr: ThemeColor(255, 140, 80),
        diffAdded: ThemeColor(45, 220, 110),
        sourceBuiltin: ThemeColor(255, 175, 45),
        sourceLibrary: ThemeColor(185, 110, 245),
        sourceProject: ThemeColor(45, 210, 190),
        background: ThemeColor(18, 16, 24),
        surface: ThemeColor(28, 24, 38),
        stroke: ThemeColor(70, 60, 95)
    )

    static let fiery = Theme(
        id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
        name: "Fiery",
        isBuiltIn: true,
        accent: ThemeColor(193, 18, 31),
        assistant: ThemeColor(102, 155, 188),
        thinking: ThemeColor(230, 145, 60),
        tool: ThemeColor(253, 240, 213),
        error: ThemeColor(120, 0, 0),
        stderr: ThemeColor(215, 55, 50),
        diffAdded: ThemeColor(90, 195, 115),
        sourceBuiltin: ThemeColor(240, 175, 50),
        sourceLibrary: ThemeColor(102, 155, 188),
        sourceProject: ThemeColor(85, 195, 155),
        background: ThemeColor(0, 48, 73),
        surface: ThemeColor(12, 60, 88),
        stroke: ThemeColor(65, 110, 140)
    )

    static let purpleRaindrops = Theme(
        id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
        name: "Purple Raindrops",
        isBuiltIn: true,
        accent: ThemeColor(67, 97, 238),
        assistant: ThemeColor(247, 37, 133),
        thinking: ThemeColor(63, 55, 201),
        tool: ThemeColor(76, 201, 240),
        error: ThemeColor(181, 23, 158),
        stderr: ThemeColor(114, 9, 183),
        diffAdded: ThemeColor(80, 215, 170),
        sourceBuiltin: ThemeColor(72, 149, 239),
        sourceLibrary: ThemeColor(58, 12, 163),
        sourceProject: ThemeColor(86, 11, 173),
        background: ThemeColor(16, 8, 28),
        surface: ThemeColor(26, 16, 42),
        stroke: ThemeColor(72, 12, 168)
    )

    static let neonJungle = Theme(
        id: UUID(uuidString: "10101010-1010-1010-1010-101010101010")!,
        name: "Neon Jungle",
        isBuiltIn: true,
        accent: ThemeColor(65, 234, 212),
        assistant: ThemeColor(255, 32, 110),
        thinking: ThemeColor(155, 65, 235),
        tool: ThemeColor(251, 255, 18),
        error: ThemeColor(255, 55, 80),
        stderr: ThemeColor(225, 40, 145),
        diffAdded: ThemeColor(125, 240, 65),
        sourceBuiltin: ThemeColor(245, 205, 30),
        sourceLibrary: ThemeColor(65, 234, 212),
        sourceProject: ThemeColor(75, 235, 65),
        background: ThemeColor(12, 15, 10),
        surface: ThemeColor(20, 24, 16),
        stroke: ThemeColor(50, 65, 50)
    )

    /// Default first — the rest are presented as presets in Settings.
    static let builtInThemes: [Theme] = [
        defaultTheme,
        ember,
        forest,
        violet,
        monoSlate,
        tokyoNight,
        nord,
        catppuccinMocha,
        vortex,
        crimson,
        sunburst,
        harleq,
        fiery,
        purpleRaindrops,
        neonJungle
    ]

    // Gradient/depth shades derived from the accent. Tuned so the Default
    // accent's shades land close to the hand-picked values the app shipped
    // with, while staying sensible for any custom accent.
    var accentBright: ThemeColor { accent.lightened(by: 0.30) }
    var accentDeep: ThemeColor { accent.darkened(by: 0.33) }
    var accentShadow: ThemeColor { accent.darkened(by: 0.72) }

    /// Accent + editable role colors in display order — used for compact swatch strips.
    var previewSwatches: [ThemeColor] { [accent, assistant, thinking, tool, error, diffAdded, sourceBuiltin, sourceLibrary, sourceProject] }
}
