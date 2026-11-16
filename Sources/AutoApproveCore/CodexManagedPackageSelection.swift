import Foundation
import Darwin

/// The official daemon CLI may invoke its managed binary even for a version
/// query. Verify the selected package before invoking daemon subcommands.
enum CodexManagedPackageSelection {
    static func verify(home:String,executable:@Sendable(String)throws->Void)throws {
        func exists(_ path:String)throws->Bool {
            var info=stat()
            if lstat(path,&info)==0{return true}
            guard errno==ENOENT else{throw AppError.message(CodexFeatureSupport.legacyRuntimeUnavailable)}
            return false
        }
        var root=home+"/packages/app-server-daemon"
        if try !exists(root+"/current") {
            for (name,artifacts) in [
                ("app-server-daemon",["daemon.pid","daemon.stderr.log","daemon-updater.pid","daemon-updater.stderr.log"]),
                ("standalone",["app-server.pid","app-server.stderr.log","app-server-updater.pid","app-server-updater.stderr.log"])
            ] {
                if try artifacts.contains(where:{try exists(home+"/app-server-daemon/"+$0)}) {
                    root=home+"/packages/"+name;break
                }
            }
        }
        guard try exists(root+"/current") else{return}
        let packaged=root+"/current/bin/codex",legacy=root+"/current/codex"
        let selected=try exists(packaged) ? packaged:legacy
        guard FileManager.default.isExecutableFile(atPath:selected) else{throw AppError.message(CodexFeatureSupport.legacyRuntimeUnavailable)}
        do {try executable(selected)}
        catch {throw AppError.message(CodexFeatureSupport.legacyRuntimeUnavailable)}
    }
}
