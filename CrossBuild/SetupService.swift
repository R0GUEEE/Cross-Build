import Foundation
import SwiftUI

enum SetupStepKind: String {
    case scan = "Scan"
    case verify = "Verify"
    case configure = "Configure"
}

enum SetupStepStatus: String {
    case pending = "Pending"
    case running = "Running"
    case succeeded = "Done"
    case failed = "Failed"
    case skipped = "Skipped"
}

struct SetupStep: Identifiable {
    var id: String
    var title: String
    var detail: String
    var kind: SetupStepKind
    var status: SetupStepStatus = .pending
    var output: String = ""
}

struct SetupEnvironment {
    var runtime = "Embedded / In-App"
    var linuxRuntime = "ios-linuxkit"
    var rootfsPresent = false
    var sdkCount = 0
    var toolchains: [AppToolchainScan] = []
    var notes: [String] = []
}

@MainActor
final class SetupService: ObservableObject {
    @Published private(set) var environment = SetupEnvironment()
    @Published private(set) var steps: [SetupStep] = []
    @Published private(set) var isRunning = false
    @Published private(set) var runningStepID: String?
    @Published private(set) var summary = ""
    @Published private(set) var didPrepare = false
    @Published private(set) var statusLine = "Not scanned yet."

    var presentTools: [AppToolchainScan] { environment.toolchains.filter(\.present) }
    var missingTools: [AppToolchainScan] { environment.toolchains.filter { !$0.present } }

    func prepare(workspace: WorkspaceModel, settings: AppSettings) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var env = SetupEnvironment()
        env.rootfsPresent = LinuxGuestEngine.isLinked && LinuxGuestEngine.isRootBundled
        env.sdkCount = IOSSDKDiscovery.bundledSDKs().count
        env.toolchains = AppToolchainLibraries.scanBundle()

        if !env.rootfsPresent {
            env.notes.append("Embedded ios-linuxkit rootfs is missing.")
        }
        if env.sdkCount == 0 {
            env.notes.append("No bundled SDK payload was discovered.")
        }
        let missing = env.toolchains.filter { !$0.present }
        if !missing.isEmpty {
            env.notes.append("\(missing.count) declared toolchain component(s) are missing from the installed IPA.")
        }

        environment = env
        steps = makeSteps(env)
        didPrepare = true
        statusLine = missing.isEmpty && env.rootfsPresent
            ? "In-app runtime scan complete."
            : "Scan complete with missing components."
    }

    func run(workspace: WorkspaceModel, settings: AppSettings) async {
        guard !isRunning else { return }
        if !didPrepare { await prepare(workspace: workspace, settings: settings) }

        isRunning = true
        defer { isRunning = false }

        for index in steps.indices {
            runningStepID = steps[index].id
            steps[index].status = .running

            switch steps[index].id {
            case "toolchains":
                let missing = environment.toolchains.filter { !$0.present }
                steps[index].output = environment.toolchains
                    .map { "\($0.present ? "READY" : "MISSING")  \($0.name)  \($0.location)\n\($0.detail)" }
                    .joined(separator: "\n\n")
                steps[index].status = missing.isEmpty ? .succeeded : .failed
            case "linux":
                steps[index].output = environment.rootfsPresent
                    ? "ios-linuxkit engine and fakefs-root are bundled."
                    : "ios-linuxkit engine/rootfs is incomplete."
                steps[index].status = environment.rootfsPresent ? .succeeded : .failed
            case "sdk":
                steps[index].output = "\(environment.sdkCount) bundled SDK(s) discovered."
                steps[index].status = environment.sdkCount > 0 ? .succeeded : .failed
            case "project":
                workspace.detectSampleProject()
                steps[index].output = workspace.generatedConfigurationSummary.joined(separator: "\n")
                steps[index].status = .succeeded
            default:
                steps[index].status = .skipped
            }
        }
        runningStepID = nil

        let failures = steps.filter { $0.status == .failed }.count
        summary = failures == 0
            ? "Setup verified the in-app runtime, compiler payloads, SDKs, and project configuration."
            : "Setup finished with \(failures) missing/incomplete component check(s)."
        settings.setupCompletedAt = ISO8601DateFormatter().string(from: Date())
        settings.setupLastSummary = summary
    }

    private func makeSteps(_ env: SetupEnvironment) -> [SetupStep] {
        [
            .init(id: "toolchains", title: "Scan compiler libraries",
                  detail: "\(env.toolchains.filter(\.present).count) of \(env.toolchains.count) declared components discovered in the IPA.",
                  kind: .scan),
            .init(id: "linux", title: "Verify ios-linuxkit",
                  detail: env.rootfsPresent ? "Embedded runtime and rootfs detected." : "Runtime/rootfs incomplete.",
                  kind: .verify),
            .init(id: "sdk", title: "Scan bundled SDKs",
                  detail: "\(env.sdkCount) SDK payload(s) discovered.",
                  kind: .scan),
            .init(id: "project", title: "Detect active project",
                  detail: "Generate project-specific compiler/package configuration from the workspace.",
                  kind: .configure)
        ]
    }
}
