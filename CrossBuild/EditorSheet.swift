import SwiftUI

/// The file editor, as a popup over the file list.
///
/// It used to be a tab of its own, which meant every "open this file" gesture
/// moved the whole app somewhere else and every "look at another file" gesture
/// moved it back. Editing one file is a detour from browsing, not a destination.
struct EditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selection = CodeEditorSelection()
    @State private var showGoToLine = false
    @State private var goToLine = 1
    @State private var currentMatch = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workspace.editor.showFind { findBar; Divider() }
                if workspace.editor.selected == nil {
                    ForgeEmptyState(icon: "doc.text",
                                    title: "No File",
                                    message: "Pick a file from the project to edit it here.",
                                    actionTitle: "Close") { dismiss() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodeEditorView(
                        text: Binding(get: { workspace.editorText },
                                      set: { workspace.updateEditorText($0) }),
                        selection: $selection,
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
                    Divider()
                    statusBar
                }
            }
            .navigationTitle(workspace.editor.selected?.name ?? "Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        workspace.editor.showFind.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Find")
                    Button {
                        workspace.saveEditor()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(workspace.editor.selected == nil)
                    .accessibilityLabel("Save")
                }
            }
            .alert("Go to Line", isPresented: $showGoToLine) {
                TextField("Line", value: $goToLine, format: .number)
                Button("Go") { jumpToLine(goToLine) }
                Button("Cancel", role: .cancel) { }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(workspace.editor.selected?.isDirty == true)
    }

    private func close() {
        if let document = workspace.editor.selected, document.isDirty {
            workspace.saveEditor()
        }
        dismiss()
    }

    private var findBar: some View {
        let matches = findMatches()
        return HStack(spacing: 6) {
            TextField("Find", text: Binding(get: { workspace.editor.findText },
                                            set: { workspace.editor.findText = $0; currentMatch = 0 }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text(matches.isEmpty ? "none" : "\(clamped(matches) + 1)/\(matches.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { step(matches, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty)
            Button { step(matches, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty)
            Button { workspace.editor.showFind = false } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Ln \(selection.line), Col \(selection.column)")
            let language = EditorLanguage(fileName: workspace.editor.selected?.name ?? "")
            Text(language.displayName)
            Spacer()
            if workspace.editor.selected?.isDirty == true {
                Label("Modified", systemImage: "circle.fill")
            } else {
                Label("Saved", systemImage: "checkmark.circle")
            }
            Button("Go to Line") {
                goToLine = selection.line
                showGoToLine = true
            }
            .buttonStyle(.plain)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.05))
    }

    // MARK: - Search

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

    private func clamped(_ matches: [NSRange]) -> Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(currentMatch, 0), matches.count - 1)
    }

    private func step(_ matches: [NSRange], by offset: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentMatch = ((clamped(matches) + offset) % count + count) % count
        selection.range = matches[currentMatch]
    }

    private func jumpToLine(_ line: Int) {
        let lines = workspace.editorText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }
        let clampedLine = max(1, min(line, lines.count))
        let location = lines.prefix(clampedLine - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        selection.range = NSRange(location: location, length: 0)
    }
}
