import Foundation

enum ProjectLanguage: String, CaseIterable, Hashable {
    case c = "C", cpp = "C++", objc = "Objective-C", objcpp = "Objective-C++"
    case swift = "Swift", logos = "Logos", rust = "Rust", go = "Go", zig = "Zig"
    case python = "Python", javascript = "JavaScript", typescript = "TypeScript"
    case java = "Java", kotlin = "Kotlin", assembly = "Assembly"
}

enum BuildSystem: String, Hashable {
    case theos = "Theos", swiftPM = "SwiftPM", xcode = "Xcode"
    case cargo = "Cargo", go = "Go Modules", zig = "Zig Build"
    case npm = "npm", pnpm = "pnpm", yarn = "Yarn"
    case cmake = "CMake", meson = "Meson", make = "Make", ninja = "Ninja"
    case gradle = "Gradle", python = "Python Packaging", unknown = "Custom"
}

enum TheosProjectType: String {
    case tweak = "Tweak", application = "Application", tool = "Tool"
    case library = "Library", framework = "Framework"
    case preferenceBundle = "Preference Bundle", bundle = "Bundle", unknown = "Unknown"
}

struct DetectionEvidence: Identifiable {
    let id = UUID()
    let signal: String
    let detail: String
    let weight: Int
}

struct BuildCandidate: Identifiable {
    let id = UUID()
    let system: BuildSystem
    let toolchain: ToolchainKind
    let command: String
    let confidence: Double
    let reason: String
}

struct ProjectAnalysis {
    let primaryToolchain: ToolchainKind
    let languages: Set<ProjectLanguage>
    let buildSystems: Set<BuildSystem>
    let candidates: [BuildCandidate]
    let evidence: [DetectionEvidence]
    let theosType: TheosProjectType?
    let isRootlessHinted: Bool
    let isMonorepo: Bool

    var confidence: Double { candidates.first?.confidence ?? 0 }
}

enum ProjectDetector {
    static func analyze(paths: [String], fileContents: [String: String] = [:]) -> ProjectAnalysis {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        var languages = Set<ProjectLanguage>()
        var systems = Set<BuildSystem>()
        var evidence: [DetectionEvidence] = []
        var scores: [ToolchainKind: Int] = [:]
        var candidates: [BuildCandidate] = []

        func hit(_ kind: ToolchainKind, _ points: Int, _ signal: String, _ detail: String) {
            scores[kind, default: 0] += points
            evidence.append(.init(signal: signal, detail: detail, weight: points))
        }
        func has(_ name: String) -> Bool { names.contains(name) }
        func ext(_ suffix: String) -> Bool { names.contains { $0.lowercased().hasSuffix(suffix) } }

        let languageRules: [(String, ProjectLanguage, ToolchainKind)] = [
            (".c", .c, .clang), (".cc", .cpp, .clang), (".cpp", .cpp, .clang),
            (".m", .objc, .clang), (".mm", .objcpp, .clang), (".swift", .swift, .swift),
            (".xm", .logos, .theos), (".x", .logos, .theos), (".xi", .logos, .theos),
            (".rs", .rust, .rust), (".go", .go, .go), (".zig", .zig, .zig),
            (".py", .python, .python), (".js", .javascript, .javascript),
            (".ts", .typescript, .javascript), (".java", .java, .custom),
            (".kt", .kotlin, .custom), (".s", .assembly, .clang), (".asm", .assembly, .clang)
        ]
        for (suffix, language, toolchain) in languageRules where ext(suffix) {
            languages.insert(language); hit(toolchain, 8, "source", "Detected \(language.rawValue) sources")
        }

        if has("Package.swift") {
            systems.insert(.swiftPM); hit(.swift, 45, "manifest", "Package.swift")
            candidates.append(.init(system: .swiftPM, toolchain: .swift, command: "swift build", confidence: 0.96, reason: "SwiftPM manifest"))
        }
        if has("Cargo.toml") {
            systems.insert(.cargo); hit(.rust, 45, "manifest", "Cargo.toml")
            candidates.append(.init(system: .cargo, toolchain: .rust, command: "cargo build", confidence: 0.96, reason: "Cargo manifest"))
        }
        if has("go.mod") {
            systems.insert(.go); hit(.go, 45, "manifest", "go.mod")
            candidates.append(.init(system: .go, toolchain: .go, command: "go build ./...", confidence: 0.96, reason: "Go module"))
        }
        if has("build.zig") || has("build.zig.zon") {
            systems.insert(.zig); hit(.zig, 45, "manifest", "build.zig")
            candidates.append(.init(system: .zig, toolchain: .zig, command: "zig build", confidence: 0.96, reason: "Zig build manifest"))
        }
        if has("CMakeLists.txt") {
            systems.insert(.cmake); hit(.clang, 30, "build-system", "CMakeLists.txt")
            candidates.append(.init(system: .cmake, toolchain: .clang, command: "cmake -S . -B build && cmake --build build", confidence: 0.90, reason: "CMake project"))
        }
        if has("meson.build") {
            systems.insert(.meson); hit(.clang, 30, "build-system", "meson.build")
            candidates.append(.init(system: .meson, toolchain: .clang, command: "meson setup build && meson compile -C build", confidence: 0.90, reason: "Meson project"))
        }
        if has("package.json") {
            systems.insert(has("pnpm-lock.yaml") ? .pnpm : has("yarn.lock") ? .yarn : .npm)
            hit(.javascript, 38, "manifest", "package.json")
            let command = has("pnpm-lock.yaml") ? "pnpm run build" : has("yarn.lock") ? "yarn build" : "npm run build"
            candidates.append(.init(system: has("pnpm-lock.yaml") ? .pnpm : has("yarn.lock") ? .yarn : .npm, toolchain: .javascript, command: command, confidence: 0.92, reason: "JavaScript package manifest"))
        }
        if has("pyproject.toml") || has("setup.py") || has("requirements.txt") {
            systems.insert(.python); hit(.python, 38, "manifest", "Python project metadata")
            candidates.append(.init(system: .python, toolchain: .python, command: "python3 -m build", confidence: 0.88, reason: "Python packaging metadata"))
        }
        if has("build.gradle") || has("build.gradle.kts") {
            systems.insert(.gradle); hit(.custom, 35, "build-system", "Gradle build")
            candidates.append(.init(system: .gradle, toolchain: .custom, command: "./gradlew build", confidence: 0.91, reason: "Gradle project"))
        }

        let makefile = fileContents["Makefile"] ?? ""
        let control = fileContents["control"] ?? ""
        let theosBySource = languages.contains(.logos)
        let theosByMakefile = makefile.localizedCaseInsensitiveContains("THEOS") ||
            makefile.contains("tweak.mk") || makefile.contains("application.mk") ||
            makefile.contains("tool.mk") || makefile.contains("bundle.mk")
        let theosByControl = has("control") && (control.contains("Architecture: iphoneos") || control.contains("Depends: firmware"))
        if (has("Makefile") && has("control")) || theosBySource || theosByMakefile || theosByControl {
            systems.insert(.theos); hit(.theos, 70, "theos", "Theos/Logos project signals")
            candidates.insert(.init(system: .theos, toolchain: .theos, command: "make package", confidence: 0.99, reason: "Theos project markers"), at: 0)
        } else if has("Makefile") {
            systems.insert(.make); hit(.custom, 22, "build-system", "Makefile")
            candidates.append(.init(system: .make, toolchain: .custom, command: "make", confidence: 0.78, reason: "Generic Make project"))
        }

        if paths.contains(where: { $0.hasSuffix(".xcodeproj/project.pbxproj") || $0.hasSuffix(".xcworkspace/contents.xcworkspacedata") }) {
            systems.insert(.xcode); hit(.swift, 32, "build-system", "Xcode project/workspace")
            candidates.append(.init(system: .xcode, toolchain: .swift, command: "xcodebuild", confidence: 0.90, reason: "Xcode metadata"))
        }

        let theosType: TheosProjectType? = systems.contains(.theos) ? detectTheosType(makefile: makefile, paths: paths) : nil
        let rootless = makefile.localizedCaseInsensitiveContains("rootless") ||
            control.localizedCaseInsensitiveContains("iphoneos-arm64") ||
            paths.contains { $0.localizedCaseInsensitiveContains("rootless") }

        let best = scores.max { $0.value < $1.value }?.key ?? .custom
        if candidates.isEmpty {
            candidates.append(.init(system: .unknown, toolchain: best, command: defaultCommand(best), confidence: 0.55, reason: "Source-language inference"))
        }
        candidates.sort { $0.confidence > $1.confidence }
        let roots = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })
        return .init(primaryToolchain: best, languages: languages, buildSystems: systems,
                     candidates: candidates, evidence: evidence, theosType: theosType,
                     isRootlessHinted: rootless, isMonorepo: roots.count > 1)
    }

    private static func detectTheosType(makefile: String, paths: [String]) -> TheosProjectType {
        let lower = makefile.lowercased()
        if lower.contains("tweak.mk") || paths.contains(where: { $0.hasSuffix(".xm") }) { return .tweak }
        if lower.contains("application.mk") { return .application }
        if lower.contains("tool.mk") { return .tool }
        if lower.contains("library.mk") { return .library }
        if lower.contains("framework.mk") { return .framework }
        if lower.contains("preference_bundle.mk") { return .preferenceBundle }
        if lower.contains("bundle.mk") { return .bundle }
        return .unknown
    }

    private static func defaultCommand(_ kind: ToolchainKind) -> String {
        switch kind {
        case .clang: return "clang"
        case .swift: return "swift build"
        case .theos: return "make package"
        case .rust: return "cargo build"
        case .go: return "go build ./..."
        case .zig: return "zig build"
        case .python: return "python3"
        case .javascript: return "npm run build"
        case .custom: return "make"
        }
    }
}
