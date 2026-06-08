import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PiTerminalCoordinator {
    weak var host: PiTerminalHost?

    private let sessionStore: PiAgentSessionStore

    init(sessionStore: PiAgentSessionStore) {
        self.sessionStore = sessionStore
    }

    func attach(host: PiTerminalHost) {
        self.host = host
    }

    var canOpenSelectedSessionInTerminal: Bool {
        guard let session = sessionStore.selectedSession else { return false }
        if let sessionFile = session.piSessionFile, FileManager.default.fileExists(atPath: sessionFile) { return true }
        return session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func openPiSelfUpdateInTerminal() {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-pi-update-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let updateCommand = terminalPiSelfUpdateCommand()
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport(prepending: resolvedPiPathForShell()))
        \(updateCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create Pi update terminal script: \(error.localizedDescription)")
#endif
        }
    }

    func openPiInstallInTerminal() {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-pi-install-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let installCommand = """
        npm install -g @earendil-works/pi-coding-agent || { echo "npm not found. Install Node.js first."; }
        echo ""
        echo "Press any key to close."
        read -k 1
        """
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport())
        \(installCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create Pi install terminal script: \(error.localizedDescription)")
#endif
        }
    }

    /// Installs the GitHub CLI if needed, then runs `gh auth login` — one
    /// "Set up GitHub" action covering both steps in a single Terminal session.
    /// the GitHub install/login helpers (mirrors `openPiInstallInTerminal`).
    func openShellScript(named: String, body: String) {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-\(named)-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport())
        \(body)
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create \(named) terminal script: \(error.localizedDescription)")
#endif
        }
    }

    func openSelectedSessionInTerminal() {
        guard let session = sessionStore.selectedSession,
              let sessionRef = resumablePiSessionReference(for: session) else { return }
        host?.onTerminalResumeOpened(forSessionID: session.id)

        let workingDirectory = session.worktreePath ?? session.projectPath
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-resume-\(session.id.uuidString)")
            .appendingPathExtension("command")
        let resumeCommand = terminalResumeCommand(workingDirectory: workingDirectory, sessionReference: sessionRef)
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport(prepending: resolvedPiPathForShell()))
        \(resumeCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: session.id)
            sessionStore.append(.init(sessionID: session.id, role: .status, title: "Opened in Terminal", text: "Opened in Terminal."))
        } catch {
            sessionStore.updateSession(session.id) { record in
                record.lastError = error.localizedDescription
            }
        }
    }

    private func resumablePiSessionReference(for session: PiAgentSessionRecord) -> String? {
        if let sessionFile = session.piSessionFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionFile.isEmpty,
           FileManager.default.fileExists(atPath: sessionFile) {
            return sessionFile
        }
        if let sessionID = session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return sessionID
        }
        if let sessionFile = session.piSessionFile?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionFile.isEmpty {
            sessionStore.updateSession(session.id) { record in
                record.lastError = "Pi session file no longer exists; trying session id if available."
            }
        }
        return nil
    }

    private func terminalPiSelfUpdateCommand() -> String {
        let piPath = resolvedPiPathForShell()
        return """
        "\(piPath)" update pi || { echo "Pi not found. Install pi or add it to PATH."; }
        echo ""
        echo "Press any key to close."
        read -k 1
        """
    }

    private func terminalResumeCommand(workingDirectory: String, sessionReference: String) -> String {
        let piPath = resolvedPiPathForShell()
        return """
        cd \(shellQuoted(workingDirectory)) || exit 1
        "\(piPath)" --session \(shellQuoted(sessionReference)) || { echo "Pi not found. Install pi or add it to PATH."; echo ""; echo "Command: pi --session \(shellQuoted(sessionReference))"; read -k 1 "?Press any key to close."; }
        """
    }

    private func openTerminalScript(_ scriptURL: URL, for sessionID: UUID) {
        let trimmedPath = host?.piAgentTerminalApplicationPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        // No explicit choice → macOS Terminal.
        guard let selectedTerminalPath = trimmedPath, !selectedTerminalPath.isEmpty else {
            if openInAppleTerminal(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: defaultTerminalURL(), sessionID: sessionID)
            return
        }

        // An unrecognised app should not survive the validation in Settings, but a stale
        // selection from an older build still might — fall back to a best-effort open.
        guard let terminal = SupportedTerminal(appPath: selectedTerminalPath) else {
            let terminalURL = URL(fileURLWithPath: selectedTerminalPath)
            guard FileManager.default.fileExists(atPath: terminalURL.path) else {
                sessionStore.updateSession(sessionID) { record in
                    record.lastError = "Selected terminal app no longer exists. Choose another app in Settings."
                }
                return
            }
            openCommandFile(scriptURL, withApplicationAt: terminalURL, sessionID: sessionID)
            return
        }

        switch terminal {
        case .appleTerminal:
            if openInAppleTerminal(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: defaultTerminalURL(), sessionID: sessionID)
        case .iTerm:
            if openInITerm(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: URL(fileURLWithPath: selectedTerminalPath), sessionID: sessionID)
        case .ghostty, .kitty, .alacritty, .wezTerm:
            if launchTerminalCLI(terminal, appPath: selectedTerminalPath, scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: URL(fileURLWithPath: selectedTerminalPath), sessionID: sessionID)
        }
    }

    /// Launches a CLI-driven terminal (Ghostty, kitty, Alacritty, WezTerm) so it opens a
    /// new window running the prepared `.command` script via `/bin/zsh`. Returns `false`
    /// if the terminal's executable could not be found or started.
    @discardableResult
    private func launchTerminalCLI(_ terminal: SupportedTerminal, appPath: String, scriptURL: URL, sessionID: UUID) -> Bool {
        guard let launcher = terminal.commandLineLauncher else { return false }
        let executableURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(launcher.executable)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = launcher.leadingArguments + ["/bin/zsh", scriptURL.path]
        do {
            try process.run()
            return true
        } catch {
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            sessionStore.updateSession(sessionID) { record in
                record.lastError = "Could not launch \(name): \(error.localizedDescription)"
            }
            return false
        }
    }

    private func openCommandFile(_ scriptURL: URL, withApplicationAt terminalURL: URL?, sessionID: UUID) {
        guard let terminalURL else {
            guard NSWorkspace.shared.open(scriptURL) else {
                sessionStore.updateSession(sessionID) { record in
                    record.lastError = "Could not open the default terminal app."
                }
                return
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sessionStore = sessionStore
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                sessionStore.updateSession(sessionID) { record in
                    record.lastError = error.localizedDescription
                }
            }
        }
    }

    private func defaultTerminalURL() -> URL? {
        [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Runs the prepared `#!/bin/zsh` `.command` file in Terminal. We point `do script`
    /// at the script path (chmod 755 + shebang) rather than typing the raw multi-line
    /// command, so behavior no longer depends on the user's interactive login shell.
    @discardableResult
    private func openInAppleTerminal(scriptURL: URL, sessionID: UUID) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(scriptURL.path))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open Terminal.")
    }

    /// Runs the prepared `.command` file in iTerm. iTerm's `command` parameter must be a
    /// single executable to exec — passing a multi-line shell snippet makes iTerm try to
    /// exec a bogus argv[0] and end the session immediately ("session ended very soon
    /// after starting"). The script file is executable with a shebang, so exec works.
    @discardableResult
    private func openInITerm(scriptURL: URL, sessionID: UUID) -> Bool {
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "\(appleScriptEscaped(scriptURL.path))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open iTerm.")
    }

    @discardableResult
    private func runAppleScript(_ source: String, sessionID: UUID, fallbackMessage: String) -> Bool {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            sessionStore.updateSession(sessionID) { $0.lastError = fallbackMessage }
            return false
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? fallbackMessage
            sessionStore.updateSession(sessionID) { record in
                record.lastError = message
            }
            return false
        }
        return true
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func resolvedPiPathForShell() -> String {
        PiExecutableResolver().resolve()?.path ?? "pi"
    }

    // Terminal.app launches `.command` scripts with a minimal PATH (no nvm/Homebrew),
    // so `pi`'s `#!/usr/bin/env node` shebang fails to find `node`. Mirror the in-app
    // PATH augmentation from PiAgentProcess.processEnvironment.
    private func augmentedShellPATHExport(prepending piPath: String? = nil) -> String {
        var dirs: [String] = []
        if let piPath, !piPath.isEmpty, piPath != "pi" {
            let dir = (piPath as NSString).deletingLastPathComponent
            if !dir.isEmpty { dirs.append(dir) }
        }
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        return "export PATH=\"\(dirs.joined(separator: ":")):$PATH\""
    }
}
