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


/// The one progress indicator for anything the app runs.
///
/// Determinate when the run announced a step count, indeterminate otherwise --
/// never a percentage nobody measured. Command output arrives all at once, so
/// there is nothing to stream a real percentage from.
struct RunProgressBar: View {
    let progress: WorkspaceModel.RunProgress
    var compact = false

    var body: some View {
        if progress.isRunning {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(progress.label).font(.caption.weight(.medium)).lineLimit(1)
                    if progress.stepCount > 1 {
                        Text("step \(progress.currentStep) of \(progress.stepCount)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.clock(progress.elapsed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !compact, !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ForgeCard<Content: View>: View {
    let title:String
    var subtitle:String? = nil
    @ViewBuilder let content:Content
    init(_ title:String, subtitle:String?=nil, @ViewBuilder content:()->Content) {
        self.title=title; self.subtitle=subtitle; self.content=content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(.secondary.opacity(0.055),in:RoundedRectangle(cornerRadius:ForgeTheme.corner))
    }
}

struct ForgeActionButton: View {
    let title:String
    let icon:String
    var prominent=false
    let action:()->Void
    var body: some View {
        Button(action:action) {
            Label(title,systemImage:icon).font(.subheadline.weight(.medium))
                .frame(maxWidth:.infinity,minHeight:38)
        }
        .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
    }
}

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let makeBodyClosure:(Configuration)->AnyView
    init<S:PrimitiveButtonStyle>(_ style:S) { makeBodyClosure={ AnyView(style.makeBody(configuration:$0)) } }
    func makeBody(configuration:Configuration)->some View { makeBodyClosure(configuration) }
}

struct ForgeMetric: View {
    let title:String
    let value:String
    let icon:String
    var body: some View {
        HStack(spacing:8) {
            Image(systemName:icon).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:1) {
                Text(value).font(.headline)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
