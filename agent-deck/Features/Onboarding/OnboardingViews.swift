import SwiftUI
import TourKit

private enum WelcomeTourContent {
    static var pages: [TourPage] {
        [
            TourPage(
                imageName: "pop-onb-1",
                title: "Command Pi from \(AppBrand.displayName)",
                description: "Run Pi coding sessions from a focused Mac workspace with project context, models, repo activity, and session state in one place."
            ),
            TourPage(
                imageName: "pop-onb-2",
                title: "Work in a Coding Chat",
                description: "Use a customizable chat view built for implementation work: full transcripts, tool calls, file previews, attachments, and live controls."
            ),
            TourPage(
                imageName: "pop-onb-3",
                title: "Orchestrate Deck Agents",
                description: "Delegate focused work to custom Deck agents, run them alone or in parallel, supervise decisions, and keep worktrees isolated."
            ),
            TourPage(
                imageName: "pop-onb-4",
                title: "Shape Your Agent System",
                description: "Create, organize, assign, and reuse agents, skills, and prompts so project workflows become clear, portable, and repeatable."
            ),
            TourPage(
                imageName: "pop-onb-5",
                title: "Manage Project Instructions",
                description: "Control system guidance, AGENTS.md, CLAUDE.md, and project-scoped instructions from one place instead of hunting through files."
            ),
            TourPage(
                imageName: "pop-onb-6",
                title: "Connect the Wider Workflow",
                description: "Bring in GitHub, project folders, environment keys, and model setup when you need them. Setup checks confirm the workspace is ready."
            )
        ]
    }
}

struct WelcomeOnboardingSheet: View {
    var viewModel: AppViewModel
    let onFinish: (SidebarItem?) -> Void
    #if DEBUG
    /// Debug demo: seed the Setup step with the canned "nothing installed" rows
    /// instead of probing the real machine.
    var forceNothingInstalledForDebug = false
    #endif
    @State private var phase: Phase = .tour
    @State private var setupItemsTask: Task<[SetupCheckItem], Never>?
    @State private var setupItems: [SetupCheckItem] = []

    private enum Phase {
        case tour
        case setup
        case preferences
        case finalInfo
    }

    var body: some View {
        Group {
            switch phase {
            case .tour:
                tourView
            case .setup:
                SetupChecklistView(
                    viewModel: viewModel,
                    preloadedItems: setupSimulation.isActive ? nil : setupItemsTask,
                    simulation: setupSimulation,
                    onBack: { phase = .tour },
                    onContinue: { items in
                        setupItems = items
                        phase = .preferences
                    }
                )
            case .preferences:
                OnboardingPreferencesView(
                    viewModel: viewModel,
                    setupItems: setupItems,
                    onBack: { phase = .setup },
                    onFinish: { _ in phase = .finalInfo }
                )
            case .finalInfo:
                OnboardingFinalView(
                    setupItems: setupItems,
                    onBack: { phase = .preferences },
                    onFinish: { target in onFinish(target) }
                )
            }
        }
        .task {
            preloadSetupChecksIfNeeded()
        }
    }

    private var tourView: some View {
        TourSlideshowView(
            pages: WelcomeTourContent.pages,
            width: 660,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Check Setup",
            onFinish: {
                setupItemsTask = nil
                phase = .setup
            },
            onClose: { onFinish(nil) }
        )
        .frame(width: 660)
    }

    /// `.nothingInstalled` in the debug demo so the Setup step runs the real
    /// service against forced states (1:1 with real); `.init()` otherwise.
    private var setupSimulation: SetupSimulation {
        #if DEBUG
        if forceNothingInstalledForDebug { return .nothingInstalled }
        #endif
        return .init()
    }

    private func preloadSetupChecksIfNeeded() {
        guard setupItemsTask == nil, !setupSimulation.isActive else { return }
        let projectRootPaths = viewModel.configuredProjectsRootPaths
        let githubAccount = viewModel.currentGitHubAccount
        let selectedProjectPath = viewModel.selectedProjectPath
        let hasConfirmedProjectsRootPaths = viewModel.hasConfirmedProjectsRootPaths
        let suggestedProjectsRootPath = viewModel.suggestedProjectsRootPath
        setupItemsTask = Task {
            await SetupDependencyService().loadItems(
                projectRootPaths: projectRootPaths,
                githubAccount: githubAccount,
                selectedProjectPath: selectedProjectPath,
                hasConfirmedProjectsRootPaths: hasConfirmedProjectsRootPaths,
                suggestedProjectsRootPath: suggestedProjectsRootPath
            )
        }
    }
}

/// Closing onboarding screen: points the user at the three hubs they'll use,
/// highlights where the Coding Agent lives in the sidebar, and smart-routes the
/// primary action to Doctor (if anything is broken) or Pi Agent (if ready to code).
struct OnboardingFinalView: View {
    let setupItems: [SetupCheckItem]
    let onBack: () -> Void
    let onFinish: (SidebarItem?) -> Void

    private var canStartCoding: Bool {
        piPassed && modelsPassed && projectPassed
    }

    private var needsDoctor: Bool {
        setupItems.contains { $0.status == .failed }
    }

    private var piPassed: Bool {
        setupItems.first { $0.id == "pi-cli" }?.status == .passed
    }

    private var modelsPassed: Bool {
        setupItems.first { $0.id == "pi-models" }?.status == .passed
    }

    private var projectPassed: Bool {
        setupItems.first { $0.id == "project-root" }?.status == .passed
    }

    private var primaryTarget: SidebarItem {
        if canStartCoding { return .agent }
        if needsDoctor { return .doctor }
        return .doctor
    }

    private var primaryButtonTitle: String {
        if canStartCoding { return "Start Coding" }
        if needsDoctor { return "Review Setup" }
        return "Open Doctor"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(canStartCoding ? "You're ready to code" : "You're set up")
                    .font(.title2.bold())
                    .fontWidth(.expanded)
                Text("Three places you'll use in \(AppBrand.displayName).")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    infoCard(
                        icon: "stethoscope",
                        title: "Doctor",
                        detail: "Check runtime health and install or fix anything that's missing — Pi, models, project folders, and GitHub."
                    )
                    infoCard(
                        icon: "cpu",
                        title: "Models",
                        detail: "Connect providers and choose which models are available. Add a provider any time with the + button in Models."
                    )
                    infoCard(
                        icon: "sparkles.rectangle.stack",
                        title: "Coding Agent",
                        detail: "Start coding sessions with Pi Agent. You'll find this chip at the bottom of your sidebar — tap it any time to jump back in.",
                        usePiSymbol: true
                    )
                }
                .padding(24)
            }
            .background(AppTheme.windowBackground)

            Divider()
            HStack {
                Button("Back") { onBack() }
                    .appSecondaryButton()
                Spacer()
                Button(primaryButtonTitle) {
                    onFinish(primaryTarget)
                }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 660, height: 560)
        .background(AppTheme.windowBackground)
    }

    private func infoCard(icon: String, title: String, detail: String, usePiSymbol: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if usePiSymbol {
                Image("pi")
                    .imageScale(.large)
                    .foregroundStyle(AppTheme.brandAccent)
            } else {
                Image(systemName: icon)
                    .imageScale(.large)
                    .foregroundStyle(AppTheme.brandAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }
}

struct SetupChecklistView: View {
    var viewModel: AppViewModel
    fileprivate let preloadedItems: Task<[SetupCheckItem], Never>?
    let onBack: () -> Void
    let onContinue: ([SetupCheckItem]) -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = true
    @State private var loginService = PiProviderLoginService()
    @State private var showingConnectProvider = false
    /// Demo only: when active, the checks run against forced install states
    /// (so the demo is 1:1 with the real service code). `.init()` = real checks.
    @State private var simulation: SetupSimulation
    @Environment(\.scenePhase) private var scenePhase

    fileprivate init(
        viewModel: AppViewModel,
        preloadedItems: Task<[SetupCheckItem], Never>? = nil,
        simulation: SetupSimulation = .init(),
        onBack: @escaping () -> Void,
        onContinue: @escaping ([SetupCheckItem]) -> Void
    ) {
        self.viewModel = viewModel
        self.preloadedItems = preloadedItems
        _simulation = State(initialValue: simulation)
        self.onBack = onBack
        self.onContinue = onContinue
    }

    var body: some View {
        Group {
            if showingConnectProvider {
                AddProviderFlowSheet(
                    viewModel: viewModel,
                    loginService: loginService,
                    onClose: {
                        showingConnectProvider = false
                        Task { await refresh() }
                    }
                )
            } else {
                checklist
            }
        }
        .frame(width: 660, height: 560)
        .background(AppTheme.windowBackground)
        .task {
            if items.isEmpty {
                await loadInitialItems()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refresh() }
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Check")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("\(AppBrand.displayName) works best after these checks pass.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(.borderless)
                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(isRefreshing)
                .help("Refresh setup checks")
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        if isRefreshing && items.isEmpty {
                            loadingRow
                        } else {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                setupRow(item)
                                if index < items.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                    }
                    .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.contentStroke, lineWidth: 1)
                    )
                }
                .padding(24)
            }
            .background(AppTheme.windowBackground)

            Divider()
            HStack {
                Button("Back") {
                    onBack()
                }
                .appSecondaryButton()
                Spacer()
                Button("Continue") {
                    onContinue(items)
                }
                .appPrimaryButton()
                .disabled(isRefreshing && items.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            AppSpinner()
                .controlSize(.small)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text("Checking setup")
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text("\(AppBrand.displayName) is checking Pi, models, project settings, and integrations.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @MainActor
    private func loadInitialItems() async {
        isRefreshing = true
        // The demo (simulation active) always runs the real service with forced
        // states — never the preloaded real-machine task.
        if !simulation.isActive, let preloadedItems {
            items = await preloadedItems.value
            isRefreshing = false
            return
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let projectRootPaths = viewModel.configuredProjectsRootPaths
        let githubAccount = viewModel.currentGitHubAccount
        items = await SetupDependencyService().loadItems(
            projectRootPaths: projectRootPaths,
            githubAccount: githubAccount,
            selectedProjectPath: viewModel.selectedProjectPath,
            hasConfirmedProjectsRootPaths: viewModel.hasConfirmedProjectsRootPaths,
            suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath,
            simulation: simulation
        )
    }

    private func setupRow(_ item: SetupCheckItem) -> some View {
        HStack(alignment: .center, spacing: 14) {
            statusIcon(for: item)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = item.recovery, item.status != .passed {
                    Text(recovery)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.status != .passed, item.action != nil || item.secondaryAction != nil {
                    HStack(spacing: 8) {
                        if let action = item.action {
                            Button(action.buttonTitle) { perform(action) }
                                .appPrimaryButton()
                        }
                        if let secondaryAction = item.secondaryAction {
                            Button(secondaryAction.buttonTitle) { perform(secondaryAction) }
                                .appSecondaryButton()
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 16)

            Text(item.status.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(item.status.color)
                .background(Capsule(style: .continuous).fill(item.status.color.opacity(0.12)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusIconImage: (SetupCheckItem) -> AnyView {
        { item in
            AnyView(
                Image(systemName: item.status.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.status.color)
                    .frame(width: 28)
            )
        }
    }

    @ViewBuilder
    private func statusIcon(for item: SetupCheckItem) -> some View {
        #if DEBUG
        // Debug-only: tap the status icon to flip a row missing↔ready so the
        // dependent UI (e.g. a "ready" Pi Models row, connected GitHub) can be
        // previewed without the real dependency installed.
        Button { debugToggleStatus(item) } label: { statusIconImage(item) }
            .buttonStyle(.plain)
            .help("Debug: toggle this check's status")
        #else
        statusIconImage(item)
        #endif
    }

    #if DEBUG
    /// Flips the simulated install state for this check and re-runs the *real*
    /// service, so dependent rows recompute correctly (e.g. toggling Pi to Ready
    /// makes Pi Models offer "Connect a provider" via the real gating).
    private func debugToggleStatus(_ item: SetupCheckItem) {
        let nowReady = item.status != .passed
        switch item.id {
        case "pi-cli": simulation.piInstalled = nowReady
        case "pi-models": simulation.modelsAvailable = nowReady
        case "project-root": simulation.projectsConfigured = nowReady
        case "github": simulation.githubConnected = nowReady
        default: break
        }
        Task { await refresh() }
    }
    #endif

    private func perform(_ action: SetupCheckAction) {
        // First-run setup: replace the auto-seeded default rather than
        // appending, so picking a custom folder yields a single-entry list
        // (matching the user's mental model from the original UX).
        let replacing = !viewModel.hasConfirmedProjectsRootPaths
        switch action {
        case .chooseProjectRoot:
            viewModel.chooseProjectsRootDirectory(replacingExisting: replacing)
            Task { await refresh() }
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory(replacingExisting: replacing)
            Task { await refresh() }
        case .installPi:
            viewModel.openPiInstallInTerminal()
        case .connectProvider:
            showingConnectProvider = true // in-place; back returns to the checklist
        case .setupGitHub:
            viewModel.openGitHubSetupInTerminal()
        }
    }
}

struct SetupCheckItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let status: SetupCheckStatus
    let recovery: String?
    let action: SetupCheckAction?
    let secondaryAction: SetupCheckAction?

    init(
        id: String,
        title: String,
        detail: String,
        status: SetupCheckStatus,
        recovery: String?,
        action: SetupCheckAction? = nil,
        secondaryAction: SetupCheckAction? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.recovery = recovery
        self.action = action
        self.secondaryAction = secondaryAction
    }
}

enum SetupCheckAction: Hashable {
    case chooseProjectRoot
    case useSuggestedProjectRoot
    case installPi
    case connectProvider
    case setupGitHub

    var buttonTitle: String {
        switch self {
        case .chooseProjectRoot: "Choose Folder…"
        case .useSuggestedProjectRoot: "Use Suggested Folder"
        case .installPi: "Install in Terminal"
        case .connectProvider: "Connect a provider"
        case .setupGitHub: "Set up GitHub"
        }
    }
}

enum SetupCheckStatus: Hashable {
    case passed
    case warning
    case failed

    var label: String {
        switch self {
        case .passed: "Ready"
        case .warning: "Optional"
        case .failed: "Missing"
        }
    }

    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "circle.dashed"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .secondary
        case .failed: .red
        }
    }
}

/// Forces specific install/auth states for previews & the debug demos. `nil`
/// fields fall back to the real machine check, so the demo runs the *same*
/// `SetupDependencyService` code as the real onboarding — guaranteeing 1:1.
struct SetupSimulation: Equatable {
    var piInstalled: Bool?
    var modelsAvailable: Bool?
    var projectsConfigured: Bool?
    var githubConnected: Bool?
    var ghInstalled: Bool?

    var isActive: Bool {
        piInstalled != nil || modelsAvailable != nil || projectsConfigured != nil
            || githubConnected != nil || ghInstalled != nil
    }

    static let nothingInstalled = SetupSimulation(
        piInstalled: false, modelsAvailable: false, projectsConfigured: false,
        githubConnected: false, ghInstalled: false
    )
}

struct SetupDependencyService {
    private let commandRunner = CommandRunner()
    private let piResolver = PiExecutableResolver()

    func loadItems(
        projectRootPaths: [String],
        githubAccount: GitHubHostAccount?,
        selectedProjectPath: String?,
        hasConfirmedProjectsRootPaths: Bool = true,
        suggestedProjectsRootPath: String? = nil,
        simulation: SetupSimulation = .init()
    ) async -> [SetupCheckItem] {
        async let pi = piCheck(simulation)
        async let models = modelCheck(simulation)
        let github = await githubCheck(account: githubAccount, simulation: simulation)
        let project = projectRootCheck(paths: projectRootPaths, isConfirmed: hasConfirmedProjectsRootPaths, suggestedPath: suggestedProjectsRootPath, simulation: simulation)

        // Web Access (optional Exa/URL-fetch fallback) lives in Doctor, not in
        // the first-run Setup Check — it's noise for onboarding.
        return await [pi, models, project, github]
    }

    // MARK: Pi

    private func piCheck(_ simulation: SetupSimulation) async -> SetupCheckItem {
        let installed: Bool
        if let forced = simulation.piInstalled {
            installed = forced
        } else {
            let piCommand = piResolver.resolve()?.path ?? "pi"
            installed = ((try? await commandRunner.run(piCommand, arguments: ["--help"], timeout: 6))?.exitCode == 0)
        }
        return piItem(installed: installed)
    }

    private func piItem(installed: Bool) -> SetupCheckItem {
        installed
            ? SetupCheckItem(id: "pi-cli", title: "Pi", detail: "Pi is installed and available to \(AppBrand.displayName).", status: .passed, recovery: nil)
            : SetupCheckItem(id: "pi-cli", title: "Pi", detail: "Install Pi and make sure `pi` is available from your login shell.", status: .failed, recovery: "After installing, verify `pi --help` works in Terminal.", action: .installPi)
    }

    // MARK: Models

    private func modelCheck(_ simulation: SetupSimulation) async -> SetupCheckItem {
        // Connect-a-provider only makes sense once pi exists, so gate on pi.
        let piInstalled = simulation.piInstalled ?? (piResolver.resolve() != nil)
        if let forced = simulation.modelsAvailable {
            return modelsItem(available: forced, count: forced ? 12 : 0, piInstalled: piInstalled)
        }
        let models = await PiModelDiscoveryService(commandRunner: commandRunner, piResolver: piResolver).loadAvailableModels()
        return modelsItem(available: !models.isEmpty, count: models.count, piInstalled: piInstalled)
    }

    private func modelsItem(available: Bool, count: Int, piInstalled: Bool) -> SetupCheckItem {
        if available {
            return SetupCheckItem(id: "pi-models", title: "Pi Models", detail: "\(count) models are available to \(AppBrand.displayName).", status: .passed, recovery: nil)
        }
        return SetupCheckItem(
            id: "pi-models",
            title: "Pi Models",
            detail: "`pi --list-models` did not return any usable models.",
            status: .failed,
            recovery: piInstalled ? "Connect a model provider to load its models." : "Install Pi first (above), then connect a model provider.",
            action: piInstalled ? .connectProvider : nil
        )
    }

    // MARK: Projects

    private func projectRootCheck(paths: [String], isConfirmed: Bool, suggestedPath: String?, simulation: SetupSimulation) -> SetupCheckItem {
        if let forced = simulation.projectsConfigured {
            return projectItem(configured: forced, detail: forced ? (suggestedPath ?? "Projects folder configured.") : nil, suggestedPath: suggestedPath)
        }

        let resolvedPaths = paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let existingPaths = resolvedPaths.filter { path in
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let hasAnyConfigured = !resolvedPaths.isEmpty
        let hasAnyExisting = !existingPaths.isEmpty

        if !isConfirmed || !hasAnyConfigured {
            return projectItem(configured: false, detail: nil, suggestedPath: suggestedPath)
        }
        let detail: String
        if hasAnyExisting {
            detail = existingPaths.count == 1 ? existingPaths[0] : "\(existingPaths.count) folders configured: \(existingPaths.joined(separator: ", "))"
        } else {
            detail = "None of the configured folders exist anymore. Choose a parent folder that contains your projects."
        }
        return SetupCheckItem(
            id: "project-root", title: "Projects Folders", detail: detail,
            status: hasAnyExisting ? .passed : .failed,
            recovery: hasAnyExisting ? nil : "Choose an existing parent folder for your projects.",
            action: hasAnyExisting ? nil : .chooseProjectRoot
        )
    }

    private func projectItem(configured: Bool, detail: String?, suggestedPath: String?) -> SetupCheckItem {
        if configured {
            return SetupCheckItem(id: "project-root", title: "Projects Folders", detail: detail ?? "Projects folder configured.", status: .passed, recovery: nil)
        }
        let hasSuggested = suggestedPath?.isEmpty == false
        return SetupCheckItem(
            id: "project-root", title: "Projects Folders",
            detail: hasSuggested ? "Choose at least one parent folder that contains your projects. Suggested: \(suggestedPath!)" : "Choose at least one parent folder that contains your projects.",
            status: .failed, recovery: nil,
            action: hasSuggested ? .useSuggestedProjectRoot : .chooseProjectRoot,
            secondaryAction: hasSuggested ? .chooseProjectRoot : nil
        )
    }

    // MARK: GitHub

    private func githubCheck(account: GitHubHostAccount?, simulation: SetupSimulation) async -> SetupCheckItem {
        let resolvedAccount: GitHubHostAccount?
        if let connected = simulation.githubConnected {
            resolvedAccount = connected
                ? (account ?? GitHubHostAccount(host: "github.com", login: "octocat", scopes: [], gitProtocol: nil, tokenSource: nil, isActive: true))
                : nil
        } else if let account {
            resolvedAccount = account
        } else {
            resolvedAccount = await GitHubCLIAuthService(commandRunner: commandRunner).loadStatus().account
        }

        if let resolvedAccount {
            return SetupCheckItem(id: "github", title: "GitHub", detail: "Connected as \(resolvedAccount.login) on \(resolvedAccount.host).", status: .passed, recovery: nil)
        }

        let ghInstalled: Bool
        if let forced = simulation.ghInstalled {
            ghInstalled = forced
        } else {
            ghInstalled = (try? await commandRunner.run("gh", arguments: ["--version"], timeout: 5))?.exitCode == 0
        }
        return SetupCheckItem(
            id: "github",
            title: "GitHub",
            detail: ghInstalled
                ? "Optional. Sign in to GitHub for issue, comment, commit, and push workflows."
                : "Optional. Install the GitHub CLI and sign in for issue, comment, commit, and push workflows.",
            status: .warning,
            recovery: nil,
            action: .setupGitHub
        )
    }
}

// MARK: - Preferences phase

struct OnboardingPreferencesView: View {
    var viewModel: AppViewModel
    let setupItems: [SetupCheckItem]
    let onBack: () -> Void
    let onFinish: (SidebarItem?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preferences")
                    .font(.title2.bold())
                    .fontWidth(.expanded)
                Text("Tune the defaults for new sessions.")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        worktreeRow
                        rowDivider
                        modelRow
                        rowDivider
                        autoTitlesRow
                        rowDivider
                        gitAutomationRow
                        rowDivider
                        subagentsRow
                    }
                    .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.contentStroke, lineWidth: 1)
                    )

                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.caption2)
                        Text("Every option here can be changed later in Settings.")
                            .font(.caption)
                    }
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                }
                .padding(24)
            }
            .background(AppTheme.windowBackground)

            Divider()
            HStack {
                Button("Back") { onBack() }
                    .appSecondaryButton()
                Spacer()
                Button(finishButtonTitle) {
                    onFinish(finishTarget)
                }
                .appPrimaryButton()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 660, height: 560)
        .background(AppTheme.windowBackground)
        .task {
            viewModel.ensureAvailableModelsLoaded()
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    // MARK: Gates & finish state

    private var githubPassed: Bool {
        setupItems.first { $0.id == "github" }?.status == .passed
    }

    // No models + a finished discovery pass (modelsLastUpdatedAt set) means there
    // genuinely are none, not that we're still loading.
    private var modelsAreLoading: Bool {
        viewModel.enabledAvailableModels.isEmpty && viewModel.modelsLastUpdatedAt == nil
    }

    private var needsDoctor: Bool {
        setupItems.contains { $0.status == .failed }
    }

    private var finishTarget: SidebarItem? {
        if needsDoctor { return .doctor }
        if viewModel.enabledProjects.isEmpty, !viewModel.discoveredProjects.isEmpty { return .projects }
        return nil
    }

    private var finishButtonTitle: String {
        needsDoctor ? "Review Setup" : "Done"
    }

    // MARK: Rows

    private var worktreeRow: some View {
        OnboardingPreferenceRow(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Worktree isolation",
            caption: "Each new Pi session gets its own git branch in an isolated working copy. Use the Merge toolbar action to bring work back."
        ) {
            Toggle("", isOn: Binding(
                get: { viewModel.appSettings.piAgentSessionsUseWorktree },
                set: { viewModel.setPiAgentSessionsUseWorktree($0) }
            ))
            .appCheckbox()
            .labelsHidden()
        }
    }

    private var modelRow: some View {
        OnboardingPreferenceRow(
            icon: "cpu",
            title: "Default model",
            caption: "Used when starting new sessions. You can still pick a different model per session.",
            secondary: AnyView(modelAndThinkingControl)
        ) {
            EmptyView()
        }
    }

    private var modelAndThinkingControl: some View {
        HStack(spacing: 16) {
            Picker("", selection: defaultModelBinding) {
                if viewModel.enabledAvailableModels.isEmpty {
                    Text(modelsAreLoading ? "Loading models…" : "No models available").tag("")
                }
                ForEach(viewModel.enabledAvailableModels, id: \.identifier) { model in
                    Text(model.displayName).tag(model.identifier)
                }
            }
            .appMenuPicker()
            .labelsHidden()
            .tint(AppTheme.brandAccent)
            .frame(width: 220)

            HStack(spacing: 8) {
                Text("Thinking:")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                Picker("", selection: thinkingLevelBinding) {
                    Text("Off").tag("off")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .appMenuPicker()
                .labelsHidden()
                .tint(AppTheme.brandAccent)
                .fixedSize()
            }
        }
        .padding(.top, 8)
    }

    private var autoTitlesRow: some View {
        OnboardingPreferenceRow(
            icon: "sparkles",
            title: "Auto-generate session titles",
            caption: "Drafts a short title from the first request in each session.",
            secondary: viewModel.appSettings.autoGeneratePiAgentSessionTitles ? AnyView(titleModelControl) : nil
        ) {
            Toggle("", isOn: Binding(
                get: { viewModel.appSettings.autoGeneratePiAgentSessionTitles },
                set: { viewModel.setAutoGeneratePiAgentSessionTitles($0) }
            ))
            .appCheckbox()
            .labelsHidden()
        }
    }

    private var titleModelControl: some View {
        HStack(spacing: 8) {
            Text("Title model:")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            Picker("", selection: titleGenerationModelBinding) {
                Text("Default model").tag("")
                ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                    Text(model.displayName).tag(model.identifier)
                }
            }
            .appMenuPicker()
            .labelsHidden()
            .tint(AppTheme.brandAccent)
            .fixedSize()
        }
        .padding(.top, 6)
    }

    private var gitAutomationRow: some View {
        OnboardingPreferenceRow(
            icon: "arrow.triangle.branch",
            title: "Git automation",
            caption: "Show Commit and Push actions in the session toolbar. Commit messages are drafted by a model.",
            disabledHint: githubPassed ? nil : "Connect GitHub in Setup to enable.",
            openSetup: githubPassed ? nil : onBack,
            secondary: (viewModel.appSettings.piAgentGitAutomationEnabled && githubPassed) ? AnyView(commitMessageModelControl) : nil
        ) {
            Toggle("", isOn: Binding(
                get: { viewModel.appSettings.piAgentGitAutomationEnabled },
                set: { viewModel.setPiAgentGitAutomationEnabled($0) }
            ))
            .appCheckbox()
            .labelsHidden()
            .disabled(!githubPassed)
        }
    }

    private var commitMessageModelControl: some View {
        HStack(spacing: 8) {
            Text("Commit model:")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            Picker("", selection: commitMessageModelBinding) {
                Text("Choose model…").tag("")
                ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                    Text(model.displayName).tag(model.identifier)
                }
            }
            .appMenuPicker()
            .labelsHidden()
            .tint(AppTheme.brandAccent)
            .fixedSize()
        }
        .padding(.top, 6)
    }

    private var subagentsRow: some View {
        OnboardingPreferenceRow(
            icon: "paperplane",
            title: "Deck agents",
            caption: "Let new sessions delegate focused work to Deck agents you've configured."
        ) {
            Toggle("", isOn: Binding(
                get: { viewModel.areSubagentsEnabledForNewSessions },
                set: { viewModel.setSubagentsEnabledForNewSessions($0) }
            ))
            .appCheckbox()
            .labelsHidden()
        }
    }

    // MARK: Bindings

    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { viewModel.defaultPiAgentModel()?.identifier ?? "" },
            set: { newID in
                guard !newID.isEmpty,
                      let model = viewModel.enabledAvailableModels.first(where: { $0.identifier == newID })
                else { return }
                viewModel.setDefaultPiAgentModel(model)
            }
        )
    }

    private var thinkingLevelBinding: Binding<String> {
        Binding(
            get: {
                let level = viewModel.piRuntimeDefaultThinkingLevel()
                return level == "none" ? "off" : level
            },
            set: { viewModel.setDefaultPiAgentThinkingLevel($0) }
        )
    }

    private var commitMessageModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.piAgentCommitMessageModelIdentifier ?? "" },
            set: { viewModel.setPiAgentCommitMessageModelIdentifier($0) }
        )
    }

    private var titleGenerationModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.piAgentTitleGenerationModelIdentifier ?? "" },
            set: { viewModel.setPiAgentTitleGenerationModelIdentifier($0) }
        )
    }
}

private struct OnboardingPreferenceRow<Control: View>: View {
    let icon: String
    let title: String
    let caption: String
    var disabledHint: String? = nil
    var openSetup: (() -> Void)? = nil
    var secondary: AnyView? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabledHint == nil ? AppTheme.brandAccent : .secondary)
                .frame(width: 28, height: 24, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if let disabledHint {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text(disabledHint)
                            .font(.caption.weight(.medium))
                        if let openSetup {
                            Button("Open Setup", action: openSetup)
                                .buttonStyle(.link)
                                .font(.caption.weight(.medium))
                        }
                    }
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.top, 2)
                }
                if let secondary {
                    secondary
                }
            }

            Spacer(minLength: 16)

            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

