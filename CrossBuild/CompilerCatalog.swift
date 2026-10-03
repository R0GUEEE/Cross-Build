import Foundation

enum CompilerCategory: String, CaseIterable, Identifiable {
    case native = "Native", apple = "Apple", systems = "Systems", runtime = "Runtimes"
    case jvm = "JVM", web = "Web", build = "Build Systems", jailbreak = "Jailbreak"
    var id: String { rawValue }
}

enum InstallMethod: String, Codable {
    case bundled = "Bundled / Embedded"
    case package = "Package Manager"
    case archive = "Imported Archive"
    case custom = "Custom Executable"
}

struct CompilerCatalogItem: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let category: CompilerCategory
    let executable: String
    let languages: [String]
    let markers: [String]
    let buildCommand: String
    let cleanCommand: String
    let testCommand: String
    let packageCommand: String
    let installMethod: InstallMethod
    let packageNames: [String]
    let notes: String
    let icon: String
}

enum CompilerCatalog {
    static let items: [CompilerCatalogItem] = [
        .init(id:"clang",name:"LLVM / Clang",subtitle:"C, C++, Objective-C and Objective-C++",category:.native,executable:"clang",languages:["C","C++","Objective-C","Objective-C++","Assembly"],markers:["Makefile","CMakeLists.txt"],buildCommand:"make",cleanCommand:"make clean",testCommand:"make test",packageCommand:"make package",installMethod:.package,packageNames:["clang","llvm"],notes:"Core native compiler. SDK/sysroot required for Apple targets.",icon:"c.square"),
        .init(id:"swift",name:"Swift",subtitle:"Swift compiler and Swift Package Manager",category:.apple,executable:"swift",languages:["Swift"],markers:["Package.swift"],buildCommand:"swift build",cleanCommand:"swift package clean",testCommand:"swift test",packageCommand:"swift build -c release",installMethod:.archive,packageNames:["swift"],notes:"Toolchain availability depends on compatible iOS build/runtime environment.",icon:"swift"),
        .init(id:"theos",name:"Theos / Logos",subtitle:"iOS jailbreak tweak and package toolchain",category:.jailbreak,executable:"make",languages:["Logos","Objective-C","Objective-C++"],markers:["control","Makefile",".xm",".x"],buildCommand:"make package",cleanCommand:"make clean",testCommand:"make",packageCommand:"make package",installMethod:.archive,packageNames:["theos","ldid","dpkg"],notes:"Supports tweak, app, tool, library and preference bundle projects; rootless/rootful schemes.",icon:"wrench.and.screwdriver"),
        .init(id:"rust",name:"Rust",subtitle:"rustc + Cargo",category:.systems,executable:"cargo",languages:["Rust"],markers:["Cargo.toml","Cargo.lock"],buildCommand:"cargo build",cleanCommand:"cargo clean",testCommand:"cargo test",packageCommand:"cargo build --release",installMethod:.archive,packageNames:["rust","cargo"],notes:"Cross-target standard libraries/linker configuration may be required.",icon:"gearshape.2"),
        .init(id:"go",name:"Go",subtitle:"Go compiler and module tooling",category:.systems,executable:"go",languages:["Go"],markers:["go.mod","go.sum"],buildCommand:"go build ./...",cleanCommand:"go clean",testCommand:"go test ./...",packageCommand:"go build -trimpath ./...",installMethod:.archive,packageNames:["golang"],notes:"Native execution depends on runtime environment and signing constraints.",icon:"shippingbox"),
        .init(id:"zig",name:"Zig",subtitle:"Zig compiler and cross-compilation toolchain",category:.systems,executable:"zig",languages:["Zig","C","C++"],markers:["build.zig","build.zig.zon"],buildCommand:"zig build",cleanCommand:"rm -rf zig-cache zig-out",testCommand:"zig build test",packageCommand:"zig build -Doptimize=ReleaseSafe",installMethod:.archive,packageNames:["zig"],notes:"Useful as a cross-compiler and C/C++ driver.",icon:"bolt"),
        .init(id:"python",name:"Python",subtitle:"CPython runtime and packaging",category:.runtime,executable:"python3",languages:["Python"],markers:["pyproject.toml","requirements.txt","setup.py"],buildCommand:"python3 -m compileall .",cleanCommand:"find . -name __pycache__ -type d -prune -exec rm -rf {} +",testCommand:"python3 -m unittest",packageCommand:"python3 -m build",installMethod:.package,packageNames:["python3","python3-pip"],notes:"Embedded CPython is preferred for normal sideload environments.",icon:"chevron.left.forwardslash.chevron.right"),
        .init(id:"node",name:"Node.js",subtitle:"JavaScript and TypeScript runtime",category:.web,executable:"node",languages:["JavaScript","TypeScript"],markers:["package.json"],buildCommand:"npm run build",cleanCommand:"npm run clean",testCommand:"npm test",packageCommand:"npm pack",installMethod:.package,packageNames:["nodejs","npm"],notes:"Package scripts and native modules may require additional tooling.",icon:"network"),
        .init(id:"typescript",name:"TypeScript",subtitle:"TypeScript compiler",category:.web,executable:"tsc",languages:["TypeScript"],markers:["tsconfig.json"],buildCommand:"npx tsc",cleanCommand:"rm -rf dist",testCommand:"npm test",packageCommand:"npm pack",installMethod:.package,packageNames:["typescript"],notes:"Requires a JavaScript runtime/package manager.",icon:"t.square"),
        .init(id:"java",name:"OpenJDK / Java",subtitle:"Java compiler and runtime",category:.jvm,executable:"javac",languages:["Java"],markers:["pom.xml","build.gradle"],buildCommand:"javac *.java",cleanCommand:"find . -name '*.class' -delete",testCommand:"./gradlew test",packageCommand:"jar cf app.jar *.class",installMethod:.archive,packageNames:["openjdk"],notes:"JVM availability on iOS depends on the execution backend.",icon:"cup.and.saucer"),
        .init(id:"kotlin",name:"Kotlin",subtitle:"Kotlin/JVM compiler",category:.jvm,executable:"kotlinc",languages:["Kotlin"],markers:["build.gradle.kts",".kt"],buildCommand:"./gradlew build",cleanCommand:"./gradlew clean",testCommand:"./gradlew test",packageCommand:"./gradlew assemble",installMethod:.archive,packageNames:["kotlin"],notes:"Typically paired with OpenJDK and Gradle.",icon:"k.square"),
        .init(id:"cmake",name:"CMake",subtitle:"Cross-platform build-system generator",category:.build,executable:"cmake",languages:["C","C++"],markers:["CMakeLists.txt"],buildCommand:"cmake -S . -B build && cmake --build build",cleanCommand:"rm -rf build",testCommand:"ctest --test-dir build",packageCommand:"cmake --build build --config Release",installMethod:.package,packageNames:["cmake"],notes:"Pairs with Ninja or Make and a native compiler.",icon:"hammer"),
        .init(id:"ninja",name:"Ninja",subtitle:"Fast low-level build executor",category:.build,executable:"ninja",languages:[],markers:["build.ninja"],buildCommand:"ninja",cleanCommand:"ninja -t clean",testCommand:"ninja test",packageCommand:"ninja",installMethod:.package,packageNames:["ninja"],notes:"Usually generated by CMake or Meson.",icon:"hare"),
        .init(id:"meson",name:"Meson",subtitle:"Modern native build system",category:.build,executable:"meson",languages:["C","C++"],markers:["meson.build"],buildCommand:"meson setup build && meson compile -C build",cleanCommand:"meson compile -C build --clean",testCommand:"meson test -C build",packageCommand:"meson compile -C build",installMethod:.package,packageNames:["meson","ninja"],notes:"Requires Python and normally Ninja.",icon:"square.stack.3d.up"),
        .init(id:"make",name:"GNU Make",subtitle:"Makefile build executor",category:.build,executable:"make",languages:[],markers:["Makefile","makefile"],buildCommand:"make",cleanCommand:"make clean",testCommand:"make test",packageCommand:"make package",installMethod:.package,packageNames:["make"],notes:"Used by Theos and many native projects.",icon:"hammer.fill"),
        .init(id:"dpkg",name:"dpkg Tooling",subtitle:"Debian package creation for jailbreak projects",category:.jailbreak,executable:"dpkg-deb",languages:[],markers:["control","DEBIAN"],buildCommand:"dpkg-deb --build .",cleanCommand:"rm -rf packages",testCommand:"dpkg-deb --info",packageCommand:"dpkg-deb --build .",installMethod:.package,packageNames:["dpkg"],notes:"Provides .deb packaging; commonly used with Theos.",icon:"shippingbox.fill"),
        .init(id:"ldid",name:"ldid",subtitle:"iOS code-signing utility",category:.jailbreak,executable:"ldid",languages:[],markers:["entitlements.plist"],buildCommand:"ldid -S",cleanCommand:"true",testCommand:"ldid -e",packageCommand:"ldid -S",installMethod:.package,packageNames:["ldid"],notes:"Signing helper for jailbreak/sideload development workflows.",icon:"signature")
    ]
}
