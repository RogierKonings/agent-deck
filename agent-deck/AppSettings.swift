import Foundation

struct PiAgentTranscriptVisibilitySettings: Codable, Hashable {
    var showShortcutsStrip: Bool = true
    var showThinking: Bool = true
    var showWebActivity: Bool = true
    var showToolCalls: Bool = true
    var showErrors: Bool = true
    var showFinalSystemPrompt: Bool = true
    var showPlans: Bool = true
    var showDiffs: Bool = true

    enum CodingKeys: String, CodingKey {
        case showShortcutsStrip
        case showThinking
        case showWebActivity
        case showToolCalls
        case showErrors
        case showFinalSystemPrompt
        case showPlans
        case showDiffs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showShortcutsStrip = try container.decodeIfPresent(Bool.self, forKey: .showShortcutsStrip) ?? true
        showThinking = try container.decodeIfPresent(Bool.self, forKey: .showThinking) ?? true
        showWebActivity = try container.decodeIfPresent(Bool.self, forKey: .showWebActivity) ?? true
        showToolCalls = try container.decodeIfPresent(Bool.self, forKey: .showToolCalls) ?? true
        showErrors = try container.decodeIfPresent(Bool.self, forKey: .showErrors) ?? true
        showFinalSystemPrompt = try container.decodeIfPresent(Bool.self, forKey: .showFinalSystemPrompt) ?? true
        showPlans = try container.decodeIfPresent(Bool.self, forKey: .showPlans) ?? true
        showDiffs = try container.decodeIfPresent(Bool.self, forKey: .showDiffs) ?? true
    }
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentNotificationDelayMinutes: Int = 3
    var piAgentIdleParkingEnabled: Bool = true
    var piAgentIdleParkingTimeoutMinutes: Int = 10
    var piAgentTranscriptVisibility: PiAgentTranscriptVisibilitySettings = .init()
    var piAgentTerminalApplicationPath: String?
    var projectsRootPaths: [String] = [ProjectDiscovery.defaultRootDirectoryURL().path]
    var didConfirmProjectsRootPaths: Bool = false
    var nativeSubagentsEnabledForNewSessions: Bool = true
    var agentMemoryEnabled: Bool = false
    var agentMemorySubagentsEnabled: Bool = true
    var agentMemoryShowTranscriptCards: Bool = true
    var agentMemoryInjectionCharacterBudget: Int = 6_000
    var agentMemoryRetentionDays: Int = 120
    var showContextSmartZoneHint: Bool = false
    var autoGeneratePiAgentSessionTitles: Bool = FoundationModelAutomationService.isAvailable()
    var autoUpdatePiAgentSessionTitles: Bool = FoundationModelAutomationService.isAvailable()
    var piAgentTitleGenerationModelIdentifier: String? = FoundationModelAutomationService.isAvailable() ? FoundationModelAutomationService.identifier : nil
    var piAgentGitAutomationEnabled: Bool = false
    var piAgentGitAutomationRequiresConfirmation: Bool = true
    var piAgentCommitMessageModelIdentifier: String?
    var piAgentSessionsUseWorktree: Bool = false
    var piAgentSessionsKeepWorktreeAfterMerge: Bool = true
    var autoGenerateAgentAvatarPrompts: Bool = false
    var agentAvatarPromptModelIdentifier: String?
    var skillDescriptionModelIdentifier: String?
    var disabledProviders: Set<String> = []
    var disabledModelIdentifiers: Set<String> = []
    var openAIFastModeModelIdentifiers: Set<String> = []
    var disabledInjectedCommandIDs: Set<String> = []
    var enabledLibraryCommandIDs: Set<String> = []
    var defaultAgentNames: Set<String> = []
    var defaultSkillNames: Set<String> = []
    var externalSkillPaths: Set<String> = []
    var importedSkillRepositories: [ImportedSkillRepository] = []
    var defaultPromptTemplateNames: Set<String> = []
    var disabledBundledPromptNames: Set<String> = []
    var disabledBundledSkillNames: Set<String> = []
    var externalPromptPaths: Set<String> = []
    var didMigrateAgentAssignmentsFromDiscoveredFiles: Bool = false
    var selectedThemeID: UUID = Theme.defaultTheme.id
    var customThemes: [Theme] = []
    /// Asset-catalog name of the user-chosen Dock icon. `nil` = bundle default.
    var selectedAppIconName: String?

    enum CodingKeys: String, CodingKey {
        case gitHubBoardCacheLifetimeMinutes
        case piAgentNotificationDelayMinutes
        case piAgentIdleParkingEnabled
        case piAgentIdleParkingTimeoutMinutes
        case piAgentTranscriptVisibility
        case piAgentTerminalApplicationPath
        case projectsRootPaths
        case didConfirmProjectsRootPaths
        case nativeSubagentsEnabledForNewSessions
        case agentMemoryEnabled
        case agentMemorySubagentsEnabled
        case agentMemoryShowTranscriptCards
        case agentMemoryInjectionCharacterBudget
        case agentMemoryRetentionDays
        case showContextSmartZoneHint
        case autoGeneratePiAgentSessionTitles
        case autoUpdatePiAgentSessionTitles
        case piAgentTitleGenerationModelIdentifier
        case piAgentGitAutomationEnabled
        case piAgentGitAutomationRequiresConfirmation
        case piAgentCommitMessageModelIdentifier
        case piAgentSessionsUseWorktree
        case piAgentSessionsKeepWorktreeAfterMerge
        case autoGenerateAgentAvatarPrompts
        case agentAvatarPromptModelIdentifier
        case skillDescriptionModelIdentifier
        case disabledProviders
        case disabledModelIdentifiers
        case openAIFastModeModelIdentifiers
        case disabledInjectedCommandIDs
        case enabledLibraryCommandIDs
        case defaultAgentNames
        case defaultSkillNames
        case externalSkillPaths
        case importedSkillRepositories
        case defaultPromptTemplateNames
        case disabledBundledPromptNames
        case disabledBundledSkillNames
        case externalPromptPaths
        case didMigrateAgentAssignmentsFromDiscoveredFiles
        case selectedThemeID
        case customThemes
        case selectedAppIconName
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitHubBoardCacheLifetimeMinutes = try container.decodeIfPresent(Int.self, forKey: .gitHubBoardCacheLifetimeMinutes) ?? 15
        piAgentNotificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .piAgentNotificationDelayMinutes) ?? 3
        let decodedIdleParkingTimeout = try container.decodeIfPresent(Int.self, forKey: .piAgentIdleParkingTimeoutMinutes) ?? 10
        piAgentIdleParkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentIdleParkingEnabled) ?? (decodedIdleParkingTimeout > 0)
        piAgentIdleParkingTimeoutMinutes = max(decodedIdleParkingTimeout, 1)
        piAgentTranscriptVisibility = try container.decodeIfPresent(PiAgentTranscriptVisibilitySettings.self, forKey: .piAgentTranscriptVisibility) ?? .init()
        piAgentTerminalApplicationPath = try container.decodeIfPresent(String.self, forKey: .piAgentTerminalApplicationPath)
        let hasStoredProjectsRootPaths = container.contains(.projectsRootPaths)
        projectsRootPaths = try container.decodeIfPresent([String].self, forKey: .projectsRootPaths) ?? [ProjectDiscovery.defaultRootDirectoryURL().path]
        didConfirmProjectsRootPaths = try container.decodeIfPresent(Bool.self, forKey: .didConfirmProjectsRootPaths) ?? hasStoredProjectsRootPaths
        nativeSubagentsEnabledForNewSessions = try container.decodeIfPresent(Bool.self, forKey: .nativeSubagentsEnabledForNewSessions) ?? true
        agentMemoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryEnabled) ?? false
        agentMemorySubagentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemorySubagentsEnabled) ?? true
        agentMemoryShowTranscriptCards = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryShowTranscriptCards) ?? true
        agentMemoryInjectionCharacterBudget = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryInjectionCharacterBudget) ?? 6_000, 1_000)
        agentMemoryRetentionDays = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryRetentionDays) ?? 120, 1)
        showContextSmartZoneHint = try container.decodeIfPresent(Bool.self, forKey: .showContextSmartZoneHint) ?? false
        let foundationModelAvailable = FoundationModelAutomationService.isAvailable()
        autoGeneratePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoGeneratePiAgentSessionTitles) ?? foundationModelAvailable
        autoUpdatePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePiAgentSessionTitles) ?? foundationModelAvailable
        piAgentTitleGenerationModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentTitleGenerationModelIdentifier)
            ?? (foundationModelAvailable ? FoundationModelAutomationService.identifier : nil)
        piAgentGitAutomationEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationEnabled) ?? false
        piAgentGitAutomationRequiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationRequiresConfirmation) ?? true
        piAgentCommitMessageModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentCommitMessageModelIdentifier)
        piAgentSessionsUseWorktree = try container.decodeIfPresent(Bool.self, forKey: .piAgentSessionsUseWorktree) ?? false
        piAgentSessionsKeepWorktreeAfterMerge = try container.decodeIfPresent(Bool.self, forKey: .piAgentSessionsKeepWorktreeAfterMerge) ?? true
        autoGenerateAgentAvatarPrompts = try container.decodeIfPresent(Bool.self, forKey: .autoGenerateAgentAvatarPrompts) ?? false
        agentAvatarPromptModelIdentifier = try container.decodeIfPresent(String.self, forKey: .agentAvatarPromptModelIdentifier)
        skillDescriptionModelIdentifier = try container.decodeIfPresent(String.self, forKey: .skillDescriptionModelIdentifier)
        disabledProviders = try container.decodeIfPresent(Set<String>.self, forKey: .disabledProviders) ?? []
        disabledModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .disabledModelIdentifiers) ?? []
        openAIFastModeModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .openAIFastModeModelIdentifiers) ?? []
        disabledInjectedCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledInjectedCommandIDs) ?? []
        enabledLibraryCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryCommandIDs) ?? []
        defaultAgentNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultAgentNames) ?? []
        defaultSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultSkillNames) ?? []
        externalSkillPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalSkillPaths) ?? []
        importedSkillRepositories = try container.decodeIfPresent([ImportedSkillRepository].self, forKey: .importedSkillRepositories) ?? []
        defaultPromptTemplateNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultPromptTemplateNames) ?? []
        disabledBundledPromptNames = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBundledPromptNames) ?? []
        disabledBundledSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBundledSkillNames) ?? []
        externalPromptPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalPromptPaths) ?? []
        didMigrateAgentAssignmentsFromDiscoveredFiles = try container.decodeIfPresent(Bool.self, forKey: .didMigrateAgentAssignmentsFromDiscoveredFiles) ?? false
        selectedThemeID = try container.decodeIfPresent(UUID.self, forKey: .selectedThemeID) ?? Theme.defaultTheme.id
        customThemes = try container.decodeIfPresent([Theme].self, forKey: .customThemes) ?? []
        selectedAppIconName = try container.decodeIfPresent(String.self, forKey: .selectedAppIconName)
    }
}

struct TerminalApplicationOption: Identifiable, Hashable {
    static let defaultID = "__macos_default__"

    var name: String
    var path: String?

    var id: String { path ?? Self.defaultID }
}

/// Terminal applications Agent Deck can reliably open a fresh window in and have it
/// run a prepared script. Terminal and iTerm are driven through AppleScript; Ghostty,
/// kitty, Alacritty and WezTerm expose a command-line flag that runs a given command
/// in a new window. Terminals without any such mechanism — notably Warp and Hyper —
/// are intentionally unsupported: there is no dependable way to make them run our
/// Pi session/update script.
enum SupportedTerminal: CaseIterable {
    case appleTerminal
    case iTerm
    case ghostty
    case kitty
    case alacritty
    case wezTerm

    /// Lowercased `.app` bundle file name, used to recognise a chosen application.
    var bundleName: String {
        switch self {
        case .appleTerminal: return "terminal.app"
        case .iTerm: return "iterm.app"
        case .ghostty: return "ghostty.app"
        case .kitty: return "kitty.app"
        case .alacritty: return "alacritty.app"
        case .wezTerm: return "wezterm.app"
        }
    }

    /// For the CLI-driven terminals, the executable inside `Contents/MacOS` and the
    /// argument(s) that must precede the `/bin/zsh <script>` invocation. `nil` for the
    /// AppleScript-driven terminals (Terminal, iTerm).
    var commandLineLauncher: (executable: String, leadingArguments: [String])? {
        switch self {
        case .appleTerminal, .iTerm: return nil
        case .ghostty: return ("ghostty", ["-e"])
        case .kitty: return ("kitty", [])
        case .alacritty: return ("alacritty", ["-e"])
        case .wezTerm: return ("wezterm", ["start", "--"])
        }
    }

    /// Human-readable list of every supported terminal, for help text and warnings.
    static let displayList = "Terminal, iTerm, Ghostty, kitty, Alacritty, and WezTerm"

    /// Resolves the terminal identified by an application bundle path, if it is one
    /// Agent Deck supports.
    init?(appPath: String) {
        let name = URL(fileURLWithPath: appPath).lastPathComponent.lowercased()
        guard let match = Self.allCases.first(where: { $0.bundleName == name }) else { return nil }
        self = match
    }
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let defaults = UserDefaults.standard
    private let defaultsKey = "agentDeckAppSettings"

    var settings: AppSettings {
        didSet { schedulePersist() }
    }

    /// Coalesces rapid settings mutations (theme picker scrubbing, model
    /// toggles) into a single encode + UserDefaults write per debounce
    /// window. Encode stays on main (AppSettings is MainActor-isolated by
    /// default), but happens only once per ~150ms regardless of how many
    /// property mutations land in that window, and the write itself hops
    /// off-main. Trade-off: up to 150 ms of un-persisted state on a crash;
    /// acceptable since the values are user-toggleable and we'd re-derive
    /// them anyway. Matches the debounce shape used by
    /// `PiAgentSessionStore.scheduleSave`.
    private var pendingPersistTask: Task<Void, Never>?
    private static let persistDebounceNanoseconds: UInt64 = 150_000_000

    private func schedulePersist() {
        pendingPersistTask?.cancel()
        let key = defaultsKey
        pendingPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard let data = try? JSONEncoder().encode(self.settings) else { return }
            // UserDefaults.set is itself thread-safe; hop off-main so the
            // disk I/O doesn't sit on the actor.
            Task.detached(priority: .utility) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }
}
