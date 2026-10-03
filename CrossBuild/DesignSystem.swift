import SwiftUI

enum ForgePanel: String, CaseIterable, Identifiable {
    case terminal = "Terminal", problems = "Problems", build = "Build", agent = "Agent"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .problems: return "exclamationmark.triangle"
        case .build: return "hammer"
        case .agent: return "sparkles"
        }
    }
}

struct ForgeTheme {
    static let corner: CGFloat = 12
    static let compactCorner: CGFloat = 8
}

struct IDEStatusPill: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.secondary.opacity(0.10), in: Capsule())
    }
}

struct IDESectionHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}
