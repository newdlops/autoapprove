import Foundation
import Darwin
@testable import AutoApproveCore

@main struct CredentialFileCheck {
    static func main() {
        do {try run()}
        catch {
            FileHandle.standardError.write(Data("Owned credential witness rejected\n".utf8))
            exit(1)
        }
    }
    static func run()throws {
        let args=CommandLine.arguments
        func owned(_ home:String)throws {
            // Foundation may spell /private/tmp as /tmp when standardizing a
            // selected path. Check its actual physical location, not the alias.
            guard let pointer=realpath(home,nil) else{throw AppError.message("Owned auth-isolation fixture required")}
            defer{free(pointer)}
            guard String(cString:pointer).hasPrefix("/private/tmp/aa-auth-isolation-") else{throw AppError.message("Owned auth-isolation fixture required")}
        }
        switch args.dropFirst().first {
        case "capture":
            guard args.count==4 else{throw AppError.message("Two owned homes required")}
            try owned(args[2]);try owned(args[3])
            let a=try CodexCredentialFile.capture(home:args[2]),b=try CodexCredentialFile.capture(home:args[3])
            try CodexCredentialFile.requireIndependent(a,b)
            print(String(decoding:try JSONEncoder().encode([a,b]),as:UTF8.self))
        case "verify":
            let value=try JSONDecoder().decode(CodexCredentialFile.self,from:FileHandle.standardInput.readDataToEndOfFile())
            try owned(value.selectedHome);try owned(value.physicalHome);try value.verifyCurrent()
            print("{\"verified\":true}")
        default:throw AppError.message("Unknown owned credential check")
        }
    }
}
