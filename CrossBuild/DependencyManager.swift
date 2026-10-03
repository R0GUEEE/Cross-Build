import Foundation

struct DependencyEcosystem: Identifiable, Sendable {
    let id:String
    let name:String
    let manifest:String
    let resolveCommand:String
    let updateCommand:String
}

enum DependencyManager {
    static let ecosystems:[DependencyEcosystem] = [
        .init(id:"swiftpm",name:"Swift Package Manager",manifest:"Package.swift",resolveCommand:"swift package resolve",updateCommand:"swift package update"),
        .init(id:"cargo",name:"Cargo",manifest:"Cargo.toml",resolveCommand:"cargo fetch",updateCommand:"cargo update"),
        .init(id:"go",name:"Go Modules",manifest:"go.mod",resolveCommand:"go mod download",updateCommand:"go get -u ./..."),
        .init(id:"npm",name:"npm",manifest:"package.json",resolveCommand:"npm install",updateCommand:"npm update"),
        .init(id:"python",name:"Python",manifest:"requirements.txt",resolveCommand:"python3 -m pip install -r requirements.txt",updateCommand:"python3 -m pip install -U -r requirements.txt"),
        .init(id:"cmake",name:"CMake",manifest:"CMakeLists.txt",resolveCommand:"cmake -S . -B build",updateCommand:"cmake -S . -B build"),
        .init(id:"meson",name:"Meson",manifest:"meson.build",resolveCommand:"meson setup build",updateCommand:"meson setup --reconfigure build")
    ]

    static func detected(in files:[WorkspaceFile]) -> [DependencyEcosystem] {
        let names=Set(files.map{$0.name})
        return ecosystems.filter{names.contains($0.manifest)}
    }
}
