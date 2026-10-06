import SwiftUI
import UIKit

struct IDEView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    // Deliberately no size-class branching: the panel height used to change with
    // the window, so the same app looked like a different app when the window
    // moved. A fixed height that the user collapses is predictable.
    @State private var showCompilerManager = false
    @State private var showGitHub = false
    @State private var showWorkspaceConfiguration = false
    @State private var bottomPanel: ForgePanel = .terminal
    @State private var bottomExpanded = true
    @State private var pendingCloseDocument: EditorDocument?
    @State private var editorSelection = CodeEditorSelection()
    @State private var showGoToLine = false
    @State private var goToLine = 1
    /// Counted off the render path. `workspace.projectFiles.count` walks the whole
    /// file tree (`flattened` rebuilds it) and `makefileTargets()` reads the
    /// Makefile off disk -- both were evaluated on every body render, once inside
    /// the navigator header and once inside the Build menu's content builder.
    @State private var projectFileCount = 0
    @State private var makeTargets: [String] = []
    /// Which find/replace match is current, advanced by the up/down buttons.
    @State private var currentMatch = 0
    /// The bottom panel's height, scaled rather than fixed, so a large text size
    /// does not leave the console clipped.
    @ScaledMetric(relativeTo: .caption) private var bottomPanelHeight: CGFloat = 240

    var body: some View {
        NavigationSplitView {
            navigator
                .navigationTitle("Cross Build")
                // Applies the "Navigator width" preference, which used to be a
                // slider that nothing read.
                .navigationSplitViewColumnWidth(min: 220, ideal: settings.navigatorWidth, max: 480)
        } detail: {
            editorWorkspace
        }
        .sheet(isPresented: $showCompilerManager) {
            CompilerManagerView().environmentObject(workspace)
        }
        .sheet(isPresented: $showGitHub, onDismiss: {
            workspace.files.reload()
            if let importedPath = workspace.github.lastImportedPath {
                workspace.detectProject(at: importedPath)
            }
        }) {
            GitHubCloneView(github: workspace.github)
        }
        .sheet(isPresented: $showWorkspaceConfiguration) {
            WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
        }
        .onAppear {
            if let configured = ForgePanel(rawValue: settings.defaultBottomPanel) { bottomPanel = configured }
            bottomExpanded = settings.defaultBottomPanelExpanded
        }
        // Re-read when the tree is rebuilt or the active project changes.
        .task(id: "\(workspace.files.roots.count)-\(workspace.activeProjectRoot ?? "")") {
            projectFileCount = workspace.projectFiles.count
            makeTargets = workspace.makefileTargets()
        }
        .alert(item: $pendingCloseDocument) { doc in
            Alert(
                title: Text("Discard unsaved changes?"),
                message: Text("\(doc.name) has changes that have not been saved."),
                primaryButton: .destructive(Text("Discard")) { workspace.closeDocument(doc.id) },
                secondaryButton: .cancel()
            )
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment:.leading,spacing:2) {
                    Text("Project").font(.headline)
                    Text(projectFileCount == 1 ? "1 file" : "\(projectFileCount) files")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { openGitHubImporter() } label: { Image(systemName:"arrow.down.circle") }.buttonStyle(.plain)
                Button { workspace.files.reload() } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.plain)
                Menu {
                    Section("Project") {
                        Button("Refresh All Directories", systemImage: "arrow.clockwise") { workspace.files.reload() }
                        Button("Show App Files & Folders", systemImage: "square.stack.3d.up") { workspace.files.revealAllAppDirectories() }
                        Button("Workspace Only", systemImage: "folder") { workspace.files.revealWorkspaceOnly() }
                        Button("Save Current File", systemImage: "square.and.arrow.down", action: workspace.saveEditor)
                        Button("Detect Project & Compiler", systemImage: "waveform.badge.magnifyingglass", action: workspace.detectSampleProject)
                    }
                    Section("Source Control") {
                        Button("Clone from GitHub", systemImage: "arrow.down.circle") { openGitHubImporter() }
                    }
                    Section("File Operations") {
                        Button("New File", systemImage: "doc.badge.plus") { createAndOpenNewFile() }
                        Button("New Folder", systemImage: "folder.badge.plus") { workspace.files.createFolder(named: "New Folder") }
                        if let selected = workspace.files.selected {
                            Button("Duplicate Selected", systemImage: "plus.square.on.square") { workspace.files.duplicate(selected) }
                            Button("Copy Selected Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = selected.path }
                        }
                    }
                    Section("Tools") {
                        Button("Manage Compilers", systemImage: "cpu") { showCompilerManager = true }
                        Button("Workspace Configuration", systemImage: "slider.horizontal.3") { showWorkspaceConfiguration = true }
                        Button("Toggle Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") { bottomExpanded.toggle() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(10)

            Divider()
            WorkspaceBrowserView(files: workspace.files,
                                 onDelete: workspace.deleteFile,
                                 onRename: workspace.renameFile,
                                 confirmDeletes: settings.confirmDestructiveActions,
                                 onOpen: { workspace.openFile($0) },
                                 onSetActiveProject: { workspace.useFolderAsActiveProject($0) })
        }
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            tabBar
            Divider()
            detectionBar
            if workspace.editor.showFind {
                // Matches are computed here rather than stored, so the count is
                // always about the text on screen. The bar only exists while
                // searching, which is what keeps this off the render path the
                // rest of the time.
                let matches = findMatches()
                HStack(spacing: 6) {
                    TextField("Find", text: Binding(get: { workspace.editor.findText },
                                                    set: { workspace.editor.findText = $0; currentMatch = 0 })).textFieldStyle(.roundedBorder)
                    Text(matches.isEmpty ? "no matches" : "\(clampedMatchIndex(matches) + 1) of \(matches.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button { stepMatch(matches, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(matches.isEmpty)
                    Button { stepMatch(matches, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(matches.isEmpty)
                    TextField("Replace", text: Binding(get: { workspace.editor.replaceText }, set: { workspace.editor.replaceText = $0 })).textFieldStyle(.roundedBorder)
                    Button("Replace") { replaceCurrentMatch(matches) }
                        .disabled(matches.isEmpty)
                    Button("All") {
                        workspace.editor.replaceAll()
                        if let doc = workspace.editor.selected { workspace.updateEditorText(doc.text) }
                    }
                    .disabled(matches.isEmpty)
                    Button { workspace.editor.showFind = false } label: { Image(systemName: "xmark") }
                }.padding(8).background(.secondary.opacity(0.04))
            }
            if workspace.editor.documents.isEmpty && settings.showWelcomeScreen {
                WorkspaceHomeView(clone: { openGitHubImporter() }, configure: { showWorkspaceConfiguration = true }).environmentObject(workspace)
            } else if workspace.editor.documents.isEmpty {
                ForgeEmptyState(icon: "doc.text",
                                title: "No File Open",
                                message: "Open a file from the navigator, or start a new one.",
                                actionTitle: "New File") { createAndOpenNewFile() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The Go-to-Line alert lives here rather than on the split view.
                // Two `.alert` modifiers on the same view is one more than
                // SwiftUI honours, so it competed with the discard-changes alert
                // and could silently do nothing.
                editor
                    .alert("Go to Line", isPresented: $showGoToLine) {
                        TextField("Line", value: $goToLine, format: .number)
                        Button("Go") { jumpToLine(goToLine) }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        // One pass instead of `components(separatedBy:)`, which
                        // allocated an array of every line per body evaluation.
                        Text("1 to \(max(1, workspace.editorText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }))")
                    }
            }
            Divider()
            if bottomExpanded {
                BottomWorkbenchView(panel: $bottomPanel)
                    .environmentObject(workspace)
                    .frame(height: bottomPanelHeight)
            } else {
                collapsedPanelBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.editor.selected?.name ?? "Workspace").font(.headline)
                // Where the open file actually is, rather than repeating the
                // toolchain the detection strip already shows.
                Text(workspace.editor.selected.map { workspace.relativePath($0.path) } ?? "No file open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Menu {
                Picker("Toolchain", selection: $workspace.selectedToolchain) {
                    ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Manage Compilers", systemImage: "slider.horizontal.3") { showCompilerManager = true }
                Button("Auto Detect", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
            } label: {
                if settings.showStatusBadges {
                    IDEStatusPill(icon: "cpu", text: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
                } else {
                    Text(workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
                        .font(.caption)
                }
            }
            if workspace.editor.selected != nil {
                Button { workspace.editor.showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.bordered)
                Button(action: workspace.saveEditor) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
            }
            // A menu rather than a single button: the project build is one of
            // several things worth asking for, and building one file or one
            // target should not mean editing the project command first.
            Menu {
                Button("Build Project", systemImage: "hammer.fill") { workspace.runBuild(settings: settings) }
                if let document = workspace.editor.selected {
                    Button("Build \(document.name)", systemImage: "doc.badge.gearshape") {
                        workspace.buildIndividual(.init(kind: .file(workspace.relativePath(document.path)),
                                                        title: document.name,
                                                        detail: "Compile this file on its own"),
                                                  settings: settings)
                    }
                }
                let targets = makeTargets
                if !targets.isEmpty {
                    Menu("Build Make Target") {
                        ForEach(targets.prefix(20), id: \.self) { target in
                            Button("make \(target)") {
                                workspace.buildIndividual(.init(kind: .makeTarget(target),
                                                                title: "make \(target)",
                                                                detail: "Make target"),
                                                          settings: settings)
                            }
                        }
                    }
                }
                Divider()
                Button("Copy Workspace into Guest", systemImage: "arrow.down.to.line") {
                    workspace.syncWorkspaceToGuest(settings: settings)
                }
            } label: {
                if workspace.isExecuting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Build", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.isExecuting)
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.editor.documents) { doc in
                    HStack(spacing: 5) {
                        Button {
                            workspace.selectDocument(doc.id)
                        } label: {
                            HStack(spacing: 6) {
                                // The same icon the navigator shows for this file,
                                // so a tab is identifiable at a glance instead of
                                // every tab wearing the same document glyph.
                                Image(systemName: WorkspaceFileIcon.symbol(for: doc.name))
                                    .foregroundStyle(WorkspaceFileIcon.tint(for: doc.name))
                                Text(doc.name)
                                if doc.isDirty { Circle().frame(width: 6, height: 6) }
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            requestClose(doc)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close \(doc.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: ForgeTheme.compactCorner)
                            .fill(workspace.editor.selectedID == doc.id ? Color.secondary.opacity(0.12) : Color.clear)
                    )
                }
                Button(action: createAndOpenNewFile) {
                    Image(systemName: "plus").padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New file")
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(.secondary.opacity(0.04))
    }

    private func requestClose(_ doc: EditorDocument) {
        if doc.isDirty && workspace.configuration.confirmCloseDirty {
            pendingCloseDocument = doc
        } else {
            workspace.closeDocument(doc.id)
        }
    }

    /// Single place for "create a new file and actually show it". Creating without
    /// opening leaves an invisible untitled file on disk, which is what the empty
    /// state's New File button used to do -- every call site now goes through here
    /// so the two steps cannot drift apart again.
    private func createAndOpenNewFile() {
        guard let file = workspace.files.createFile(named: workspace.newFileName()) else { return }
        workspace.files.open(file)
        workspace.openSelectedFile()
    }

    @ViewBuilder private var detectionBar: some View {
        if let analysis = workspace.analysis {
            HStack(spacing: 8) {
                if settings.showStatusBadges {
                    IDEStatusPill(icon: "cpu", text: analysis.primaryToolchain.rawValue)
                    IDEStatusPill(icon: "chart.bar.fill", text: "\(Int(analysis.confidence * 100))%")
                    if let type = analysis.theosType { IDEStatusPill(icon: "wrench.and.screwdriver", text: type.rawValue) }
                } else {
                    Text("\(analysis.primaryToolchain.rawValue) · \(Int(analysis.confidence * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let candidate = analysis.candidates.first {
                    Text(candidate.command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                // The same build timer as the editor status bar, so the strip above
                // the code and the strip below it never disagree about a run.
                if workspace.runProgress.isRunning || !workspace.lastRun.label.isEmpty {
                    Divider().frame(height: 12)
                    BuildStatusBar(progress: workspace.runProgress, last: workspace.lastRun)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.secondary.opacity(0.04))
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            editorCommandBar
            Divider()
            CodeEditorView(
                text: Binding(get: { workspace.editorText }, set: { workspace.updateEditorText($0) }),
                selection: $editorSelection,
                fileName: workspace.editor.selected?.name ?? "Untitled",
                options: .init(
                    fontSize: settings.editorFontSize,
                    tabWidth: settings.editorTabWidth,
                    insertSpaces: settings.editorInsertSpaces,
                    wordWrap: settings.editorWordWrap,
                    showLineNumbers: settings.editorLineNumbers,
                    highlightCurrentLine: settings.editorHighlightCurrentLine,
                    showInvisibleCharacters: settings.editorShowInvisibles,
                    autoClosePairs: settings.editorAutoClosePairs
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            editorStatusBar
        }
    }

    private var editorCommandBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Save", systemImage: "square.and.arrow.down", action: workspace.saveEditor)
                Button("Find & Replace", systemImage: "magnifyingglass") { workspace.editor.showFind.toggle() }
                Divider()
                Button("Indent Selection", systemImage: "increase.indent") { transformSelectedLines(indent: true) }
                Button("Outdent Selection", systemImage: "decrease.indent") { transformSelectedLines(indent: false) }
                Button("Duplicate Line", systemImage: "plus.square.on.square") { duplicateCurrentLine() }
                Button("Delete Line", systemImage: "trash") { deleteCurrentLine() }
                Divider()
                Button("Trim Trailing Whitespace", systemImage: "eraser") { trimTrailingWhitespace() }
                Button("Sort Lines (Selection or File)", systemImage: "arrow.up.arrow.down") { sortSelectedLines() }
                Divider()
                Button("Toggle Comment", systemImage: "text.bubble") { toggleComment() }
                Button("Go to Line…", systemImage: "arrow.right.to.line") {
                    goToLine = editorSelection.line
                    showGoToLine = true
                }
            } label: {
                Label("Edit", systemImage: "text.cursor")
            }
            .buttonStyle(.bordered)

            Menu {
                Toggle("Word Wrap", isOn: $settings.editorWordWrap)
                Toggle("Line Numbers", isOn: $settings.editorLineNumbers)
                Toggle("Highlight Current Line", isOn: $settings.editorHighlightCurrentLine)
                Toggle("Auto-close Pairs", isOn: $settings.editorAutoClosePairs)
                Divider()
                Picker("Tab Width", selection: $settings.editorTabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                Toggle("Insert Spaces", isOn: $settings.editorInsertSpaces)
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)

            Spacer()
            if let doc = workspace.editor.selected {
                Text(EditorLanguage(fileName: doc.name).displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.035))
    }

    private var editorStatusBar: some View {
        HStack(spacing: 14) {
            BuildStatusBar(progress: workspace.runProgress, last: workspace.lastRun)
            Divider().frame(height: 12)
            Text("Ln \(editorSelection.line), Col \(editorSelection.column)")
            if editorSelection.selectedLength > 0 { Text("\(editorSelection.selectedLength) selected") }
            Spacer()
            Text(workspace.configuration.defaultEncoding)
            Text(workspace.configuration.lineEndings)
            Text(settings.editorInsertSpaces ? "Spaces: \(settings.editorTabWidth)" : "Tab: \(settings.editorTabWidth)")
            if workspace.editor.selected?.isDirty == true {
                Label("Modified", systemImage: "circle.fill")
            } else {
                Label("Saved", systemImage: "checkmark.circle")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.05))
    }

    private func lineRange(in text: String, line: Int) -> Range<String.Index>? {
        guard line > 0 else { return nil }
        var start = text.startIndex
        var current = 1
        while current < line, let newline = text[start...].firstIndex(of: "\n") {
            start = text.index(after: newline)
            current += 1
        }
        guard current == line else { return nil }
        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
        return start..<end
    }

    /// Every match of the find string, in document order.
    private func findMatches() -> [NSRange] {
        let needle = workspace.editor.findText
        guard !needle.isEmpty else { return [] }
        let text = workspace.editorText as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor <= text.length {
            let found = text.range(of: needle, options: [], range: NSRange(location: cursor, length: text.length - cursor))
            if found.location == NSNotFound { break }
            ranges.append(found)
            cursor = found.location + max(1, found.length)
        }
        return ranges
    }

    /// Which match is current, so the bar can say "3 of 9".
    ///
    /// This used to be derived from the caret and to fall back to index 0, so
    /// whenever the caret was not exactly on a match the label read "1 of N" and
    /// "Replace" silently rewrote the *first* match in the file instead of the one
    /// near the caret. The index is now tracked explicitly and clamped.
    private func clampedMatchIndex(_ matches: [NSRange]) -> Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(currentMatch, 0), matches.count - 1)
    }

    private func stepMatch(_ matches: [NSRange], by offset: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let next = ((clampedMatchIndex(matches) + offset) % count + count) % count
        currentMatch = next
        editorSelection.range = matches[next]
    }

    private func replaceCurrentMatch(_ matches: [NSRange]) {
        guard !matches.isEmpty else { return }
        let range = matches[clampedMatchIndex(matches)]
        let text = workspace.editorText as NSString
        guard range.location + range.length <= text.length else { return }
        let replacement = workspace.editor.replaceText
        workspace.updateEditorText(text.replacingCharacters(in: range, with: replacement))
        editorSelection.range = NSRange(location: range.location + (replacement as NSString).length, length: 0)
    }

    /// Moves the caret to a 1-based line.
    private func jumpToLine(_ line: Int) {
        let lines = workspace.editorText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }
        let clamped = max(1, min(line, lines.count))
        let location = lines.prefix(clamped - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        editorSelection.range = NSRange(location: location, length: 0)
    }

    /// Comments or uncomments the selected lines, or the caret's line.
    ///
    /// It uncomments only when every covered line is already commented, which is
    /// what makes it a toggle rather than a one-way switch.
    private func toggleComment() {
        let marker = EditorLanguage(fileName: workspace.editor.selected?.name ?? "").lineComment
        guard !marker.isEmpty else { return }
        var lines = workspace.editorText.components(separatedBy: "\n")

        var bounds: (lower: Int, upper: Int)?
        if let selection = selectedLineBounds() {
            bounds = selection
        } else {
            let index = editorSelection.line - 1
            bounds = lines.indices.contains(index) ? (lower: index, upper: index + 1) : nil
        }
        guard let bounds, bounds.lower < bounds.upper, bounds.upper <= lines.count else { return }

        let allCommented = lines[bounds.lower..<bounds.upper].allSatisfy { line in
            line.drop { $0 == " " || $0 == "\t" }.hasPrefix(marker)
        }
        for index in bounds.lower..<bounds.upper {
            let line = lines[index]
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var body = String(line.dropFirst(indent.count))
            if allCommented {
                if body.hasPrefix(marker + " ") { body.removeFirst(marker.count + 1) }
                else if body.hasPrefix(marker) { body.removeFirst(marker.count) }
            } else if !body.hasPrefix(marker) {
                body = marker + " " + body
            }
            lines[index] = indent + body
        }
        workspace.updateEditorText(lines.joined(separator: "\n"))
    }

    private func duplicateCurrentLine() {
        var text = workspace.editorText
        guard let range = lineRange(in: text, line: editorSelection.line) else { return }
        let value = String(text[range])
        text.insert(contentsOf: "\n" + value, at: range.upperBound)
        workspace.updateEditorText(text)
    }

    private func deleteCurrentLine() {
        var text = workspace.editorText
        guard let range = lineRange(in: text, line: editorSelection.line) else { return }
        var removal = range
        if removal.upperBound < text.endIndex { removal = removal.lowerBound..<text.index(after: removal.upperBound) }
        else if removal.lowerBound > text.startIndex { removal = text.index(before: removal.lowerBound)..<removal.upperBound }
        text.removeSubrange(removal)
        workspace.updateEditorText(text)
    }

    private func transformSelectedLines(indent: Bool) {
        let unit = settings.editorInsertSpaces ? String(repeating: " ", count: settings.editorTabWidth) : "\t"
        var lines = workspace.editorText.components(separatedBy: "\n")

        // Indent/outdent every line the selection covers; with no selection, the
        // caret's line -- which is what the command already did.
        var bounds: (lower: Int, upper: Int)?
        if let selection = selectedLineBounds() {
            bounds = selection
        } else {
            let index = editorSelection.line - 1
            bounds = lines.indices.contains(index) ? (lower: index, upper: index + 1) : nil
        }
        guard let bounds, bounds.lower < bounds.upper, bounds.upper <= lines.count else { return }

        for index in bounds.lower..<bounds.upper {
            if indent {
                lines[index] = unit + lines[index]
            } else if lines[index].hasPrefix(unit) {
                lines[index].removeFirst(unit.count)
            } else if lines[index].hasPrefix("\t") {
                lines[index].removeFirst()
            }
        }
        workspace.updateEditorText(lines.joined(separator: "\n"))
    }

    private func trimTrailingWhitespace() {
        // `#"\\s+$"#` is a *literal backslash* followed by `s+$` in a raw string,
        // so it could only ever match a line ending in `\sss...` and the command
        // never removed a space or a tab. Use the same pattern the save path uses.
        let cleaned = workspace.editorText.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        workspace.updateEditorText(cleaned)
    }

    /// Sorts the selected lines when there is a selection, and the whole document
    /// when there is none (the behaviour a "sort lines" command normally has).
    /// The previous version checked only the caret's line and then sorted every
    /// line regardless of what was selected, silently reordering the entire file
    /// behind an autosave.
    private func sortSelectedLines() {
        var lines = workspace.editorText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }
        let bounds = selectedLineBounds() ?? (lower: 0, upper: lines.count)
        guard bounds.lower < bounds.upper, bounds.upper <= lines.count else { return }
        lines[bounds.lower..<bounds.upper].sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        workspace.updateEditorText(lines.joined(separator: "\n"))
    }

    /// The half-open line range covered by the current selection, or nil when
    /// nothing is selected. A selection ending exactly at a line break does not
    /// drag in the following line.
    private func selectedLineBounds() -> (lower: Int, upper: Int)? {
        let selection = editorSelection.range
        guard selection.length > 0, selection.location != NSNotFound else { return nil }
        let first = lineIndex(atUTF16Offset: selection.location)
        let last = lineIndex(atUTF16Offset: selection.location + selection.length - 1)
        return (max(0, first - 1), last)
    }

    /// 1-based line number containing the given UTF-16 offset.
    private func lineIndex(atUTF16Offset offset: Int) -> Int {
        let ns = workspace.editorText as NSString
        let clamped = max(0, min(offset, ns.length))
        return ns.substring(to: clamped).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func openGitHubImporter() {
        workspace.github.lastImportedPath = nil
        showGitHub = true
    }

    private var collapsedPanelBar: some View {
        HStack {
            ForEach(ForgePanel.allCases) { item in
                Button {
                    bottomPanel = item; bottomExpanded = true
                } label: { Label(item.rawValue, systemImage: item.icon).font(.caption) }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { bottomExpanded = true } label: { Image(systemName: "chevron.up") }
        }.padding(8)
    }
}
