import SwiftUI

struct WorkspaceHomeView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let clone: () -> Void
    let configure: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:4) {
                    Text("Workspace").font(.largeTitle.bold())
                    Text("Open a file or import a project to start editing.").foregroundStyle(.secondary)
                }
                HStack {
                    action("Clone Repository","arrow.down.circle",clone)
                    action("New Swift File","doc.badge.plus") {
                        workspace.files.createFile(named:"Untitled.swift")
                        workspace.files.reload()
                        if let file=workspace.files.flattened.first(where:{$0.name=="Untitled.swift"}) {
                            workspace.files.open(file); workspace.openSelectedFile()
                        }
                    }
                    action("Detect Project","waveform.badge.magnifyingglass",workspace.detectSampleProject)
                    action("Configure","slider.horizontal.3",configure)
                }
                .buttonStyle(.bordered)

                GroupBox("Project Overview") {
                    VStack(alignment:.leading,spacing:8) {
                        LabeledContent("Project files",value:"\(workspace.projectFiles.count)")
                        LabeledContent("Toolchain",value:workspace.analysis?.primaryToolchain.rawValue ?? workspace.selectedToolchain.rawValue)
                        LabeledContent("Open editors",value:"\(workspace.editor.documents.count)")
                        LabeledContent("Execution",value:workspace.executionStatus)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if !workspace.files.recent.isEmpty {
                    GroupBox("Recent Files") {
                        VStack(alignment:.leading,spacing:4) {
                            ForEach(workspace.files.recent.prefix(6)) { file in
                                Button {
                                    workspace.files.open(file); workspace.openSelectedFile()
                                } label: {
                                    Label(file.name,systemImage:"doc.text").frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain).padding(.vertical,4)
                            }
                        }
                    }
                }
            }.padding(20)
        }
    }

    private func action(_ title:String,_ icon:String,_ action:@escaping()->Void)->some View {
        Button(action:action) { Label(title,systemImage:icon) }
    }
}
