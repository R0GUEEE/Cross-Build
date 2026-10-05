// swift-tools-version: 6.0
//
// Cross Build as a SwiftPM package, for building with xtool instead of Xcode.
//
// This is a translation of project.yml. The mapping, construct by construct:
//
//   XcodeGen                          SwiftPM
//   ---------------------------------------------------------------
//   target type: application          .executableTarget + xtool.yml
//   target type: library.static       .target (C/C++), publicHeadersPath
//   dependencies: framework: <xc>     .binaryTarget
//   buildPhase: resources             resources: [.copy(...)]
//   HEADER_SEARCH_PATHS               cSettings .headerSearchPath
//   GCC_PREPROCESSOR_DEFINITIONS      cSettings .define
//   OTHER_CFLAGS                      cSettings .unsafeFlags
//   OTHER_LDFLAGS                     linkerSettings .unsafeFlags
//
// Three things are deliberately NOT expressed here, because SwiftPM has no way
// to say them and pretending otherwise would be worse than saying so:
//
//   1. XcodeGen's `info:` block (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace,
//      UILaunchScreen, CFBundleDisplayName). xtool.yml carries the bundle metadata
//      instead; the two plist keys that matter for the workspace being visible in
//      Files.app are set there.
//
//   2. The Meson-built engine (libish_emu.a, libish.a, libfakefs.a) is not a
//      module and has no header layout SwiftPM can import, so it stays where it
//      was: a link path and libraries in linkerSettings, exactly what
//      OTHER_LDFLAGS did. It must be built first -- Tools/build-local.sh does
//      that, or CI's "Build iOS Linux engine" step.
//
//   3. `ASSETCATALOG_COMPILER_APPICON_NAME` / the .xcassets compilation. xtool
//      takes an icon as a plain PNG via xtool.yml rather than compiling an
//      asset catalogue.

import PackageDescription

let package = Package(
    name: "CrossBuild",
    platforms: [.iOS(.v16)],
    products: [
        // xtool packages the executable product into the .app.
        .executable(name: "CrossBuild", targets: ["CrossBuild"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        // MARK: - C shims
        //
        // Each is a module map beside its header, which is what the Xcode targets
        // did with Module/module.modulemap and why they deliberately did NOT set
        // DEFINES_MODULE (that made clang see two copies of the map and report
        // "redefinition of module 'CrossBuildClang'").

        .target(
            name: "CrossBuildClang",
            path: "Native/CrossBuildClang",
            publicHeadersPath: "Module",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),

        .target(
            name: "CrossBuildPython",
            path: "Native/CrossBuildPython",
            publicHeadersPath: "Module"
        ),

        // The engine shim includes ios-linuxkit's own xX_main_Xx.h and drives the
        // boot sequence, so it needs the vendored tree on its header path and the
        // same GUEST_ARM64 define the engine is built with.
        //
        // _XOPEN_SOURCE and _DARWIN_C_SOURCE must come as a pair: the engine's
        // headers pull in the SDK's ucontext.h, which refuses to declare the
        // deprecated ucontext routines without _XOPEN_SOURCE -- and defining
        // _XOPEN_SOURCE alone pins __DARWIN_C_LEVEL lower and hides
        // fstatat/makedev/DT_*. This pair cost real time to find.
        .target(
            name: "CrossBuildLinux",
            path: "Native/CrossBuildLinux",
            publicHeadersPath: "Module",
            cSettings: [
                .define("GUEST_ARM64", to: "1"),
                .define("_XOPEN_SOURCE", to: "600"),
                .define("_DARWIN_C_SOURCE"),
                .headerSearchPath("../../Vendor/linuxkit"),
                .headerSearchPath("../../Vendor/linuxkit/build-ios")
            ]
        ),

        // MARK: - Embedded CPython
        //
        // The support package ships this with its own Info.plist, which installd
        // insists on for an embedded framework. It is produced by the vendoring
        // step (Tools/build-local.sh), not committed.
        .binaryTarget(
            name: "Python",
            path: "Vendor/Python/Python.xcframework"
        ),

        // MARK: - The app
        .executableTarget(
            name: "CrossBuild",
            dependencies: [
                "CrossBuildClang",
                "CrossBuildLinux",
                "CrossBuildPython",
                "Python",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "CrossBuild",
            // The asset catalogue is replaced by xtool.yml's icon; the Python icon
            // script is a build-time tool, not a source file.
            exclude: [
                "Resources/Toolchains",
                "Assets.xcassets"
            ],
            // Deliberately NO `resources:` here.
            //
            // SwiftPM would put them in a generated <Target>_<Target>.bundle and
            // expect Bundle.module, but the app reads fakefs-root/, python/,
            // app/ and Toolchains/ through Bundle.main.resourceURL -- the app
            // bundle root. They are declared in xtool.yml's top-level
            // `resources:` instead, which is what places files at the root.
            // As SwiftPM resources every one of those paths would resolve to
            // nothing at runtime.
            swiftSettings: [
                // The app was built at Swift 5 language mode; Swift 6 strict
                // concurrency would flag things that are not bugs here.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // The Meson-built engine. Built before this package, not a target.
                .unsafeFlags([
                    "-L.Vendor/linuxkit/build-ios",
                    "-lish_emu", "-lish", "-lfakefs",
                    "-lsqlite3",
                    "-ObjC"
                ])
            ]
        )
    ]
)
