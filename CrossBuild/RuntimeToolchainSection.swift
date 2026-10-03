import SwiftUI

/// Probes the Linux guest for the toolchain executables it can actually run, and
/// installs the missing ones straight from apk.
///
/// `ToolchainRuntimeManager` was fully implemented but had no caller anywhere, so
/// none of this was reachable from the UI -- the refresh and install paths were
/// dead code. This is the view that uses it.
struct RuntimeToolchainSection: View {
    @ObservedObject var runtime: ToolchainRuntimeManager
    @State private var installingID: String?
    @State private var message: String?

    var body: some View {
        Section {
            if runtime.probes.isEmpty {
                Text(runtime.isRefreshing ? "Checking the guest…" : "Not checked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(runtime.probes) { probe in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: probe.readiness)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(probe.name).font(.subheadline.weight(.medium))
                        Text(probe.version.isEmpty ? probe.detail : "\(probe.version) — \(probe.detail)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch probe.readiness {
                    case .availableToInstall:
                        Button("Install") { install(probe) }
                            .buttonStyle(.borderless)
                            .disabled(installingID != nil || runtime.isRefreshing)
                    case .functional:
                        Text("Ready").font(.caption).foregroundStyle(.green)
                    default:
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            Button {
                Task { await runtime.refresh() }
            } label: {
                if runtime.isRefreshing {
                    ProgressView()
                } else {
                    Label("Check guest toolchains", systemImage: "arrow.clockwise")
                }
            }
            .disabled(runtime.isRefreshing || installingID != nil)

            if let message {
                Text(message).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
        } header: {
            Text("Linux guest toolchains")
        } footer: {
            Text("Install runs apk inside the guest. Requires the Linux Guest execution backend and a bundled rootfs — the check itself boots the guest.")
                .font(.caption)
        }
    }

    private func install(_ probe: ToolchainProbe) {
        installingID = probe.id
        message = "Installing \(probe.name) with apk…"
        Task {
            let (ok, output) = await runtime.install(probe.id)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = trimmed.isEmpty ? (ok ? "Installed \(probe.name)." : "Install failed.") : trimmed
            installingID = nil
        }
    }

    private func icon(for readiness: ToolchainReadiness) -> String {
        switch readiness {
        case .functional: return "checkmark.circle.fill"
        case .installed, .configured: return "circle.dashed"
        case .availableToInstall: return "arrow.down.circle"
        case .unavailable: return "xmark.circle"
        }
    }
}
