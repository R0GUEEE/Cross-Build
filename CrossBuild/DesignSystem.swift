import SwiftUI

// MARK: - Panels

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

// MARK: - Tokens

/// The design tokens everything else is built from.
///
/// The app previously hard-coded its own numbers at each call site -- a 14 here,
/// a 12 there, `.secondary.opacity(0.055)` in one card and `0.04` in the next --
/// which is how a UI ends up almost-consistent, where the eye reads the
/// near-misses as sloppiness. Everything visual now comes from here.
enum ForgeTheme {
    static let corner: CGFloat = 12
    static let compactCorner: CGFloat = 8

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let pill: CGFloat = 999
    }

    enum Surface {
        /// Page background, behind the scrolling content.
        static let background = Color(.systemGroupedBackground)
        /// Cards and grouped sections sitting on the background.
        static let card = Color(.secondarySystemGroupedBackground)
        /// The strongest quiet fill -- headers, inset strips.
        static let raised = Color(.tertiarySystemFill)
        /// A hairline that reads on both light and dark.
        static let border = Color.primary.opacity(0.07)
    }

    /// Fixed heights so rows line up across screens rather than each view picking
    /// its own padding and hoping.
    enum Row {
        static let height: CGFloat = 44
        static let compactHeight: CGFloat = 34
    }
}

// MARK: - Primitives

/// The app's status chip. `IDEStatusPill` and `ForgeBadge` were two capsules that
/// differed only in padding, so one is now the other.
struct IDEStatusPill: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        ForgeBadge(text: text, icon: icon, tint: tint)
    }
}

/// The one empty state. Five screens had grown their own version of this, each
/// with a different icon size and nothing to do next.
struct ForgeEmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        // The system's own empty state where it exists: it matches the rest of
        // iOS, follows Dynamic Type and accessibility settings, and is the shape
        // people already recognise. The hand-rolled one stays for iOS 16.
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                if let message { Text(message) }
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.borderedProminent)
                }
            }
        } else {
            legacy
        }
    }

    private var legacy: some View {
        VStack(spacing: ForgeTheme.Space.md) {
            Image(systemName: icon)
                .font(.largeTitle.weight(.light))
                .imageScale(.large)
                .foregroundStyle(.tertiary)
            VStack(spacing: ForgeTheme.Space.xs) {
                Text(title).font(.headline)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ForgeTheme.Space.xl)
        .padding(.horizontal, ForgeTheme.Space.lg)
    }
}

/// A number with a label, for the summary tiles the dashboards are made of.
struct ForgeStat: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: ForgeTheme.Space.sm) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .imageScale(.medium)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kept as the name the dashboards already use.
struct ForgeMetric: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        ForgeStat(title: title, value: value, icon: icon)
    }
}

struct ForgeBadge: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            // `imageScale` rather than a fixed point size, so the chip grows with
            // the label next to it instead of staying at 9pt.
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// A card. Used to be a one-off background colour and radius; now it is the
/// tokenised surface so every panel in the app matches.
struct ForgeCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ForgeTheme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: ForgeTheme.Space.sm) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(ForgeTheme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForgeTheme.Surface.card, in: RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .strokeBorder(ForgeTheme.Surface.border, lineWidth: 1)
        )
    }
}

struct ForgeActionButton: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: ForgeTheme.Row.compactHeight + 4)
        }
        .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
    }
}

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        makeBodyClosure = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { makeBodyClosure(configuration) }
}

/// How a diagnostic is shown, in one place, so the Problems panel and any inline
/// report cannot disagree about what red means.
extension BuildDiagnosticSeverity {
    var tint: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .note: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle.fill"
        }
    }
}

// MARK: - Progress

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
            VStack(alignment: .leading, spacing: ForgeTheme.Space.xs + 1) {
                HStack(spacing: 6) {
                    Text(progress.label).font(.caption.weight(.medium)).lineLimit(1)
                    if progress.stepCount > 1 {
                        Text("step \(progress.currentStep) of \(progress.stepCount)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: ForgeTheme.Space.xs)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.clock(progress.elapsed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
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

/// The build timer, in one place: what is running and for how long, or what ran
/// last and how long it took. A run that has finished still has a duration worth
/// seeing, which is why this reads both the live progress and the last record.
struct BuildStatusBar: View {
    let progress: WorkspaceModel.RunProgress
    let last: WorkspaceModel.RunRecord

    var body: some View {
        HStack(spacing: ForgeTheme.Space.sm) {
            if progress.isRunning {
                ProgressView().controlSize(.small)
                Text(progress.label).fontWeight(.medium).lineLimit(1)
                if progress.stepCount > 1 {
                    Text("step \(progress.currentStep)/\(progress.stepCount)")
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(RunProgressBar.clock(progress.elapsed))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
            } else if !last.label.isEmpty {
                Label(last.succeeded ? "ok" : "failed",
                      systemImage: last.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(last.succeeded ? .green : .red)
                Text(last.label).lineLimit(1)
                Text(RunProgressBar.clock(last.seconds)).monospacedDigit()
            } else {
                Text("No build has run yet").foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
    }
}
