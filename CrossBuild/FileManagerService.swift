import Foundation
import SwiftUI

struct WorkspaceFile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var isFavorite: Bool
    var children: [WorkspaceFile]?

    init(id: UUID = UUID(), name: String, path: String, isDirectory: Bool = false,
         size: Int64 = 0, modified: Date = .now, isFavorite: Bool = false,
         children: [WorkspaceFile]? = nil) {
        self.id = id; self.name = name; self.path = path; self.isDirectory = isDirectory
        self.size = size; self.modified = modified; self.isFavorite = isFavorite; self.children = children
    }
}

@MainActor
final class FileManagerService: ObservableObject {
    @Published var roots: [WorkspaceFile] = [
        .init(name: "CrossBuild", path: "/CrossBuild", isDirectory: true, children: [
            .init(name: "Sources", path: "/CrossBuild/Sources", isDirectory: true, children: [
                .init(name: "main.swift", path: "/CrossBuild/Sources/main.swift", size: 128)
            ]),
            .init(name: "Makefile", path: "/CrossBuild/Makefile", size: 256),
            .init(name: "control", path: "/CrossBuild/control", size: 180)
        ])
    ]
    @Published var selected: WorkspaceFile?
    @Published var recent: [WorkspaceFile] = []
    @Published var query = ""

    var flattened: [WorkspaceFile] {
        func walk(_ files: [WorkspaceFile]) -> [WorkspaceFile] {
            files.flatMap { [$0] + walk($0.children ?? []) }
        }
        return walk(roots)
    }

    var searchResults: [WorkspaceFile] {
        guard !query.isEmpty else { return [] }
        return flattened.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    func open(_ file: WorkspaceFile) {
        selected = file
        guard !file.isDirectory else { return }
        recent.removeAll { $0.id == file.id }
        recent.insert(file, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }

    func createFile(named name: String, in parentPath: String = "/CrossBuild") {
        insert(.init(name: name, path: parentPath + "/" + name), parentPath: parentPath)
    }

    func createFolder(named name: String, in parentPath: String = "/CrossBuild") {
        insert(.init(name: name, path: parentPath + "/" + name, isDirectory: true, children: []), parentPath: parentPath)
    }

    func duplicate(_ file: WorkspaceFile) {
        let ext = (file.name as NSString).pathExtension
        let base = (file.name as NSString).deletingPathExtension
        let copyName = base + " copy" + (ext.isEmpty ? "" : "." + ext)
        var copy = file
        copy = .init(name: copyName, path: (file.path as NSString).deletingLastPathComponent + "/" + copyName,
                     isDirectory: file.isDirectory, size: file.size, children: file.children)
        insert(copy, parentPath: (file.path as NSString).deletingLastPathComponent)
    }

    func delete(_ file: WorkspaceFile) { mutateTree { $0.removeAll { $0.id == file.id } } }

    func toggleFavorite(_ file: WorkspaceFile) {
        mutateTree { files in
            for i in files.indices where files[i].id == file.id { files[i].isFavorite.toggle() }
        }
    }

    func rename(_ file: WorkspaceFile, to newName: String) {
        mutateTree { files in
            for i in files.indices where files[i].id == file.id {
                files[i].name = newName
                files[i].path = (files[i].path as NSString).deletingLastPathComponent + "/" + newName
            }
        }
    }

    private func insert(_ file: WorkspaceFile, parentPath: String) {
        func add(_ nodes: inout [WorkspaceFile]) -> Bool {
            for i in nodes.indices {
                if nodes[i].path == parentPath {
                    nodes[i].children = (nodes[i].children ?? []) + [file]; return true
                }
                if nodes[i].children != nil, add(&nodes[i].children!) { return true }
            }
            return false
        }
        if !add(&roots) { roots.append(file) }
    }

    private func mutateTree(_ body: (inout [WorkspaceFile]) -> Void) {
        func recurse(_ nodes: inout [WorkspaceFile]) {
            body(&nodes)
            for i in nodes.indices where nodes[i].children != nil { recurse(&nodes[i].children!) }
        }
        recurse(&roots)
    }
}
