import Foundation
import SwiftUI

// Full Setup: probe the execution host through whichever backend is active,
// report what is present, install what is missing with the host's own package
// manager, then apply the resulting paths to the app's configuration.
//
// The app cannot install anything into itself. A stock sideload runs in a
// sandbox with no ability to spawn processes at all, so every install and probe
// here goes through the CrossBuild Helper (jailbreak-local or remote). When no
// such backend is available this screen reports that plainly and offers the
// exact command to run, instead of pretending a button did something.

enum SetupStepKind: String {
    case probe = "Detect"
    case install = "Install"
    case configure = "Configure"
}

enum SetupStepStatus: String {
    case pending = "Pending"
    case running = "Running"
    case succeeded = "Done"
    case failed = "Failed"
    case skipped = "Skipped"
}

enum SetupConfigureAction: String {
    case applyPath
    case applyTheosPath
    case applySDK
    case detectProject
}

struct SetupStep: Identifiable {
    var id: String
    var title: String
    var detail: String
    var kind: SetupStepKind
    var command: String
    var status: SetupStepStatus = .pending
    var output: String = ""
    var configureAction: SetupConfigureAction? = nil
}

struct SetupEnvironment {
    var backendName: String = "Unknown"
    var canSpawnProcesses: Bool = false
    var canInstallPackages: Bool = false
    var isRoot: Bool = false
    var hasSudo: Bool = false
    var osDescription: String = ""
    var packageManager: String = ""
    var helperMessage: String = ""
    var path: String = ""
    var theosPath: String = ""
    var sdkPath: String = ""
    var notes: [String] = []
}

/// One requirement to check for, and how to obtain it on each package manager.
/// `packages` is only populated where a real package name is known; an absent
/// entry means "we do not know how to install this here", which is reported as
/// skipped rather than guessed at.
struct SetupTool: Identifiable {
    var id: String
    var name: String
    var binary: String
    var group: String
    var packages: [String: String]
    var hint: String
    var essential: Bool
}

enum SetupCatalog {
    static let tools: [SetupTool] = [
        .init(id: "git", name: "Git", binary: "git", group: "Core",
              packages: ["apk": "git", "apt-get": "git", "dnf": "git", "yum": "git", "pacman": "git", "brew": "git"],
              hint: "Needed to clone repositories and Theos.", essential: true),
        .init(id: "make", name: "Make", binary: "make", group: "Core",
              packages: ["apk": "make", "apt-get": "make", "dnf": "make", "yum": "make", "pacman": "make", "brew": "make"],
              hint: "Build executor used by Theos and most native projects.", essential: true),
        .init(id: "python3", name: "Python 3", binary: "python3", group: "Core",
              packages: ["apk": "python3", "apt-get": "python3", "dnf": "python3", "yum": "python3", "pacman": "python", "brew": "python3"],
              hint: "Runs the CrossBuild Helper itself and Python projects.", essential: true),

        .init(id: "clang", name: "Clang", binary: "clang", group: "Native",
              packages: ["apk": "clang", "apt-get": "clang", "dnf": "clang", "yum": "clang", "pacman": "clang", "brew": "llvm"],
              hint: "C, C++, Objective-C and Objective-C++.", essential: true),
        .init(id: "cmake", name: "CMake", binary: "cmake", group: "Build systems",
              packages: ["apk": "cmake", "apt-get": "cmake", "dnf": "cmake", "yum": "cmake", "pacman": "cmake", "brew": "cmake"],
              hint: "Cross-platform build-system generator.", essential: false),
        .init(id: "ninja", name: "Ninja", binary: "ninja", group: "Build systems",
              packages: ["apk": "ninja-build", "apt-get": "ninja-build", "dnf": "ninja-build", "yum": "ninja-build", "pacman": "ninja", "brew": "ninja"],
              hint: "Fast low-level build executor.", essential: false),
        .init(id: "meson", name: "Meson", binary: "meson", group: "Build systems",
              packages: ["apk": "meson", "apt-get": "meson", "dnf": "meson", "yum": "meson", "pacman": "meson", "brew": "meson"],
              hint: "Modern build system; needs Ninja and Python.", essential: false),

        .init(id: "node", name: "Node.js", binary: "node", group: "Runtimes",
              packages: ["apk": "nodejs", "apt-get": "nodejs", "dnf": "nodejs", "yum": "nodejs", "pacman": "nodejs", "brew": "node"],
              hint: "JavaScript / TypeScript projects.", essential: false),

        .init(id: "dpkg-deb", name: "dpkg-deb", binary: "dpkg-deb", group: "Jailbreak packaging",
              packages: ["apk": "dpkg", "apt-get": "dpkg", "dnf": "dpkg", "yum": "dpkg", "pacman": "dpkg", "brew": "dpkg"],
              hint: "Builds .deb packages for jailbreak projects.", essential: false),
        .init(id: "ldid", name: "ldid", binary: "ldid", group: "Jailbreak packaging",
              packages: ["brew": "ldid"],
              hint: "Fake-signs binaries for jailbroken devices. Usually built from source on iOS; not in most Linux repos.", essential: false),

        .init(id: "swift", name: "Swift", binary: "swift", group: "Toolchains (large, often unavailable)",
              packages: [:],
              hint: "No iOS/Linux package entry here: a Swift toolchain for the device itself is not normally installable this way. Use a macOS or Linux build host.", essential: false),
        .init(id: "cargo", name: "Rust / Cargo", binary: "cargo", group: "Toolchains (large, often unavailable)",
              packages: ["brew": "rust"],
              hint: "Install rustup manually on a build host; rustup is not a package-manager package.", essential: false),
        .init(id: "go", name: "Go", binary: "go", group: "Toolchains (large, often unavailable)",
              packages: ["apk": "go", "apt-get": "golang-go", "dnf": "golang", "yum": "golang", "pacman": "go", "brew": "go"],
              hint: "Large install; available as a package on most hosts.", essential: false),
        .init(id: "zig", name: "Zig", binary: "zig", group: "Toolchains (large, often unavailable)",
              packages: ["apk": "zig", "brew": "zig"],
              hint: "Very large install; usually distributed as a tarball outside apk/brew.", essential: false)
    ]

    static let probeBinaries: [String] = tools.map(\.binary)

    static func installCommand(manager: String, packages: [String], useSudo: Bool) -> String? {
        guard !packages.isEmpty, !manager.isEmpty else { return nil }
        let joined = packages.joined(separator: " ")
        let base: String
        switch manager {
        case "apk": base = "apk add --no-cache " + joined
        case "apt-get": base = "apt-get update && apt-get install -y " + joined
        case "dnf": base = "dnf install -y " + joined
        case "yum": base = "yum install -y " + joined
        case "pacman": base = "pacman -S --noconfirm " + joined
        case "brew": base = "brew install " + joined
        default: return nil
        }
        return useSudo ? "sudo " + base : base
    }

    /// Sets KEY=VALUE in a multi-line environment block, replacing any existing
    /// entry for that key rather than appending a duplicate.
    static func upsertEnvLine(_ existing: String, key: String, value: String) -> String {
        let prefix = key + "="
        var lines = existing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(prefix) }
        lines.append(prefix + value)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Service

@MainActor
final class SetupService: ObservableObject {
    @Published private(set) var environment = SetupEnvironment()
    @Published private(set) var presence: [String: Bool] = [:]
    @Published private(set) var steps: [SetupStep] = []
    @Published private(set) var isRunning = false
    @Published private(set) var runningStepID: String?
    @Published private(set) var summary = ""
    @Published private(set) var didPrepare = false
    @Published private(set) var statusLine = "Not checked yet."

    static let probeStepID = "probe"
    static let installStepID = "install"

    var missingTools: [SetupTool] { SetupCatalog.tools.filter { presence[$0.binary] != true } }
    var presentTools: [SetupTool] { SetupCatalog.tools.filter { presence[$0.binary] == true } }
    var plannedInstallPackages: [String] {
        var names: [String] = []
        for tool in missingTools {
            if let name = tool.packages[environment.packageManager] { names.append(name) }
        }
        return Array(Set(names)).sorted()
    }

    // MARK: Probe commands

    /// One round trip for everything about the host. Each line is `KEY=value`
    /// with the key parsed on the first '='.
    private static let environmentProbeCommand: String = [
        "printf 'OS=%s\\n' \"$(uname -srm 2>/dev/null)\"",
        "printf 'UID=%s\\n' \"$(id -u 2>/dev/null)\"",
        "printf 'SUDO=%s\\n' \"$(command -v sudo >/dev/null 2>&1 && echo yes || echo no)\"",
        "printf 'PATH=%s\\n' \"$PATH\"",
        "printf 'THEOS=%s\\n' \"${THEOS:-}\"",
        "printf 'SDK=%s\\n' \"$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)\"",
        "for m in apk apt-get dnf yum pacman brew; do if command -v \"$m\" >/dev/null 2>&1; then printf 'PM=%s\\n' \"$m\"; fi; done",
        "true"
    ].joined(separator: "\n")

    private static var toolProbeCommand: String {
        let binaries = SetupCatalog.probeBinaries.joined(separator: " ")
        return "for t in \(binaries); do printf 'TOOL:%s=%s\\n' \"$t\" \"$(command -v \"$t\" >/dev/null 2>&1 && echo yes || echo no)\"; done; true"
    }

    // MARK: Steps

    /// Detect the host, then build a plan from what was found. Safe to call
    /// repeatedly; it re-probes rather than trusting earlier results.
    func prepare(workspace: WorkspaceModel, settings: AppSettings) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        summary = ""

        let resolved = workspace.resolvedBackend(settings: settings)
        var env = SetupEnvironment()
        env.backendName = resolved.backend.name
        env.canSpawnProcesses = resolved.backend.capabilities.canSpawnProcesses
        env.canInstallPackages = resolved.backend.capabilities.canInstallPackages

        guard env.canSpawnProcesses else {
            env.notes.append("The active backend cannot start processes. Cross Build cannot detect or install anything from within the app on a stock sideload.")
            env.notes.append("Run Tools/crossbuild-helper.py on a jailbroken device (then choose Jailbreak Local), or point Settings → App Configuration at a helper on a build host.")
            environment = env
            presence = [:]
            didPrepare = false
            steps = buildPlan()
            statusLine = "No executable backend."
            summary = "Setup cannot run: no backend can spawn processes."
            return
        }

        statusLine = "Detecting host…"
        let envResult = await workspace.executeCommand(Self.environmentProbeCommand, settings: settings)
        let values = parseKeyValues(envResult.stdout)
        env.osDescription = values["OS"] ?? ""
        env.isRoot = values["UID"] == "0"
        env.hasSudo = values["SUDO"] == "yes"
        env.packageManager = values["PM"] ?? ""
        env.path = values["PATH"] ?? ""
        env.theosPath = values["THEOS"] ?? ""
        env.sdkPath = values["SDK"] ?? ""
        if !envResult.succeeded {
            env.notes.append("The environment probe exited with code \(envResult.exitCode); results below may be incomplete.")
        }

        statusLine = "Checking installed tools…"
        let toolResult = await workspace.executeCommand(Self.toolProbeCommand, settings: settings)
        presence = parsePresence(toolResult.stdout)
        if presence.isEmpty {
            // A busy workspace or an unreachable helper yields no TOOL: lines.
            // Say so, rather than letting an empty result read as "everything is
            // missing" and planning a pointless mass install.
            env.notes.append("Tool detection returned no results (the backend may be busy or unreachable). Re-detect once any running command has finished.")
        }

        if env.packageManager.isEmpty {
            env.notes.append("No supported package manager was found on the host, so missing tools cannot be installed automatically.")
        }
        if !env.isRoot && !env.hasSudo {
            env.notes.append("The host user is not root and sudo is unavailable, so package installation will most likely fail.")
        }
        environment = env
        didPrepare = true
        steps = buildPlan()
        statusLine = "Found \(presentTools.count) of \(SetupCatalog.tools.count) tools."
        summary = statusLine
    }

    private func buildPlan() -> [SetupStep] {
        var planned: [SetupStep] = []
        planned.append(SetupStep(
            id: Self.probeStepID,
            title: "Detect environment",
            detail: environmentDetail(),
            kind: .probe,
            command: "",
            status: didPrepare ? .succeeded : .pending,
            output: environmentDetail()
        ))

        let packages = plannedInstallPackages
        if !presence.isEmpty, !packages.isEmpty,
           let command = SetupCatalog.installCommand(manager: environment.packageManager,
                                                     packages: packages,
                                                     useSudo: !environment.isRoot && environment.hasSudo) {
            planned.append(SetupStep(
                id: Self.installStepID,
                title: "Install \(packages.count) package\(packages.count == 1 ? "" : "s")",
                detail: packages.joined(separator: ", ") + " via " + environment.packageManager,
                kind: .install,
                command: command
            ))
        }

        if !environment.path.isEmpty {
            planned.append(SetupStep(id: "cfg.path", title: "Apply host PATH",
                                     detail: "Writes PATH into Workspace → Build Profile so builds can resolve host tools",
                                     kind: .configure, command: "", configureAction: .applyPath))
        }
        if !environment.theosPath.isEmpty {
            planned.append(SetupStep(id: "cfg.theos", title: "Apply THEOS path",
                                     detail: environment.theosPath,
                                     kind: .configure, command: "", configureAction: .applyTheosPath))
        }
        if !environment.sdkPath.isEmpty {
            planned.append(SetupStep(id: "cfg.sdk", title: "Apply iOS SDK sysroot",
                                     detail: environment.sdkPath,
                                     kind: .configure, command: "", configureAction: .applySDK))
        }
        planned.append(SetupStep(id: "cfg.detect", title: "Detect project and toolchain",
                                 detail: "Runs project detection and generates the compiler configuration",
                                 kind: .configure, command: "", configureAction: .detectProject))
        return planned
    }

    /// Execute the plan. `settings.allowSetupInstalls` is the gate for the
    /// install step — it is checked here as well as in the UI so the two cannot
    /// disagree.
    func run(workspace: WorkspaceModel, settings: AppSettings) async {
        guard !isRunning, didPrepare else { return }
        isRunning = true
        defer { isRunning = false }

        var done = 0
        var failed = 0
        var skipped = 0

        for index in steps.indices {
            if steps[index].status == .succeeded { continue }

            if steps[index].kind == .install && !settings.allowSetupInstalls {
                steps[index].status = .skipped
                steps[index].output = "Package installation is turned off in Full Setup."
                skipped += 1
                continue
            }

            steps[index].status = .running
            runningStepID = steps[index].id
            statusLine = steps[index].title + "…"

            if let action = steps[index].configureAction {
                steps[index].output = apply(action, workspace: workspace)
                steps[index].status = .succeeded
                done += 1
            } else if !steps[index].command.isEmpty {
                let result = await workspace.executeCommand(steps[index].command, settings: settings)
                steps[index].output = trimmedOutput(result)
                steps[index].status = result.succeeded ? .succeeded : .failed
                if result.succeeded { done += 1 } else { failed += 1 }

                if steps[index].id == Self.installStepID && result.succeeded {
                    statusLine = "Re-checking installed tools…"
                    let verify = await workspace.executeCommand(Self.toolProbeCommand, settings: settings)
                    presence = parsePresence(verify.stdout)
                }
            } else {
                steps[index].status = .skipped
                skipped += 1
            }
            runningStepID = nil
        }

        summary = "Setup finished — \(done) done, \(failed) failed, \(skipped) skipped. \(presentTools.count)/\(SetupCatalog.tools.count) tools now present."
        statusLine = summary
        settings.setupCompletedAt = Self.timestamp()
        settings.setupLastSummary = summary
    }

    // MARK: Configuration actions

    private func apply(_ action: SetupConfigureAction, workspace: WorkspaceModel) -> String {
        switch action {
        case .applyPath:
            workspace.configuration.environmentVariables = SetupCatalog.upsertEnvLine(
                workspace.configuration.environmentVariables, key: "PATH", value: environment.path)
            return "PATH set to \(environment.path)"
        case .applyTheosPath:
            workspace.compilerConfiguration.theosPath = environment.theosPath
            return "THEOS path set to \(environment.theosPath)"
        case .applySDK:
            workspace.compilerConfiguration.sysroot = environment.sdkPath
            return "iOS SDK sysroot set to \(environment.sdkPath)"
        case .detectProject:
            workspace.detectSampleProject()
            return "Project detection ran; toolchain and compiler settings updated."
        }
    }

    // MARK: Helpers

    private func environmentDetail() -> String {
        var parts: [String] = []
        parts.append("Backend: " + environment.backendName)
        if !environment.osDescription.isEmpty { parts.append(environment.osDescription) }
        if !environment.packageManager.isEmpty { parts.append("package manager: " + environment.packageManager) }
        if environment.isRoot { parts.append("root") }
        else if environment.hasSudo { parts.append("sudo available") }
        return parts.joined(separator: " • ")
    }

    private func parseKeyValues(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func parsePresence(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TOOL:"), let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 5)..<eq])
            let value = String(line[line.index(after: eq)...])
            if !name.isEmpty { result[name] = (value == "yes") }
        }
        return result
    }

    private func trimmedOutput(_ result: CommandResult) -> String {
        var text = result.stdout
        if !result.stderr.isEmpty {
            text += (text.isEmpty ? "" : "\n") + result.stderr
        }
        let limit = 4000
        if text.count > limit { text = "… (truncated)\n" + String(text.suffix(limit)) }
        return text
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
