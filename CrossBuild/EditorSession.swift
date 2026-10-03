import Foundation

struct EditorDocument: Identifiable, Hashable {
    let id: UUID
    var path: String
    var name: String
    var text: String
    var savedText: String
    var isDirty: Bool { text != savedText }
    init(id:UUID=UUID(), path:String, name:String, text:String) {
        self.id=id; self.path=path; self.name=name; self.text=text; self.savedText=text
    }
}

@MainActor
final class EditorSession: ObservableObject {
    @Published var documents:[EditorDocument] = []
    @Published var selectedID:UUID?
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var showFind = false

    var selectedIndex:Int? { documents.firstIndex { $0.id == selectedID } }
    var selected:EditorDocument? { guard let i=selectedIndex else{return nil}; return documents[i] }

    func open(file:WorkspaceFile, text:String) {
        if let existing=documents.first(where:{$0.path==file.path}) { selectedID=existing.id; return }
        let doc=EditorDocument(path:file.path,name:file.name,text:text)
        documents.append(doc); selectedID=doc.id
    }
    func close(_ id:UUID) {
        guard let i=documents.firstIndex(where:{$0.id==id}) else{return}
        documents.remove(at:i)
        if selectedID==id { selectedID=documents.indices.contains(i) ? documents[i].id : documents.last?.id }
    }
    func updateText(_ value:String) { guard let i=selectedIndex else{return}; documents[i].text=value }
    func document(_ id: UUID) -> EditorDocument? {
        documents.first { $0.id == id }
    }

    func markSaved(_ id: UUID, text: String? = nil) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        if let text { documents[i].text = text }
        documents[i].savedText = documents[i].text
    }

    func markSaved() {
        guard let id = selectedID else { return }
        markSaved(id)
    }

    func replaceAll() {
        guard let i=selectedIndex,!findText.isEmpty else{return}
        documents[i].text=documents[i].text.replacingOccurrences(of:findText,with:replaceText)
    }
}
