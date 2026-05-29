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
                title: "Orchestrate Subagents",
                description: "Delegate focused work to custom subagents, run them alone or in parallel, supervise decisions, and keep worktrees isolated."
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
    @State private var phase: Phase = .tour
    @State private var setupItemsTask: Task<[SetupCheckItem], Never>?
    @State private var setupItems: [SetupCheckItem] = []

    private enum Phase {
        case tour
        case setup
        case preferences
    }

    var body: some View {
        Group {
            switch phase {
            case .tour:
                tourView
            case .setup:
                SetupChecklistView(
                    viewModel: viewModel,
                    preloadedItems: setupItemsTask,
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
                    onFinish: onFinish
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
            onFinish: { phase = .setup },
            onClose: { onFinish(nil) }
        )
        .frame(width: 660)
    }

    private func preloadSetupChecksIfNeeded() {
        guard setupItemsTask == nil else { return }
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

struct SetupChecklistView: View {
    var viewModel: AppViewModel
    fileprivate let preloadedItems: Task<[SetupCheckItem], Never>?
    let onBack: () -> Void
    let onContinue: ([SetupCheckItem]) -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = true

    fileprivate init(
        viewModel: AppViewModel,
        preloadedItems: Task<[SetupCheckItem], Never>? = nil,
        onBack: @escaping () -> Void,
        onContinue: @escaping ([SetupCheckItem]) -> Void
    ) {
        self.viewModel = viewModel
        self.preloadedItems = preloadedItems
        self.onBack = onBack
        self.onContinue = onContinue
    }

    var body: some View {
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
        .frame(width: 660, height: 560)
        .background(AppTheme.windowBackground)
        .task {
            if items.isEmpty {
                await loadInitialItems()
            }
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
        if let preloadedItems {
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
            suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath
        )
    }

    private func setupRow(_ item: SetupCheckItem) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.status.color)
                .frame(width: 28)

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

    private func perform(_ action: SetupCheckAction) {
        // First-run setup: replace the auto-seeded default rather than
        // appending, so picking a custom folder yields a single-entry list
        // (matching the user's mental model from the original UX).
        let replacing = !viewModel.hasConfirmedProjectsRootPaths
        switch action {
        case .chooseProjectRoot:
            viewModel.chooseProjectsRootDirectory(replacingExisting: replacing)
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory(replacingExisting: replacing)
        }
        Task { await refresh() }
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

    var buttonTitle: String {
        switch self {
        case .chooseProjectRoot: "Choose Folder…"
        case .useSuggestedProjectRoot: "Use Suggested Folder"
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

struct SetupDependencyService {
    private let commandRunner = CommandRunner()
    private let piResolver = PiExecutableResolver()

    func loadItems(
        projectRootPaths: [String],
        githubAccount: GitHubHostAccount?,
        selectedProjectPath: String?,
        hasConfirmedProjectsRootPaths: Bool = true,
        suggestedProjectsRootPath: String? = nil
    ) async -> [SetupCheckItem] {
        async let pi = piCheck()
        async let models = modelCheck()
        let github = await githubCheck(account: githubAccount)
        let project = projectRootCheck(paths: projectRootPaths, isConfirmed: hasConfirmedProjectsRootPaths, suggestedPath: suggestedProjectsRootPath)
        let primaryRootPath = projectRootPaths.first
        let web = webAccessCheck(projectRootPath: selectedProjectPath ?? primaryRootPath)

        return await [pi, models, project, github, web]
    }

    private func piCheck() async -> SetupCheckItem {
        let piCommand = piResolver.resolve()?.path ?? "pi"

        do {
            let result = try await commandRunner.run(piCommand, arguments: ["--help"], timeout: 6)
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi",
                detail: result.exitCode == 0
                    ? "Pi is installed and available to \(AppBrand.displayName)."
                    : "`pi --help` exited with code \(result.exitCode).",
                status: result.exitCode == 0 ? .passed : .failed,
                recovery: result.exitCode == 0 ? nil : "Install Pi, then verify `pi --help` works in Terminal."
            )
        } catch {
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi",
                detail: "Install Pi and make sure `pi` is available from your login shell.",
                status: .failed,
                recovery: "Install Pi, then verify `pi --help` works in Terminal."
            )
        }
    }

    private func modelCheck() async -> SetupCheckItem {
        let models = await PiModelDiscoveryService(commandRunner: commandRunner, piResolver: piResolver).loadAvailableModels()
        if !models.isEmpty {
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "\(models.count) models are available to \(AppBrand.displayName).",
                status: .passed,
                recovery: nil
            )
        }

        do {
            let piCommand = piResolver.resolve()?.path ?? "pi"
            let result = try await commandRunner.run(piCommand, arguments: ["--list-models"], timeout: 20)
            let listOutput = result.stdout.isEmpty ? result.stderr : result.stdout
            let modelRowCount = Self.modelRowCount(fromPiListOutput: listOutput)
            if result.exitCode == 0, modelRowCount > 0 {
                return SetupCheckItem(
                    id: "pi-models",
                    title: "Pi Models",
                    detail: "\(modelRowCount) models available.",
                    status: .passed,
                    recovery: nil
                )
            }
            let rawPreview = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = rawPreview.isEmpty ? (result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no output)" : "stderr: \(result.stderr.prefix(200))") : String(rawPreview.prefix(200))
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "`pi --list-models` exited with code \(result.exitCode) and did not return usable models. Output: \(preview)",
                status: .failed,
                recovery: "Run `pi --list-models` in Terminal and complete any provider/model setup Pi reports."
            )
        } catch {
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "`pi --list-models` did not return any usable models.",
                status: .failed,
                recovery: "Run `pi --list-models` in Terminal and complete any provider/model setup Pi reports."
            )
        }
    }

    private func projectRootCheck(paths: [String], isConfirmed: Bool, suggestedPath: String?) -> SetupCheckItem {
        let resolvedPaths = paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let existingPaths = resolvedPaths.filter { path in
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let hasAnyConfigured = !resolvedPaths.isEmpty
        let hasAnyExisting = !existingPaths.isEmpty
        let hasSuggestedDirectory = suggestedPath?.isEmpty == false

        if !isConfirmed || !hasAnyConfigured {
            return SetupCheckItem(
                id: "project-root",
                title: "Projects Folders",
                detail: hasSuggestedDirectory
                    ? "Choose at least one parent folder that contains your projects. Suggested: \(suggestedPath!)"
                    : "Choose at least one parent folder that contains your projects.",
                status: .failed,
                recovery: nil,
                action: hasSuggestedDirectory ? .useSuggestedProjectRoot : .chooseProjectRoot,
                secondaryAction: hasSuggestedDirectory ? .chooseProjectRoot : nil
            )
        }

        // Confirmed and at least one path is on disk → pass; otherwise prompt
        // the user to pick one (every configured entry has disappeared).
        let detail: String
        if hasAnyExisting {
            detail = existingPaths.count == 1
                ? existingPaths[0]
                : "\(existingPaths.count) folders configured: \(existingPaths.joined(separator: ", "))"
        } else {
            detail = "None of the configured folders exist anymore. Choose a parent folder that contains your projects."
        }

        return SetupCheckItem(
            id: "project-root",
            title: "Projects Folders",
            detail: detail,
            status: hasAnyExisting ? .passed : .failed,
            recovery: hasAnyExisting ? nil : "Choose an existing parent folder for your projects.",
            action: hasAnyExisting ? nil : .chooseProjectRoot
        )
    }

    private func webAccessCheck(projectRootPath: String?) -> SetupCheckItem {
        let projectRoot = projectRootPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectRoot)
        let hasKey = environment["EXA_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let fallbackInstalled = WebFetchDependencyService().status().isInstalled

        if hasKey {
            return SetupCheckItem(
                id: "web-access",
                title: "Web Access",
                detail: "EXA_API_KEY is configured. Exa web tools are available to new Pi sessions.",
                status: .passed,
                recovery: nil
            )
        }

        if fallbackInstalled {
            return SetupCheckItem(
                id: "web-access",
                title: "Web Access",
                detail: "Optional. URL fetch fallback dependencies are installed. Configure Exa search later in Doctor if you want web search.",
                status: .warning,
                recovery: nil
            )
        }

        return SetupCheckItem(
            id: "web-access",
            title: "Web Access",
            detail: "Optional. Configure Exa search or install the URL fetch fallback later in Doctor.",
            status: .warning,
            recovery: nil
        )
    }

    private func githubCheck(account: GitHubHostAccount?) async -> SetupCheckItem {
        let resolvedAccount: GitHubHostAccount?
        if let account {
            resolvedAccount = account
        } else {
            resolvedAccount = await GitHubCLIAuthService(commandRunner: commandRunner).loadStatus().account
        }

        if let resolvedAccount {
            return SetupCheckItem(
                id: "github",
                title: "GitHub",
                detail: "Connected as \(resolvedAccount.login) on \(resolvedAccount.host).",
                status: .passed,
                recovery: nil
            )
        }

        return SetupCheckItem(
            id: "github",
            title: "GitHub",
            detail: "Optional. Install GitHub CLI and run `gh auth login` for issue, comment, commit, and push workflows.",
            status: .warning,
            recovery: "Install GitHub CLI, run `gh auth login`, then refresh this check."
        )
    }

    private static func modelRowCount(fromPiListOutput text: String) -> Int {
        text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .filter { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.count >= 2
            }
            .count
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
            title: "Native subagents",
            caption: "Let new sessions delegate focused work to subagents you've configured."
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
