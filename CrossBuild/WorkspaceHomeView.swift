import SwiftUI

struct WorkspaceHomeView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    // Fixed padding, so the home screen does not re-flow when the window size
    // class changes.
    let clone:()->Void
    let configure:()->Void
    /// Counted off the render path: `projectFiles` rebuilds the whole file tree.
    @State private var projectFileCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Ready to build").font(.largeTitle.bold())
                    Text("Open a project file, clone a repository, or create something new.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:10)],spacing:10) {
                    ForgeActionButton(title:"Clone Repository",icon:"arrow.down.circle",prominent:true,action:clone)
                    ForgeActionButton(title:"New File",icon:"doc.badge.plus",action:newFile)
                    ForgeActionButton(title:"Detect Project",icon:"waveform.badge.magnifyingglass",action:workspace.detectSampleProject)
                    ForgeActionButton(title:"Configure",icon:"slider.horizontal.3",action:configure)
                }

                ForgeCard("Project Overview",subtitle:"Current workspace at a glance") {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:130),spacing:12)],spacing:12) {
                        ForgeMetric(title:"Project Files",value:"\(projectFileCount)",icon:"doc.on.doc")
                        ForgeMetric(title:"Toolchain",value:shortToolchain,icon:"cpu")
                        ForgeMetric(title:"Open Editors",value:"\(workspace.editor.documents.count)",icon:"rectangle.stack")
                        ForgeMetric(title:"Execution",value:workspace.executionStatus,icon:"play.circle")
                    }
                }

                if let analysis=workspace.analysis {
                    ForgeCard("Detected Project",subtitle:"Cross Build analyzed the active workspace") {
                        HStack {
                            IDEStatusPill(icon:"cpu",text:analysis.primaryToolchain.rawValue)
                            IDEStatusPill(icon:"chart.bar",text:"\(Int(analysis.confidence*100))%")
                            Spacer()
                        }
                        if let candidate=analysis.candidates.first {
                            Text(candidate.command).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }

                if !workspace.files.recent.isEmpty {
                    ForgeCard("Recent Files",subtitle:"Continue where you left off") {
                        VStack(spacing:0) {
                            ForEach(workspace.files.recent.prefix(6)) { file in
                                Button {
                                    workspace.files.open(file); workspace.openSelectedFile()
                                } label: {
                                    HStack {
                                        Image(systemName:"doc.text")
                                        VStack(alignment:.leading) {
                                            Text(file.name)
                                            Text(URL(fileURLWithPath:file.path).deletingLastPathComponent().lastPathComponent)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.padding(.vertical,9)
                                }.buttonStyle(.plain)
                                if file.id != workspace.files.recent.prefix(6).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(ForgeTheme.Space.xl)
            .frame(maxWidth:900)
            .frame(maxWidth:.infinity)
        }
        // Re-read when the file tree is rebuilt, rather than on every render.
        .task(id: workspace.files.roots.count) {
            projectFileCount = workspace.projectFiles.count
        }
    }

    private var shortToolchain:String {
        workspace.analysis?.primaryToolchain.rawValue ?? workspace.selectedToolchain.rawValue
    }
    private func newFile() {
        if let file = workspace.files.createFile(named: workspace.newFileName()) {
            workspace.files.open(file)
            workspace.openSelectedFile()
        }
    }
}
