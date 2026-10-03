import Foundation

struct SDKRecord: Identifiable, Sendable {
    let id:String
    let name:String
    let path:String
    let kind:String
}

enum SDKManager {
    static func discover() -> [SDKRecord] {
        var result:[SDKRecord]=[]
        for url in IOSSDKDiscovery.bundledSDKs() {
            result.append(.init(id:url.path,name:url.deletingPathExtension().lastPathComponent,path:url.path,kind:"Apple SDK"))
        }
        if let root=LinuxGuestEngine.bundledRootPath {
            result.append(.init(id:"linux-root",name:"Alpine Linux Guest",path:root,kind:"Linux sysroot"))
        }
        return result
    }
}
