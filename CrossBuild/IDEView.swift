import SwiftUI
import UIKit

/// The editor screen.
///
/// Redesigned around one idea: a file, a Build button, and everything else behind
/// two taps. The previous layout stacked five permanent chrome rows (toolbar,
/// tab bar, detection strip, edit menu bar, status bar) on top of a phone-sized
/// editor, and each row was another place to look for the same thing.
///
/// What is left: one header row, the open tabs, the code, one status line. Files
/// open in a sheet, output in a sheet, and every command lives in the "more" menu
/// rather than in a strip of menus.
struct IDEView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    @State private var showFiles = false
    @State private var showConsole = false
    @State private var showConsolePanel: ForgePanel = .terminal
    @State private var showCompilerManager = false
    @State private var showWorkspaceConfiguration = false
    @State private var showCompilerConfiguration = false
    @State private var showAgent = false
    @State private var showGoToLine = false
    @State private var goToLine = 1
    @State private var pendingCloseDocument: EditorDocument?
    @State private var editorSelection = CodeEditorSelection()
    @State private var currentMatch = 0
    /// Dismisses the failure banner for the run it belongs to, not forever.
    @State private var dismissedBannerAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.editor.showFind { findBar; Divider() }
            buildBanner
            if workspace.editor.documents.isEmpty {
                emptyState
            } else {
                tabBar
                Divider()
                editor
            }
            Divider()
            statusBar
        }
        .background(ForgeTheme.Surface.background)
        .sheet(isPresented: $showFiles) { filesSheet }
        .sheet(isPresented: $showConsole) { consoleSheet }
        .sheet(isPresented: $showCompilerManager) {
            CompilerManagerView().environmentObject(workspace)
        }
        .sheet(isPresented: $showWorkspaceConfiguration) {
            WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
        }
        .sheet(isPresented: $showCompilerConfiguration) {
            CompilerConfigurationView(config: workspace.compilerConfiguration).environmentObject(workspace)
        }
        .sheet(isPresented: $showAgent) {
            AgentDashboardView(settings: settings).environmentObject(workspace)
        }
        .alert(item: $pendingCloseDocument) { doc in
            Alert(
                title: Text("Discard unsaved changes?"),
                message: Text("\(doc.name) has changes that have not been saved."),
                primaryButton: .destructive(Text("Discard")) { workspace.closeDocument(doc.id) },
                secondaryButton: .cancel()
            )
        }
        .alert("Go to Line", isPresented: $showGoToLine) {
            TextField("Line", value: $goToLine, format: .number)
            Button("Go") { jumpToLine(goToLine) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("1 to \(max(1, workspace.editorText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }))")
        }
        .alert("Run Again?", isPresented: $pendingRerun) {
            Button("Run") { performBuild() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A command is already running. Wait for it to finish, then build.")
        }
    }

    @State private var pendingRerun = false

    // MARK: - Header

    private var projectName: String {
        guard let root = workspace.activeProjectRoot, !root.isEmpty else { return "Workspace" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { showFiles = true } label: {
                Image(systemName: "folder")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Files")

            VStack(alignment: .leading, spacing: 1) {
                Text(projectName).font(.headline).lineLimit(1)
                Text(workspace.editor.selected?.name ?? "No file open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: performBuild) {
                if workspace.isExecuting {
                    ProgressView().controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    Label("Build", systemImage: "hammer.fill")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(workspace.isExecuting)
            .accessibilityHint("Builds \(projectName)")

            Menu {
                editMenu
                buildMenu
                toolsMenu
                viewMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var editMenu: some View {
        Section("File") {
            Button("New File", systemImage: "doc.badge.plus") { createAndOpenNewFile() }
            Button("Save", systemImage: "square.and.arrow.down", action: workspace.saveEditor)
                .disabled(workspace.editor.selected == nil)
            if let document = workspace.editor.selected {
                Button("Close \(document.name)", systemImage: "xmark") { requestClose(document) }
            }
        }
        Section("Edit") {
            Button("Find & Replace", systemImage: "magnifyingglass") { workspace.editor.showFind.toggle() }
            Button("Go to Line…", systemImage: "arrow.right.to.line") {
                goToLine = editorSelection.line
                showGoToLine = true
            }
            Button("Indent", systemImage: "increase.indent") { transformSelectedLines(indent: true) }
            Button("Outdent", systemImage: "decrease.indent") { transformSelectedLines(indent: false) }
            Button("Duplicate Line", systemImage: "plus.square.on.square") { duplicateCurrentLine() }
            Button("Delete Line", systemImage: "trash") { deleteCurrentLine() }
            Button("Toggle Comment", systemImage: "text.bubble") { toggleComment() }
            Button("Trim Trailing Whitespace", systemImage: "eraser") { trimTrailingWhitespace() }
        }
    }

    @ViewBuilder private var buildMenu: some View {
        Section("Build") {
            Button("Build Project", systemImage: "hammer.fill") { workspace.runBuild(settings: settings) }
            if let document = workspace.editor.selected {
                Button("Build \(document.name)", systemImage: "doc.badge.gearshape") {
                    workspace.buildIndividual(.init(kind: .file(workspace.relativePath(document.path)),
                                                    title: document.name,
                                                    detail: "Compile this file on its own"),
                                              settings: settings)
                }
            }
            Button("Compile All Sources", systemImage: "square.stack.3d.down.right") {
                workspace.compileAllIndividualSources(settings: settings)
            }
            Button("Clean", systemImage: "trash") {
                workspace.runWorkflowCommand(workspace.cleanCommand(), settings: settings)
            }
            Button("Test", systemImage: "checkmark.seal") {
                workspace.runWorkflowCommand(workspace.testCommand(), settings: settings)
            }
            Button("Package", systemImage: "shippingbox.fill") {
                Task { _ = await workspace.runPackage(settings: settings) }
            }
            Button("Copy Project into Guest", systemImage: "arrow.down.to.line") {
                workspace.syncWorkspaceToGuest(settings: settings)
            }
        }
        Section("Output") {
            Button("Show Output", systemImage: "terminal") { openConsole(.terminal) }
            Button("Show Problems", systemImage: "exclamationmark.triangle") { openConsole(.problems) }
        }
    }

    @ViewBuilder private var toolsMenu: some View {
        Section("Tools") {
            Button("Detect Project", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
            Button("Agent", systemImage: "sparkles") { showAgent = true }
            Button("Compilers", systemImage: "cpu") { showCompilerManager = true }
            Button("Compiler Settings", systemImage: "slider.horizontal.3") { showCompilerConfiguration = true }
            Button("Project Settings", systemImage: "folder.badge.gearshape") { showWorkspaceConfiguration = true }
            Button("Refresh Files", systemImage: "arrow.clockwise") { workspace.files.reload() }
        }
    }

    @ViewBuilder private var viewMenu: some View {
        Section("View") {
            Toggle("Word Wrap", isOn: $settings.editorWordWrap)
            Toggle("Line Numbers", isOn: $settings.editorLineNumbers)
            Toggle("Highlight Current Line", isOn: $settings.editorHighlightCurrentLine)
            Toggle("Show Invisible Characters", isOn: $settings.editorShowInvisibles)
        }
    }

    // MARK: - Find

    private var findBar: some View {
        let matches = findMatches()
        return HStack(spacing: 6) {
            TextField("Find", text: Binding(get: { workspace.editor.findText },
                                            set: { workspace.editor.findText = $0; currentMatch = 0 }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text(matches.isEmpty ? "none" : "\(clampedMatchIndex(matches) + 1)/\(matches.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Button { stepMatch(matches, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty)
            Button { stepMatch(matches, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty)
            TextField("Replace", text: Binding(get: { workspace.editor.replaceText },
                                               set: { workspace.editor.replaceText = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
            Button("Replace") { replaceCurrentMatch(matches) }
                .disabled(matches.isEmpty)
            Button { workspace.editor.showFind = false } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Build banner

    /// One line about the last run. The console is where the details live, so this
    /// says what happened and offers the way in -- instead of the app's only
    /// feedback being text that scrolled past in a panel the user may have closed.
    @ViewBuilder private var buildBanner: some View {
        if !workspace.runProgress.isRunning,
           !workspace.lastRun.label.isEmpty,
           !workspace.lastRun.succeeded,
           dismissedBannerAt != bannerStamp {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(workspace.lastRun.label) failed").font(.subheadline.weight(.semibold))
                    Text(buildBannerDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Show") { openConsole(workspace.buildDiagnostics.isEmpty ? .terminal : .problems) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { dismissedBannerAt = bannerStamp } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
        } else if !workspace.runProgress.isRunning,
                  !workspace.lastRun.label.isEmpty,
                  workspace.lastRun.succeeded,
                  dismissedBannerAt != bannerStamp {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(workspace.lastRun.label) finished in \(BuildStatusBar.clock(workspace.lastRun.seconds))")
                    .font(.caption)
                Spacer()
                Button("Output") { openConsole(.terminal) }
                    .buttonStyle(.plain)
                    .font(.caption)
                Button { dismissedBannerAt = bannerStamp } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.green.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// Identifies the run the banner describes, so dismissing one does not hide
    /// the next one.
    private var bannerStamp: Date? { workspace.lastRun.label.isEmpty ? nil : workspace.lastRun.finishedAt }

    private var buildBannerDetail: String {
        if !workspace.buildDiagnostics.isEmpty {
            let errors = workspace.buildDiagnostics.filter { $0.severity == .error }.count
            let warnings = workspace.buildDiagnostics.filter { $0.severity == .warning }.count
            if errors > 0 { return "\(errors) error\(errors == 1 ? "" : "s")" + (warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : "") }
            if warnings > 0 { return "\(warnings) warning\(warnings == 1 ? "" : "s")" }
        }
        return "Exit code \(workspace.lastExitCode ?? 1) — open the output for details."
    }

    private func performBuild() {
        guard !workspace.isExecuting else { pendingRerun = true; return }
        dismissedBannerAt = nil
        workspace.runBuild(settings: settings)
    }

    // MARK: - Content

    private var emptyState: some View {
        ForgeEmptyState(icon: "doc.text",
                        title: "No File Open",
                        message: "Pick a file from the project, or start a new one.",
                        actionTitle: "Browse Files") { showFiles = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.editor.documents) { doc in
                    Button {
                        workspace.selectDocument(doc.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(doc.name).font(.caption).lineLimit(1)
                            if doc.isDirty {
                                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                            }
                            Button { requestClose(doc) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close \(doc.name)")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: ForgeTheme.compactCorner)
                                .fill(workspace.editor.selectedID == doc.id
                                      ? Color.secondary.opacity(0.14)
                                      : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button { createAndOpenNewFile() } label: {
                    Image(systemName: "plus").font(.caption).padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New file")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.secondary.opacity(0.04))
    }

    private var editor: some View {
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
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button { openConsole(.terminal) } label: {
                HStack(spacing: 5) {
                    if workspace.runProgress.isRunning {
                        ProgressView().controlSize(.small)
                        Text(workspace.runProgress.label).font(.caption2)
                    } else {
                        Image(systemName: "terminal").font(.caption2)
                        Text(workspace.isExecuting ? workspace.executionStatus : "Output").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if workspace.editor.selected != nil {
                Text("Ln \(editorSelection.line), Col \(editorSelection.column)")
                Text(EditorLanguage(fileName: workspace.editor.selected?.name ?? "").displayName)
            }
            Button { showConsole = true; showConsolePanel = .problems } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(workspace.buildDiagnostics.count)")
                }
                .font(.caption2)
                .foregroundStyle(workspace.buildDiagnostics.isEmpty ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Problems")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.05))
    }

    private func openConsole(_ panel: ForgePanel) {
        showConsolePanel = panel
        showConsole = true
    }

    // MARK: - Sheets

    private var filesSheet: some View {
        NavigationStack {
            WorkspaceBrowserView(files: workspace.files,
                                 onDelete: workspace.deleteFile,
                                 onRename: workspace.renameFile,
                                 confirmDeletes: settings.confirmDestructiveActions,
                                 onOpen: { file in
                                     workspace.openFile(file)
                                     showFiles = false
                                 },
                                 onSetActiveProject: { folder in
                                     workspace.useFolderAsActiveProject(folder)
                                     showFiles = false
                                 })
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showFiles = false }
                    }
                }
        }
    }

    private var consoleSheet: some View {
        NavigationStack {
            BottomWorkbenchView(panel: $showConsolePanel)
                .environmentObject(workspace)
                .navigationTitle(showConsolePanel.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showConsole = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Commands

    private func requestClose(_ doc: EditorDocument) {
        if doc.isDirty && workspace.configuration.confirmCloseDirty {
            pendingCloseDocument = doc
        } else {
            workspace.closeDocument(doc.id)
        }
    }

    /// Single place for "create a new file and actually show it".
    private func createAndOpenNewFile() {
        guard let file = workspace.files.createFile(named: workspace.newFileName()) else { return }
        workspace.files.open(file)
        workspace.openSelectedFile()
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

    private func jumpToLine(_ line: Int) {
        let lines = workspace.editorText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }
        let clamped = max(1, min(line, lines.count))
        let location = lines.prefix(clamped - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        editorSelection.range = NSRange(location: location, length: 0)
    }

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
        let cleaned = workspace.editorText.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        workspace.updateEditorText(cleaned)
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
}
