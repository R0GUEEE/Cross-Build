import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceBrowserView: View {
    @ObservedObject var files: FileManagerService
    @State private var showImporter = false
    @State private var newItemName = ""
    @State private var showNewFile = false
    @State private var showNewFolder = false

    var body: some View {
        List {
            Section {
                TextField("Search files", text: $files.query)
                if !files.query.isEmpty {
                    ForEach(files.searchResults) { row($0) }
                }
            }
            if files.query.isEmpty {
                Section("Project") {
                    OutlineGroup(files.roots, children: \.children) { file in row(file) }
                }
                let favorites = files.flattened.filter(\.isFavorite)
                if !favorites.isEmpty {
                    Section("Favorites") { ForEach(favorites) { row($0) } }
                }
                if !files.recent.isEmpty {
                    Section("Recent") { ForEach(files.recent.prefix(5)) { row($0) } }
                }
            }
        }
        .navigationTitle("Files")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New File", systemImage: "doc.badge.plus") { showNewFile = true }
                    Button("New Folder", systemImage: "folder.badge.plus") { showNewFolder = true }
                    Button("Import Files", systemImage: "square.and.arrow.down") { showImporter = true }
                } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Text("\(files.flattened.filter { !$0.isDirectory }.count) files").font(.caption).foregroundStyle(.secondary)
            }.padding().background(.thinMaterial)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { files.createFile(named: url.lastPathComponent) }
            }
        }
        .alert("New File", isPresented: $showNewFile) { itemAlert(folder: false) }
        .alert("New Folder", isPresented: $showNewFolder) { itemAlert(folder: true) }
    }

    @ViewBuilder private func row(_ file: WorkspaceFile) -> some View {
        Button { files.open(file) } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(file.name)
                    if !file.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: file.isDirectory ? "folder.fill" : icon(for: file.name))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(file.isFavorite ? "Remove Favorite" : "Favorite", systemImage: "star") { files.toggleFavorite(file) }
            Button("Duplicate", systemImage: "plus.square.on.square") { files.duplicate(file) }
            Button("Delete", systemImage: "trash", role: .destructive) { files.delete(file) }
        }
    }

    private func itemAlert(folder: Bool) -> some View {
        TextField(folder ? "Folder name" : "File name", text: $newItemName)
        Button("Create") {
            if folder { files.createFolder(named: newItemName) } else { files.createFile(named: newItemName) }
            newItemName = ""
        }
        Button("Cancel", role: .cancel) { newItemName = "" }
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["swift","m","mm","c","cpp","cc","rs","go","zig","py","js","ts","xm","x"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["png","jpg","jpeg","heic","svg"].contains(ext) { return "photo" }
        if ["zip","tar","gz","xz","deb","ipa"].contains(ext) { return "shippingbox" }
        return "doc.text"
    }
}
