import SwiftUI

/// Reports what actually ships inside this app build, by inspecting the bundle at
/// runtime, and states plainly what cannot be bundled and why.
struct BundledResourcesView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    @State private var exportedHelper: URL?
    @State private var exportError: String?
    @State private var items: [BundledResource] = []

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.present ? item.icon : "xmark.circle")
                            .frame(width: 22)
                            .foregroundStyle(item.present ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(item.location)
                                if item.sizeBytes > 0 {
                                    Text("•")
                                    Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                                }
                                Text("•")
                                Text(item.execution.rawValue)
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(item.present ? "Included" : "Missing")
                            .font(.caption)
                            .foregroundStyle(item.present ? .green : .red)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Included in this build")
            } footer: {
                Text("Read from the app bundle at launch, so this reflects the build you are running rather than a fixed list.")
                    .font(.caption)
            }

            Section {
                Button {
                    exportHelper()
                } label: {
                    Label("Export helper to Documents", systemImage: "square.and.arrow.down")
                }
                if let exportedHelper {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Written to \(exportedHelper.path)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(BundledResources.runCommand(for: exportedHelper))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Run the bundled helper")
            } footer: {
                Text("The helper does the process execution Cross Build cannot do itself. Export it, then run the printed command on the host — or from a terminal app on a jailbroken device — and point Settings → App Configuration at it.")
                    .font(.caption)
            }

            Section {
                ForEach(BundledResources.unavailable, id: \.name) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.subheadline.weight(.medium))
                        Text(entry.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Cannot be bundled")
            } footer: {
                Text("Listed so the app never implies it ships something it cannot. These run on a build host or jailbroken device through the helper.")
                    .font(.caption)
            }
        }
        .navigationTitle("Bundled with the app")
        .onAppear { items = BundledResources.inventory() }
    }

    private func exportHelper() {
        exportError = nil
        do {
            exportedHelper = try BundledResources.exportHelper()
        } catch {
            exportError = error.localizedDescription
        }
    }
}
