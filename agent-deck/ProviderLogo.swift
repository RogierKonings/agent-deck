import AppKit
import SwiftUI

nonisolated enum ProviderLogo {
    static func systemSymbolName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "apple":
            return "apple.logo"
        default:
            return nil
        }
    }

    static func assetName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "anthropic":
            return "claude"
        case "azure-openai-responses", "openai", "openai-codex":
            return "openai"
        case "github-copilot":
            return "github"
        case "kimi-coding", "moonshotai", "moonshotai-cn":
            return "kimi"
        case "minimax", "minimax-cn":
            return "minimax"
        case "mistral":
            return "mistralai"
        case "opencode", "opencode-go":
            return "opencode"
        case "openrouter":
            return "openrouter"
        case "vercel-ai-gateway":
            return "vercel"
        case "xai":
            return "xai"
        case "zai", "zai-coding-cn":
            return "zai"
        // Pre-wired names for providers that ship no logo yet. Add an asset with
        // the returned name (see `rasterImagesets`) and it appears automatically;
        // until then `assetExists` routes them to the monogram fallback.
        case "amazon-bedrock":
            return "bedrock"
        case "ant-ling":
            return "ling"
        case "cerebras":
            return "cerebras"
        case "cloudflare-ai-gateway", "cloudflare-workers-ai":
            return "cloudflare"
        case "deepseek":
            return "deepseek"
        case "fireworks":
            return "fireworks"
        case "google", "google-vertex":
            return "google"
        case "groq":
            return "groq"
        case "huggingface":
            return "huggingface"
        case "nvidia":
            return "nvidia"
        case "together":
            return "together"
        case "xiaomi", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp":
            return "xiaomi"
        default:
            return nil
        }
    }

    /// Logos backed by a raster/template imageset (sized with `resizable()`)
    /// rather than a custom SF symbol set (sized with `imageScale`). Every
    /// provider logo is currently a symbol set, so this is empty — add a name
    /// here only if you introduce a raster `.imageset` brand logo.
    private static let rasterImagesets: Set<String> = []

    static func isSymbolAsset(_ assetName: String) -> Bool {
        !rasterImagesets.contains(assetName)
    }

    /// Whether a named asset is actually present in the bundle. Lets us pre-map
    /// provider → asset names that don't exist yet without showing a blank gap.
    static func assetExists(_ assetName: String) -> Bool {
        NSImage(named: assetName) != nil
    }
}

struct ProviderLogoImage: View {
    let provider: String
    var size: CGFloat = 16

    var body: some View {
        if let symbolName = ProviderLogo.systemSymbolName(for: provider) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: size))
                .imageScale(.medium)
                .frame(width: size, height: size, alignment: .center)
                .accessibilityHidden(true)
        } else if let assetName = ProviderLogo.assetName(for: provider), ProviderLogo.assetExists(assetName) {
            // Symbol-set logos scale like glyphs (imageScale); raster/template
            // imagesets (GitHub + the drop-in brand logos) use resizable sizing.
            if ProviderLogo.isSymbolAsset(assetName) {
                Image(assetName)
                    .font(.system(size: size))
                    .imageScale(.medium)
                    .frame(width: size, height: size, alignment: .center)
                    .accessibilityHidden(true)
            } else {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        } else {
            // Providers without a bundled logo (Google, Groq, DeepSeek, …) get a
            // neutral monogram so no row is ever blank.
            Text(monogram)
                .font(.system(size: size * 0.56, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                )
                .accessibilityHidden(true)
        }
    }

    private var monogram: String {
        let firstLetter = provider.first { $0.isLetter || $0.isNumber }
        return firstLetter.map { String($0).uppercased() } ?? "?"
    }
}

struct ProviderLabel: View {
    let provider: String
    var logoSize: CGFloat = 16
    var spacing: CGFloat = 6

    var body: some View {
        Label {
            Text(displayName)
        } icon: {
            ProviderLogoImage(provider: provider, size: logoSize)
        }
        .labelStyle(ProviderInlineLabelStyle(spacing: spacing))
    }

    private var displayName: String {
        provider.lowercased() == "apple" ? "Apple" : provider
    }
}

private struct ProviderInlineLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}
