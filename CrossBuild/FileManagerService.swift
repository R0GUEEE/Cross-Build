import Foundation
import SwiftUI

struct WorkspaceFile: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var isFavorite: Bool
    var children: [WorkspaceFile]?

    var id: String { path }

    static func == (lhs: WorkspaceFile, rhs: WorkspaceFile) -> Bool {
        lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    init(name: String, path: String, isDirectory: Bool = false, size: Int64 = 0,
         modified: Date = .now, isFavorite: Bool = false, children: [WorkspaceFile]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isFavorite = isFavorite
        self.children = children
    }
}

@MainActor
final class FileManagerService: ObservableObject {
    @Published var roots: [WorkspaceFile] = []
    @Published var selected: WorkspaceFile?
    @Published var recent: [WorkspaceFile] = []
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var includeAppDirectories = true

    let workspaceRoot: URL
    let documentsRoot: URL
    let libraryRoot: URL
    let temporaryRoot: URL
    let appBundleRoot: URL

    private let favoritesKey = "crossbuild.favoritePaths"
    private var favoritePaths: Set<String> = []
    private var showBundle = true
    private var showLibrary = true
    private var showTemporary = true
    private var showHidden = false
    private var followSymlinks = false
    private var searchCaseSensitive = false
    private var searchFileContents = false
    private var maxRecentFiles = 20
    private var excludedNames: Set<String> = [".git", "DerivedData", ".build", "node_modules", "Caches"]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        documentsRoot = docs
        libraryRoot = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? docs.appendingPathComponent("Library", isDirectory: true)
        temporaryRoot = FileManager.default.temporaryDirectory
        appBundleRoot = Bundle.main.bundleURL
        workspaceRoot = docs.appendingPathComponent("Workspace", isDirectory: true)
        favoritePaths = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        reload()
    }

    var flattened: [WorkspaceFile] {
        func walk(_ files: [WorkspaceFile]) -> [WorkspaceFile] {
            files.flatMap { [$0] + walk($0.children ?? []) }
        }
        return walk(roots)
    }

    var searchResults: [WorkspaceFile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return flattened.filter { file in
            if matchesName(file, needle: needle) { return true }
            return searchFileContents && contentMatches.contains(file.path)
        }
    }

    /// Paths whose *contents* matched the current query. Filled in
    /// asynchronously by `scheduleContentSearch()`; `searchResults` only reads
    /// this set, so rendering stays cheap.
    @Published private(set) var contentMatches: Set<String> = []
    private var contentSearchTask: Task<Void, Never>?

    /// Content search is opt-in, capped at 512 KB per file, and never runs on
    /// the main actor or once per keystroke. This has to be explicit: the search
    /// field binds `query` directly, so a synchronous content scan inside
    /// `searchResults` would re-read every file in the workspace on every
    /// render pass while the user types.
    private static let contentSearchSizeLimit: Int64 = 512 * 1024
    private static let contentSearchDebounceNanoseconds: UInt64 = 300_000_000

    /// Debounced, cancellable content search. Call whenever the query, the
    /// setting, or the workspace contents change.
    func scheduleContentSearch() {
        contentSearchTask?.cancel()
        contentSearchTask = nil

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchFileContents, !needle.isEmpty else {
            if !contentMatches.isEmpty { contentMatches = [] }
            return
        }

        let candidates: [String] = flattened
            .filter { !$0.isDirectory && $0.size > 0 && $0.size <= Self.contentSearchSizeLimit }
            .map(\.path)
        let caseSensitive = searchCaseSensitive

        contentSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.contentSearchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { () -> Set<String> in
                var found: Set<String> = []
                for path in candidates {
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    let hit = caseSensitive ? text.contains(needle) : text.localizedCaseInsensitiveContains(needle)
                    if hit { found.insert(path) }
                }
                return found
            }.value
            guard !Task.isCancelled, let self else { return }
            self.contentMatches = matches
        }
    }

    private func matchesName(_ file: WorkspaceFile, needle: String) -> Bool {
        if searchCaseSensitive {
            return file.name.contains(needle) || file.path.contains(needle)
        }
        return file.name.localizedCaseInsensitiveContains(needle) || file.path.localizedCaseInsensitiveContains(needle)
    }

    func configure(showAppDirectories: Bool, showBundle: Bool, showLibrary: Bool,
                   showTemporary: Bool, showHidden: Bool, followSymlinks: Bool,
                   searchCaseSensitive: Bool, searchFileContents: Bool = false, maxRecentFiles: Int = 20, excludePatterns: String) {
        includeAppDirectories = showAppDirectories
        self.showBundle = showBundle
        self.showLibrary = showLibrary
        self.showTemporary = showTemporary
        self.showHidden = showHidden
        self.followSymlinks = followSymlinks
        self.searchCaseSensitive = searchCaseSensitive
        self.searchFileContents = searchFileContents
        self.maxRecentFiles = max(5, maxRecentFiles)
        let configured = excludePatterns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        excludedNames = Set(configured).union([".git", "DerivedData", ".build", "node_modules"])
        // reload() re-schedules content search itself.
        reload()
    }

    func reload(from root: URL? = nil) {
        errorMessage = nil
        // The visible tree changed, so previously computed content matches may
        // point at files that moved or disappeared.
        defer { scheduleContentSearch() }
        if let root {
            roots = [makeRoot(root, displayName: root.lastPathComponent)]
            return
        }

        var loaded = [makeRoot(workspaceRoot, displayName: "Workspace")]
        if includeAppDirectories {
            loaded.append(makeRoot(documentsRoot, displayName: "App Documents", skipWorkspaceChild: true))
            if showLibrary { loaded.append(makeRoot(libraryRoot, displayName: "App Library")) }
            if showTemporary { loaded.append(makeRoot(temporaryRoot, displayName: "Temporary Files")) }
            if showBundle { loaded.append(makeRoot(appBundleRoot, displayName: "App Bundle")) }
        }
        roots = loaded
        refreshSelectedReference()
    }

    func isReadOnly(_ file: WorkspaceFile) -> Bool {
        file.path == appBundleRoot.path || file.path.hasPrefix(appBundleRoot.path + "/")
    }

    func revealWorkspaceOnly() {
        includeAppDirectories = false
        reload()
    }

    func revealAllAppDirectories() {
        includeAppDirectories = true
        showBundle = true
        showLibrary = true
        showTemporary = true
        reload()
    }

    func open(_ file: WorkspaceFile) {
        selected = file
        guard !file.isDirectory else { return }
        recent.removeAll { $0.path == file.path }
        recent.insert(file, at: 0)
        if recent.count > maxRecentFiles { recent = Array(recent.prefix(maxRecentFiles)) }
    }

    func contents(of file: WorkspaceFile, encoding: String.Encoding = .utf8) -> String? {
        guard !file.isDirectory else { return nil }
        do {
            return try String(contentsOfFile: file.path, encoding: encoding)
        } catch {
            errorMessage = "Could not open \(file.name) as UTF-8 text: \(error.localizedDescription)"
            return nil
        }
    }

    func save(_ text: String, to file: WorkspaceFile, encoding: String.Encoding = .utf8) throws {
        guard !file.isDirectory else { return }
        guard !isReadOnly(file) else {
            throw NSError(domain: "CrossBuild.Files", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The app bundle is read-only."])
        }
        try text.write(toFile: file.path, atomically: true, encoding: encoding)
    }

    @discardableResult
    func createFile(named name: String, in parentPath: String? = nil) -> WorkspaceFile? {
        errorMessage = nil
        guard valid(name) else { errorMessage = "Invalid file name."; return nil }
        let parent = URL(fileURLWithPath: parentPath ?? workspaceRoot.path)
        let url = uniqueURL(parent.appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            errorMessage = "Could not create \(url.lastPathComponent)."
            return nil
        }
        reload()
        return flattened.first { $0.path == url.path }
    }

    @discardableResult
    func createFolder(named name: String, in parentPath: String? = nil) -> WorkspaceFile? {
        errorMessage = nil
        guard valid(name) else { errorMessage = "Invalid folder name."; return nil }
        let parent = URL(fileURLWithPath: parentPath ?? workspaceRoot.path)
        let url = uniqueURL(parent.appendingPathComponent(name, isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            reload()
            return flattened.first { $0.path == url.path }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importFiles(_ urls: [URL], into parentPath: String? = nil) {
        errorMessage = nil
        let parent = URL(fileURLWithPath: parentPath ?? workspaceRoot.path)
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let dest = uniqueURL(parent.appendingPathComponent(source.lastPathComponent))
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reload()
    }

    func duplicate(_ file: WorkspaceFile) {
        errorMessage = nil
        guard !isReadOnly(file) else { errorMessage = "The app bundle is read-only."; return }
        let src = URL(fileURLWithPath: file.path)
        let ext = src.pathExtension
        let base = src.deletingPathExtension().lastPathComponent + " copy" + (ext.isEmpty ? "" : "." + ext)
        do {
            let dest = uniqueURL(src.deletingLastPathComponent().appendingPathComponent(base))
            try FileManager.default.copyItem(at: src, to: dest)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ file: WorkspaceFile) {
        errorMessage = nil
        guard !isReadOnly(file) else { errorMessage = "The app bundle is read-only."; return }
        do {
            try FileManager.default.removeItem(atPath: file.path)
            if selected?.path == file.path || selected?.path.hasPrefix(file.path + "/") == true { selected = nil }
            recent.removeAll { $0.path == file.path || $0.path.hasPrefix(file.path + "/") }
            favoritePaths = Set(favoritePaths.filter { $0 != file.path && !$0.hasPrefix(file.path + "/") })
            persistFavorites()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ file: WorkspaceFile, to newName: String) {
        errorMessage = nil
        guard !isReadOnly(file) else { errorMessage = "The app bundle is read-only."; return }
        guard valid(newName) else { errorMessage = "Invalid name."; return }
        do {
            let src = URL(fileURLWithPath: file.path)
            let dest = src.deletingLastPathComponent().appendingPathComponent(newName)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                errorMessage = "An item named \(newName) already exists."
                return
            }
            try FileManager.default.moveItem(at: src, to: dest)
            remapMetadata(from: src.path, to: dest.path)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ file: WorkspaceFile) {
        if favoritePaths.contains(file.path) { favoritePaths.remove(file.path) }
        else { favoritePaths.insert(file.path) }
        persistFavorites()
        reload()
    }

    private func makeRoot(_ url: URL, displayName: String, skipWorkspaceChild: Bool = false) -> WorkspaceFile {
        var visited = Set<String>()
        return node(for: url, displayName: displayName, visited: &visited, skipWorkspaceChild: skipWorkspaceChild)
    }

    private func node(for url: URL, displayName: String? = nil, visited: inout Set<String>,
                      skipWorkspaceChild: Bool = false) -> WorkspaceFile {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let isSymlink = values?.isSymbolicLink == true
        let alreadyVisited = visited.contains(resolved)

        var children: [WorkspaceFile]? = nil
        if isDirectory && !alreadyVisited && (!isSymlink || followSymlinks) {
            visited.insert(resolved)
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            var urls = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: options
            )) ?? []

            urls = urls.filter { child in
                if skipWorkspaceChild && child.standardizedFileURL.path == workspaceRoot.standardizedFileURL.path { return false }
                return !excludedNames.contains(child.lastPathComponent)
            }
            children = urls
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { child in node(for: child, visited: &visited) }
        }

        return WorkspaceFile(
            name: displayName ?? url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .now,
            isFavorite: favoritePaths.contains(url.path),
            children: children
        )
    }

    private func refreshSelectedReference() {
        guard let path = selected?.path else { return }
        selected = flattened.first { $0.path == path }
    }

    private func remapMetadata(from oldPath: String, to newPath: String) {
        recent = recent.map { file in
            guard file.path == oldPath || file.path.hasPrefix(oldPath + "/") else { return file }
            var updated = file
            updated.path = newPath + String(file.path.dropFirst(oldPath.count))
            if file.path == oldPath { updated.name = URL(fileURLWithPath: newPath).lastPathComponent }
            return updated
        }

        favoritePaths = Set(favoritePaths.map { path in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        })
        persistFavorites()

        if let current = selected, current.path == oldPath || current.path.hasPrefix(oldPath + "/") {
            var updated = current
            updated.path = newPath + String(current.path.dropFirst(oldPath.count))
            if current.path == oldPath { updated.name = URL(fileURLWithPath: newPath).lastPathComponent }
            selected = updated
        }
    }

    private func persistFavorites() {
        UserDefaults.standard.set(Array(favoritePaths).sorted(), forKey: favoritesKey)
    }

    private func valid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) \(index)" + (ext.isEmpty ? "" : "." + ext))
            index += 1
        }
        return candidate
    }
}
