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
    /// Absent by design rather than broken. A catalogue entry with no in-app
    /// payload, or the SDK count on a build that ships no SDK, is the normal
    /// state of a sideloaded install and must not be reported as a fault.
    case notBundled = "Not Bundled"
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
    /// Build tools found in the Linux guest. The guest is where compilation
    /// actually happens, so what it carries is part of the answer to "is this
    /// install working" -- without it the screen could report a ready rootfs and
    /// a toolchain the guest does not have.
    var guestTools: [String] = []
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

    /// Steps that have finished, one way or another -- what the setup progress
    /// bar counts.
    var completedStepCount: Int {
        steps.filter { $0.status == .succeeded || $0.status == .failed || $0.status == .skipped }.count
    }

    var presentTools: [AppToolchainScan] { environment.toolchains.filter(\.present) }
    var missingTools: [AppToolchainScan] { environment.toolchains.filter { !$0.present } }

    func prepare(workspace: WorkspaceModel, settings: AppSettings) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var env = SetupEnvironment()
        env.rootfsPresent = LinuxGuestEngine.isLinked && LinuxGuestEngine.isRootBundled
        env.sdkCount = IOSSDKDiscovery.availableSDKs().count
        // Ask the guest, but do NOT wait for the answer.
        //
        // Awaiting it made the entire scan depend on the guest being bootable. The
        // session serialises on a boot that may copy the rootfs, so a slow or
        // absent guest held the whole screen at "0 of 0 checks / Scanning…" --
        // no list, no steps, and nothing to say what was wrong. A scan of the
        // installed app has to be able to finish without the guest's help; the
        // guest's own row simply fills in when it answers.
        probeGuestInBackground()
        env.toolchains = AppToolchainLibraries.scanBundle()

        // Only a missing rootfs is a real fault. The other two conditions used to
        // land in "Issues Found" on every healthy install:
        //   - a catalogue component with no in-app payload is not missing from the
        //     IPA, it was never shipped in it -- the components that need a full
        //     toolchain run through the embedded runtime instead;
        //   - the Apple SDK is not redistributable, so a bundled-SDK count of zero
        //     is the normal value, not a problem to be fixed.
        if !env.rootfsPresent {
            env.notes.append("Embedded ios-linuxkit rootfs is missing; the in-app runtime cannot start.")
        }
        let missing = env.toolchains.filter { !$0.present }

        environment = env
        steps = makeSteps(env)
        didPrepare = true
        statusLine = env.rootfsPresent
            ? "In-app runtime scan complete. \(env.toolchains.count - missing.count) of \(env.toolchains.count) catalogue components ship as in-app libraries."
            : "The embedded runtime is unavailable."
    }

    /// Probes the guest off the scan's critical path.
    private func probeGuestInBackground() {
        Task { [weak self] in
            let probe = "for t in make cc gcc c++ g++ ; do command -v \"$t\" >/dev/null 2>&1 && printf '%s ' \"$t\"; done"
            let probed = await LinuxGuestSession.shared.run(probe, timeout: 15)
            guard let self, probed.code >= 0 else { return }
            let tools = probed.output
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map(String.init)
                .sorted()
            self.environment.guestTools = tools
            AppToolchainLibraries.guestTools = tools
            self.refreshGuestToolchainStep()
        }
    }

    /// Reflects a late guest answer in the toolchain step, when the scan has
    /// already produced one.
    private func refreshGuestToolchainStep() {
        guard let index = steps.firstIndex(where: { $0.id == "toolchain" }) else { return }
        let required = ToolchainRuntimeArchitecture.requiredGuestTools
        let missing = required.filter { !environment.guestTools.contains($0) }
        steps[index].output = missing.isEmpty
            ? "Present: \(environment.guestTools.joined(separator: ", "))"
            : "Missing: \(missing.joined(separator: ", "))\nPresent: \(environment.guestTools.joined(separator: ", "))"
        steps[index].status = missing.isEmpty ? .succeeded : .failed
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
                    .map { "\($0.present ? "READY" : "NOT BUNDLED")  \($0.name)  \($0.location)\n\($0.detail)" }
                    .joined(separator: "\n\n")
                // This is a scan, and the scan itself always succeeds. A component
                // without an in-app payload is a catalogue entry, not an
                // installation fault, so it no longer marks the step failed. Only
                // a build that ships no usable component at all is a failure.
                let presentCount = environment.toolchains.count - missing.count
                steps[index].status = presentCount > 0 ? .succeeded : .failed
                if presentCount < environment.toolchains.count {
                    steps[index].output += "\n\n\(environment.toolchains.count - presentCount) catalogue component(s) have no in-app library in this build. That is expected: a component is only READY when an in-app engine or library actually ships, and the toolchains that need a full compiler run through the embedded runtime instead."
                }
            case "linux":
                steps[index].output = environment.rootfsPresent
                    ? "ios-linuxkit engine and fakefs-root are bundled."
                    : "ios-linuxkit engine/rootfs is incomplete."
                steps[index].status = environment.rootfsPresent ? .succeeded : .failed
            case "toolchain":
                let required = ToolchainRuntimeArchitecture.requiredGuestTools
                let missing = required.filter { !environment.guestTools.contains($0) }
                steps[index].output = missing.isEmpty
                    ? "Present: \(environment.guestTools.joined(separator: ", "))"
                    : "Missing: \(missing.joined(separator: ", "))\nPresent: \(environment.guestTools.joined(separator: ", "))"
                steps[index].status = missing.isEmpty ? .succeeded : .failed
            case "sdk":
                steps[index].output = environment.sdkCount > 0
                    ? "\(environment.sdkCount) bundled SDK(s) discovered."
                    : "No SDK payload is bundled with this build. The Apple SDK is not redistributable, so this is the normal state for a sideloaded install, not a fault; point a project at an SDK of your own when one is needed."
                steps[index].status = environment.sdkCount > 0 ? .succeeded : .notBundled
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
            .init(id: "toolchain", title: "Guest build toolchain",
                  detail: env.guestTools.isEmpty
                      ? "No build tools were found in the Linux guest."
                      : "Found: \(env.guestTools.joined(separator: ", "))",
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
