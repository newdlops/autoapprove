import Foundation
import Darwin
@testable import AutoApproveCore

@main struct MigrationJournalCrashCheck {
    static func main() {
        do{try run()}catch{FileHandle.standardError.write(Data(error.localizedDescription.utf8));exit(1)}
    }
    static func run()throws {
        let a=CommandLine.arguments
        guard a.count==4,a[1].hasPrefix("/private/tmp/aa-migration-crash-"),UUID(uuidString:a[2]) != nil else{throw AppError.message("Owned crash fixture arguments required")}
        let root=a[1],id=a[2],mode=a[3]
        let store=try AuditStore(path:root+(mode=="foreign" ? "/foreign.sqlite":"/audit.sqlite")),journal=try CodexMigrationJournal(store:store)
        if mode=="create" || mode=="foreign" {
            let record=try journal.create(id:id,homes:[root+"/b",root+"/a"],payload:Data("reserved".utf8))
            let result:[String:Any]=["revision":record.revision,"homes":record.homes.map{["path":$0.path,"identity":$0.identity]}]
            print(String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self));return
        }
        if mode=="inspect" {
            guard let value=try journal.load(id:id) else{throw AppError.message("Owned journal missing")}
            print("{\"revision\":\(value.record.revision),\"consistent\":\(value.consistent),\"payload\":\"\(String(decoding:value.record.payload,as:UTF8.self))\"}");return
        }
        let record=try journal.repair(id:id)
        if mode=="repair" {print("{\"revision\":\(record.revision),\"consistent\":true}");return}
        if mode=="complete" {
            _=try journal.save(id:id,payload:Data("complete".utf8),expectedRevision:record.revision,terminal:true)
            try journal.release(id:id);return
        }
        guard ["crash-central","crash-first-mirror","crash-synced"].contains(mode) else{throw AppError.message("Unknown owned crash mode")}
        let order=record.homes.sorted{$0.identity<$1.identity}
        if mode != "crash-synced" {
            let blocked=mode=="crash-central" ? order:Array(order.suffix(1))
            for home in blocked{try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:home.path+"/.autoapprove-migrations")}
            do{_=try journal.save(id:id,payload:Data("attempted".utf8),expectedRevision:record.revision)}catch{_exit(70)}
            throw AppError.message("Owned mirror fault did not occur")
        }
        _=try journal.save(id:id,payload:Data("attempted".utf8),expectedRevision:record.revision)
        _exit(71) // Intentional abrupt exit: no Swift defers or deinitializers.
    }
}
