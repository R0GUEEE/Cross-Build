import SwiftUI

/// One place that decides what a file looks like.
///
/// A tab and a row in the navigator describe the same file, and they used to do
/// it differently -- the tab said `doc.text` for everything, so a Swift file, a
/// Makefile and a PNG were indistinguishable in the strip you look at most.
enum WorkspaceFileIcon {
    static func symbol(for name: String) -> String {
        if isBuildFile(name) { return "hammer" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "c", "h": return "c.circle"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cplusplus"
        case "m", "mm": return "m.circle"
        case "rs": return "gearshape.2"
        case "go": return "g.circle"
        case "zig": return "z.circle"
        case "py": return "p.circle"
        case "js", "jsx", "ts", "tsx": return "j.circle"
        case "json": return "curlybraces"
        case "yml", "yaml": return "list.bullet.indent"
        case "md", "markdown": return "text.alignleft"
        case "sh", "bash", "zsh": return "terminal"
        case "plist", "xml": return "chevron.left.forwardslash.chevron.right"
        case "x", "xm": return "wrench.and.screwdriver"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "deb", "ipa", "zip": return "shippingbox"
        default: return "doc.text"
        }
    }

    static func tint(for name: String) -> Color {
        if isBuildFile(name) { return .teal }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return .orange
        case "c", "h": return .blue
        case "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return .indigo
        case "rs": return .brown
        case "go": return .cyan
        case "zig": return .mint
        case "py": return .green
        case "js", "jsx", "ts", "tsx": return .yellow
        case "json", "yml", "yaml", "plist", "xml": return .purple
        case "md", "markdown": return .secondary
        case "sh", "bash", "zsh": return .teal
        case "x", "xm": return .pink
        default: return .secondary
        }
    }

    /// A Makefile has no extension, so it would otherwise fall through to the
    /// generic document icon despite being one of the most important files in the
    /// project for this app in particular.
    static func isBuildFile(_ name: String) -> Bool {
        ["Makefile", "makefile", "GNUmakefile"].contains(name)
    }
}
