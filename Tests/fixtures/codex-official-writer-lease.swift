import Foundation
@testable import AutoApproveCore

@main struct OfficialWriterLeaseCheck {
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count>=4,args[1].hasPrefix("/private/tmp/aa-official-writer-") else{throw AppError.message("Owned home and scope required")}
        let home=args[1],mode=args[2],ids=Array(args.dropFirst(3))
        if mode=="busy" || mode=="invalid" {
            do {
                let lease=try CodexOfficialWriterLease(home:home,threadIDs:ids);lease.close()
                throw AppError.message("Unexpected lease acceptance")
            }catch {
                guard !error.localizedDescription.contains("Unexpected") else{throw error}
                print("rejected");return
            }
        }
        guard mode=="hold" else{throw AppError.message("Unknown owned mode")}
        let lease=try CodexOfficialWriterLease(home:home,threadIDs:ids)
        defer{lease.close()}
        print("held");fflush(stdout)
        while let line=readLine() {
            if line=="verify" {try lease.verifyUnchanged();print("unchanged");fflush(stdout)}
            else if line=="verify-stale" {
                do {try lease.verifyUnchanged();throw AppError.message("Replaced lock was accepted")}
                catch {guard !error.localizedDescription.contains("Replaced lock was accepted") else{throw error}}
                print("stale");fflush(stdout)
            }
            else if line=="release" {lease.close();print("released");return}
            else{throw AppError.message("Unexpected fixture command")}
        }
    }
}
