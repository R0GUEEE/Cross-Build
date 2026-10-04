import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WorkspaceBrowserView: View {
    @ObservedObject var files: FileManagerService
    var onDelete: ((WorkspaceFile) -> Void)? = nil
    /// Routed through the workspace rather than straight to `files.rename` so the
    /// rename can also fix up any open editor tab pointing at the old path.
    var onRename: ((WorkspaceFile, String) -> Void)? = nil
    /// Mirrors "Confirm destructive actions". When it is off, Delete acts
    /// immediately instead of asking.
    var confirmDeletes: Bool = true
    @State private var showImporter = false
    @State private var newItemName = ""
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var pendingDelete: WorkspaceFile?
    @State private var pendingRename: WorkspaceFile?
    @State private var renameName = ""

    var body: some View {
        List {
            Section {
                TextField("Search files", text: $files.query)
                    // Content search runs off the main actor and is debounced;
                    // without this the field would only ever match file names.
                    .onChange(of: files.query) { _ in files.scheduleContentSearch() }
                if !files.query.isEmpty {
                    ForEach(files.searchResults) { row($0) }
                }
            }
            if files.query.isEmpty {
                if files.roots.isEmpty {
                    Section {
                        if files.isLoadingTree {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Building the file tree…").foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No files yet").font(.headline)
                                Text("Add a file with the button below, import from another app, or drop source into this folder from Files.app.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if let projectRoot = files.roots.first {
                    Section("Project") {
                        OutlineGroup([projectRoot], children: \.children) { file in row(file) }
                    }
                }
                if files.roots.count > 1 {
                    Section("App Files") {
                        DisclosureGroup("Container & Bundle") {
                            ForEach(Array(files.roots.dropFirst())) { root in
                                OutlineGroup([root], children: \.children) { file in row(file) }
                            }
                        }
                    }
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
                    Divider()
                    Button("Show All App Directories", systemImage: "square.stack.3d.up") { files.revealAllAppDirectories() }
                    Button("Workspace Only", systemImage: "folder") { files.revealWorkspaceOnly() }
                    Button("Refresh", systemImage: "arrow.clockwise") { files.reload() }
                } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Text("\(files.flattened.filter { !$0.isDirectory && ($0.path == files.workspaceRoot.path || $0.path.hasPrefix(files.workspaceRoot.path + "/")) }.count) project files").font(.caption).foregroundStyle(.secondary)
            }.padding().background(.thinMaterial)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                files.importFiles(urls)
            }
        }
        .alert("New File", isPresented: $showNewFile) {
            TextField("File name", text: $newItemName)
            Button("Create") {
                files.createFile(named: newItemName)
                newItemName = ""
            }
            Button("Cancel", role: .cancel) { newItemName = "" }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newItemName)
            Button("Create") {
                files.createFolder(named: newItemName)
                newItemName = ""
            }
            Button("Cancel", role: .cancel) { newItemName = "" }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "item")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { performDelete(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the item from the app container. Any open tabs for it will be closed.")
        }
        .alert("File Operation Failed", isPresented: Binding(
            get: { files.errorMessage != nil },
            set: { if !$0 { files.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { files.errorMessage = nil }
        } message: {
            Text(files.errorMessage ?? "Unknown file error.")
        }
        .alert("Rename \(pendingRename?.name ?? "item")", isPresented: Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )) {
            TextField("New name", text: $renameName)
            Button("Rename") {
                if let file = pendingRename {
                    if let onRename { onRename(file, renameName) } else { files.rename(file, to: renameName) }
                }
                pendingRename = nil
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        }
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
                Image(systemName: file.isDirectory ? "folder.fill" : WorkspaceFileIcon.symbol(for: file.name))
                    .foregroundStyle(file.isDirectory ? Color.accentColor : WorkspaceFileIcon.tint(for: file.name))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            Button(file.isFavorite ? "Remove Favorite" : "Add Favorite",
                   systemImage: file.isFavorite ? "star.slash" : "star") { files.toggleFavorite(file) }
            if !files.isReadOnly(file) {
                Button("Rename", systemImage: "pencil") {
                    renameName = file.name
                    pendingRename = file
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { files.duplicate(file) }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if confirmDeletes { pendingDelete = file } else { performDelete(file) }
                }
            } else {
                Label("Read-only App Bundle", systemImage: "lock.fill")
            }
        }
    }

    private func performDelete(_ file: WorkspaceFile) {
        if let onDelete { onDelete(file) } else { files.delete(file) }
    }


    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["swift","m","mm","c","cpp","cc","rs","go","zig","py","js","ts","xm","x"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["png","jpg","jpeg","heic","svg"].contains(ext) { return "photo" }
        if ["zip","tar","gz","xz","deb","ipa"].contains(ext) { return "shippingbox" }
        return "doc.text"
    }
}
