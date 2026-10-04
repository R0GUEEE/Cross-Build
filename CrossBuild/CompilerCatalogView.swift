import SwiftUI

struct CompilerCatalogView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category: CompilerCategory?
    @State private var selected: CompilerCatalogItem?

    private var filtered: [CompilerCatalogItem] {
        CompilerCatalog.items.filter { item in
            (category == nil || item.category == category) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) ||
             item.languages.joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chip("All", active: category == nil) { category = nil }
                            ForEach(CompilerCategory.allCases) { c in chip(c.rawValue, active: category == c) { category = c } }
                        }.padding(.vertical, 3)
                    }
                }
                ForEach(filtered) { item in
                    Button { selected = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon).font(.title2).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(item.category.rawValue)
                                    Text("•")
                                    Text(workspace.embeddedToolchains.isAvailable(item.id) ? "Embedded • Ready" : (AppToolchainLibraries.item(item.id)?.availability.rawValue ?? "Integrated"))
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search compilers and languages")
            .navigationTitle("Toolchain Catalogue")
            .sheet(item: $selected) { CompilerCatalogDetailView(item: $0).environmentObject(workspace) }
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
            .fontWeight(active ? .bold : .regular)
    }
}

struct CompilerCatalogDetailView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let item: CompilerCatalogItem

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon).font(.system(size: 38)).frame(width: 52)
                        VStack(alignment: .leading) {
                            Text(item.name).font(.title2.bold())
                            Text(item.subtitle).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section("Capabilities") {
                    LabeledContent("Category", value: item.category.rawValue)
                    LabeledContent("Executable", value: item.executable)
                    LabeledContent("App Library", value: workspace.embeddedToolchains.isAvailable(item.id) ? "Embedded Engine • Ready" : (AppToolchainLibraries.item(item.id)?.availability.rawValue ?? "Integrated"))
                    LabeledContent("Module", value: AppToolchainLibraries.item(item.id)?.module ?? item.id)
                    LabeledContent("Version", value: AppToolchainLibraries.item(item.id)?.version ?? "built-in")
                    let scan = AppToolchainLibraries.scanBundle().first { $0.id == item.id }
                    LabeledContent("In-app payload", value: scan?.present == true ? "Ready" : "Missing")
                    if let detail = scan?.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if !item.languages.isEmpty { LabeledContent("Languages", value: item.languages.joined(separator: ", ")) }
                }
                Section("Project Detection") {
                    Text(item.markers.joined(separator: " • ")).font(.system(.caption, design: .monospaced))
                }
                Section("Commands") {
                    command("Build", item.buildCommand)
                    command("Clean", item.cleanCommand)
                    command("Test", item.testCommand)
                    command("Package", item.packageCommand)
                }
                if !item.packageNames.isEmpty {
                    Section("Packages / Dependencies") { Text(item.packageNames.joined(separator: " • ")) }
                }
                Section("Compatibility") { Text(item.notes).font(.callout) }
                if workspace.embeddedToolchains.isAvailable(item.id) {
                    Section("Embedded Engine") {
                        Label("Linked and available in this app build", systemImage: "checkmark.seal.fill")
                        Button("Run Embedded Engine", systemImage: "play.fill") { workspace.runEmbedded(id: item.id) }
                    }
                }
                Section {
                    Button("Use Built-in Toolchain", systemImage: "checkmark.circle") {
                        workspace.selectedToolchain = toolchain(for: item.id)
                        workspace.selectedCustomCompilerID = nil
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }
            }.navigationTitle("Toolchain")
        }
    }

    private func toolchain(for id: String) -> ToolchainKind {
        switch id {
        case "clang": return .clang
        case "swift": return .swift
        case "theos", "dpkg", "ldid": return .theos
        case "rust": return .rust
        case "go": return .go
        case "zig": return .zig
        case "python": return .python
        case "node", "typescript": return .javascript
        default: return .custom
        }
    }

    private func command(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption.bold()).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}
