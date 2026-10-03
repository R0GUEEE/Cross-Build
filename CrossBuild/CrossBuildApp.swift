import SwiftUI

@main
struct CrossBuildApp: App {
    @StateObject private var workspace = WorkspaceModel()
    var body: some Scene {
        WindowGroup { IDEView().environmentObject(workspace) }
    }
}
