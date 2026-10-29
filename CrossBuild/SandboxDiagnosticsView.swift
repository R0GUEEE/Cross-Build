import SwiftUI
import UIKit

/// Why the things the app says it ships are — or are not — reachable at runtime.
///
/// "Libraries and SDKs are not importing" has several unrelated causes: a Python
/// stdlib that is present but unusable, an SDK that was dropped in the wrong folder,
/// a guest whose root filesystem never finished copying, or simply no free space.
/// This screen checks each one and prints the answer, with the path involved, instead
/// of leaving it to be inferred from a feature that quietly does not work.
struct SandboxDiagnosticsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    @State private var report: [DiagnosticSection] = []
    @State private var isRunning = true
    @State private var showResetConfirm = false

    struct DiagnosticSection: Identifiable, Sendable {
        let id: String
        let title: String
        var rows: [Row]
    }

    struct Row: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let value: String
        let ok: Bool?
        var hint: String? = nil
    }

    var body: some View {
        List {
            ForEach(report) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label)
                                Spacer(minLength: 8)
                                if let ok = row.ok {
                                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(ok ? .green : .red)
                                        .font(.caption)
                                }
                                Text(row.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                            if let hint = row.hint {
                                Text(hint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            Section("Actions") {
                Button("Re-check", systemImage: "arrow.clockwise") { Task { await run() } }
                Button("Reset the Linux guest", systemImage: "trash", role: .destructive) {
                    showResetConfirm = true
                }
                Text("The guest's root filesystem is copied out of the app bundle once. Resetting removes that copy so the next launch re-extracts it — the app has to be reopened because the interpreter cannot be restarted in-process.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sandbox Diagnostics")
        .task { await run() }
        .confirmationDialog("Reset the Linux guest root?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Delete and re-extract on next launch", role: .destructive) { resetGuest() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anything you built inside the guest is discarded.")
        }
    }

    // MARK: - Checks

    private func run() async {
        isRunning = true
        let info = await Task.detached(priority: .userInitiated) { Self.collectPythonAndSDKs() }.value
        var sections: [DiagnosticSection] = []

        // Bundle
        let bundle = Bundle.main
        let executable = bundle.executableURL
        let toolchains = bundle.resourceURL?.appendingPathComponent("Toolchains")
        let manifestCount = ((try? FileManager.default.contentsOfDirectory(atPath: toolchains?.path ?? "")) ?? []).count
        sections.append(.init(id: "bundle", title: "App bundle", rows: [
            .init(label: "Version",
                  value: (bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    + " (" + (bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")",
                  ok: nil),
            .init(label: "Executable", value: executable?.lastPathComponent ?? "missing", ok: executable != nil),
            .init(label: "Toolchain manifests", value: "\(manifestCount)", ok: manifestCount > 0)
        ]))

        // Python
        sections.append(.init(id: "python", title: "Embedded Python", rows: info.python))

        // SDKs
        sections.append(.init(id: "sdk", title: "Apple SDKs", rows: info.sdks))

        // Guest
        sections.append(.init(id: "guest", title: "Linux guest", rows: guestRows()))

        // Boot log
        let tail = LinuxGuestEngine.bootLogTail()
        if !tail.isEmpty {
            sections.append(.init(id: "bootlog", title: "Guest boot log", rows: tail.map {
                .init(label: "", value: $0, ok: nil)
            }))
        }

        // Toolchains the guest reported
        let tools = workspace.guestToolchain.sorted()
        sections.append(.init(id: "tools", title: "Guest toolchains", rows: [
            .init(label: "Reported by the guest",
                  value: tools.isEmpty ? "none" : "\(tools.count) tools",
                  ok: !tools.isEmpty,
                  hint: tools.isEmpty ? nil : tools.joined(separator: ", "))
        ]))

        report = sections
        isRunning = false
    }

    private func guestRows() -> [Row] {
        var rows: [Row] = []
        rows.append(.init(label: "Engine", value: LinuxGuestEngine.version, ok: LinuxGuestEngine.isLinked))
        rows.append(.init(label: "Execution", value: LinuxGuestEngine.buildConfiguration,
                          ok: true, hint: LinuxGuestEngine.buildConfiguration))
        rows.append(.init(label: "Root filesystem in bundle", value: LinuxGuestEngine.isRootBundled ? "present" : "missing",
                          ok: LinuxGuestEngine.isRootBundled))

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let root = documents?.appendingPathComponent("CrossBuild/linux-root", isDirectory: true)
        let marker = documents?.appendingPathComponent("CrossBuild/linux-root.build")
        let exists = root.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        rows.append(.init(label: "Writable root", value: exists ? (root?.lastPathComponent ?? "") : "not extracted yet",
                          ok: exists, hint: root?.path))
        if let marker, let stamp = try? String(contentsOf: marker, encoding: .utf8) {
            rows.append(.init(label: "Root build stamp", value: stamp, ok: true))
        } else {
            rows.append(.init(label: "Root build stamp", value: "none", ok: false,
                              hint: "Written after a complete extraction; a missing stamp means the next launch re-extracts."))
        }

        if let documents,
           let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            rows.append(.init(label: "Free space",
                              value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file), ok: nil))
        }

        switch LinuxGuestSession.shared.state {
        case .running:
            rows.append(.init(label: "Session", value: "running", ok: true))
        case .starting:
            rows.append(.init(label: "Session", value: "starting", ok: nil))
        case .idle:
            rows.append(.init(label: "Session", value: "not started", ok: nil))
        case .unavailable(let reason):
            rows.append(.init(label: "Session", value: "unavailable", ok: false, hint: reason))
        case .failed(let reason):
            rows.append(.init(label: "Session", value: "failed", ok: false, hint: reason))
        }
        if let error = workspace.guestToolchainError {
            rows.append(.init(label: "Last guest error", value: "reported", ok: false, hint: error))
        }
        return rows
    }

    /// Everything that needs file-system access, off the main actor.
    private static func collectPythonAndSDKs() -> (python: [Row], sdks: [Row]) {
        var python: [Row] = []
        let resources = Bundle.main.resourceURL
        let framework = Bundle.main.bundleURL.appendingPathComponent("Frameworks/Python.framework/Python")
        python.append(.init(label: "Python.framework", value: framework.lastPathComponent,
                            ok: FileManager.default.fileExists(atPath: framework.path),
                            hint: framework.deletingLastPathComponent().path))

        let home = resources?.appendingPathComponent("python")
        let stdlib = home?.appendingPathComponent("lib/python3.13")
        python.append(.init(label: "PYTHONHOME", value: home?.lastPathComponent ?? "missing",
                            ok: home.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                            hint: home?.path))
        let osPy = stdlib?.appendingPathComponent("os.py")
        python.append(.init(label: "os.py", value: osPy?.lastPathComponent ?? "missing",
                            ok: osPy.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                            hint: stdlib?.path))
        let encodings = stdlib?.appendingPathComponent("encodings/__init__.py")
        python.append(.init(label: "encodings", value: "package",
                            ok: encodings.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                            hint: "CPython cannot initialise without it"))
        let dynload = stdlib?.appendingPathComponent("lib-dynload")
        let extensions = ((try? FileManager.default.contentsOfDirectory(atPath: dynload?.path ?? "")) ?? [])
            .filter { $0.hasSuffix(".so") }
        python.append(.init(label: "C extensions", value: "\(extensions.count)", ok: extensions.contains { $0.hasPrefix("_sqlite3") },
                            hint: extensions.isEmpty ? "import sqlite3/ssl will fail" : nil))

        // Actually ask the interpreter. This is the only check that proves the
        // layout works rather than that the files exist.
        #if canImport(CrossBuildPython)
        if let failure = PythonEmbeddedEngine.ensureStarted() {
            python.append(.init(label: "Interpreter", value: "failed to start", ok: false, hint: failure))
        } else {
            python.append(.init(label: "Interpreter", value: PythonEmbeddedEngine().version, ok: true))
        }
        #else
        python.append(.init(label: "Interpreter", value: "not linked", ok: false))
        #endif

        var sdks: [Row] = []
        let roots = IOSSDKDiscovery.searchRoots()
        for root in roots {
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasSuffix(".sdk") }
            sdks.append(.init(label: root.lastPathComponent,
                              value: found.isEmpty ? "no .sdk" : "\(found.count)",
                              ok: found.isEmpty ? nil : true,
                              hint: root.path))
        }
        if let preferred = IOSSDKDiscovery.preferred() {
            sdks.append(.init(label: "In use", value: preferred.lastPathComponent, ok: true, hint: preferred.path))
        } else {
            sdks.append(.init(label: "In use", value: "none", ok: false,
                              hint: "Drop an .sdk folder into Documents/SDKs."))
        }
        return (python, sdks)
    }

    private func resetGuest() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let base = documents?.appendingPathComponent("CrossBuild", isDirectory: true)
        for name in ["linux-root", "linux-root.build"] {
            if let url = base?.appendingPathComponent(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        Task { await run() }
    }
}
