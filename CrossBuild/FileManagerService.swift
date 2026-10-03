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
    init(id: UUID = UUID(), name: String, path: String, isDirectory: Bool = false, size: Int64 = 0,
         modified: Date = .now, isFavorite: Bool = false, children: [WorkspaceFile]? = nil) {
        self.id=id; self.name=name; self.path=path; self.isDirectory=isDirectory; self.size=size
        self.modified=modified; self.isFavorite=isFavorite; self.children=children
    }
}

@MainActor
final class FileManagerService: ObservableObject {
    @Published var roots: [WorkspaceFile] = []
    @Published var selected: WorkspaceFile?
    @Published var recent: [WorkspaceFile] = []
    @Published var query = ""
    @Published var errorMessage: String?
    let workspaceRoot: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        workspaceRoot = docs.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        reload()
    }

    var flattened: [WorkspaceFile] {
        func walk(_ f:[WorkspaceFile])->[WorkspaceFile] { f.flatMap { [$0] + walk($0.children ?? []) } }
        return walk(roots)
    }
    var searchResults:[WorkspaceFile] {
        guard !query.isEmpty else { return [] }
        return flattened.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    func reload(from root: URL? = nil) {
        let base = root ?? workspaceRoot
        roots = [node(for: base)]
    }

    func open(_ file: WorkspaceFile) { selected=file; guard !file.isDirectory else { return }; recent.removeAll{$0.path==file.path}; recent.insert(file,at:0); if recent.count>20{recent=Array(recent.prefix(20))} }
    func contents(of file: WorkspaceFile) -> String? { guard !file.isDirectory else { return nil }; return try? String(contentsOfFile:file.path,encoding:.utf8) }
    func save(_ text:String, to file:WorkspaceFile) throws { guard !file.isDirectory else{return}; try text.write(toFile:file.path,atomically:true,encoding:.utf8); reload() }

    func createFile(named name:String, in parentPath:String?=nil) {
        guard valid(name) else { errorMessage="Invalid file name."; return }
        let parent=URL(fileURLWithPath:parentPath ?? workspaceRoot.path)
        let url=parent.appendingPathComponent(name)
        if !FileManager.default.createFile(atPath:url.path,contents:Data()) { errorMessage="Could not create \(name)." }
        reload()
    }
    func createFolder(named name:String, in parentPath:String?=nil) {
        guard valid(name) else { errorMessage="Invalid folder name."; return }
        do { try FileManager.default.createDirectory(at:URL(fileURLWithPath:parentPath ?? workspaceRoot.path).appendingPathComponent(name),withIntermediateDirectories:false); reload() }
        catch { errorMessage=error.localizedDescription }
    }
    func importFiles(_ urls:[URL], into parentPath:String?=nil) {
        let parent=URL(fileURLWithPath:parentPath ?? workspaceRoot.path)
        for source in urls {
            let access=source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let dest=uniqueURL(parent.appendingPathComponent(source.lastPathComponent))
                try FileManager.default.copyItem(at:source,to:dest)
            } catch { errorMessage=error.localizedDescription }
        }
        reload()
    }
    func duplicate(_ file:WorkspaceFile) {
        let src=URL(fileURLWithPath:file.path); let ext=src.pathExtension
        let base=src.deletingPathExtension().lastPathComponent+" copy"+(ext.isEmpty ? "" : "."+ext)
        do { try FileManager.default.copyItem(at:src,to:uniqueURL(src.deletingLastPathComponent().appendingPathComponent(base))); reload() }
        catch { errorMessage=error.localizedDescription }
    }
    func delete(_ file:WorkspaceFile) { do { try FileManager.default.removeItem(atPath:file.path); if selected?.path==file.path{selected=nil}; reload() } catch { errorMessage=error.localizedDescription } }
    func rename(_ file:WorkspaceFile,to newName:String) { guard valid(newName) else{return}; do { let src=URL(fileURLWithPath:file.path); try FileManager.default.moveItem(at:src,to:src.deletingLastPathComponent().appendingPathComponent(newName)); reload() } catch { errorMessage=error.localizedDescription } }
    func toggleFavorite(_ file:WorkspaceFile) { /* favorites are session metadata until project metadata persistence lands */ }

    private func node(for url:URL)->WorkspaceFile {
        var isDir:ObjCBool=false; FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir)
        let attrs=try? FileManager.default.attributesOfItem(atPath:url.path)
        var children:[WorkspaceFile]?=nil
        if isDir.boolValue {
            let urls=(try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []
            children=urls.sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}.map(node)
        }
        return .init(name:url.lastPathComponent,path:url.path,isDirectory:isDir.boolValue,size:(attrs?[.size] as? NSNumber)?.int64Value ?? 0,modified:(attrs?[.modificationDate] as? Date) ?? .now,children:children)
    }
    private func valid(_ name:String)->Bool { !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !name.contains("/") }
    private func uniqueURL(_ url:URL)->URL { var u=url; var n=2; while FileManager.default.fileExists(atPath:u.path){ let ext=url.pathExtension; let stem=url.deletingPathExtension().lastPathComponent; u=url.deletingLastPathComponent().appendingPathComponent("\(stem) \(n)"+(ext.isEmpty ? "" : "."+ext)); n+=1 }; return u }
}
