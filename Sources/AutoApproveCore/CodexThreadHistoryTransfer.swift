import Foundation
import CryptoKit
import CSQLite
import Darwin

/// The original 0.169 paginated history database is independent of rollouts.
/// Copy only the selected thread under the original rollout writer leases.
/// A durable before/after digest and an SQLite transaction make a lost commit
/// reply observable without replacing a subsequently changed destination.
enum CodexThreadHistoryTransfer {
    private static let schema = "c4cf7b825df929043b0bd496d5c196eb5fec1ee630f292e6c512f8a00520793a"
    private static let tables = ["thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items"]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static var failure:AppError {.message("페이지형 대화 이력의 원본·목적지·스키마가 달라 이전을 멈췄습니다. 기존 이력은 유지합니다.")}
    private enum Cell:Codable,Equatable {
        case null, integer(Int64), text(String)
    }
    private struct Snapshot:Codable,Equatable {
        let rows:[[[Cell]]]
        var empty:Bool {rows.allSatisfy(\.isEmpty)}
        func digest()throws->String {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            return SHA256.hash(data:try encoder.encode(self)).map{String(format:"%02x",$0)}.joined()
        }
    }
    private struct Intent:Codable,Equatable {
        let threadID:String,sourceHome:String,destinationHome:String,sourceIdentity:String,destinationIdentity:String
        let sourceDigest:String,destinationDigest:String
        let replacingRetired:Bool
    }
    private static func identity(_ path:String,directory:Bool=false)throws->String {
        var info=stat()
        guard lstat(path,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==(directory ? S_IFDIR:S_IFREG),
              directory || info.st_nlink==1,info.st_mode&0o022==0 else{throw failure}
        return "\(info.st_dev):\(info.st_ino)"
    }
    private final class Database {
        let db:OpaquePointer,path:String,identity:String
        private var closed=false
        init(home:String,writable:Bool)throws {
            _=try CodexThreadHistoryTransfer.identity(home,directory:true)
            guard let resolved=realpath(home,nil) else{throw failure}
            let selected=String(cString:resolved);free(resolved)
            path=selected+"/thread_history_1.sqlite";identity=try CodexThreadHistoryTransfer.identity(path)
            var pointer:OpaquePointer?
            let flags=(writable ? SQLITE_OPEN_READWRITE:SQLITE_OPEN_READONLY)|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW
            guard sqlite3_open_v2(path,&pointer,flags,nil)==SQLITE_OK,let pointer else{sqlite3_close(pointer);throw failure}
            db=pointer;sqlite3_busy_timeout(db,1000);sqlite3_limit(db,SQLITE_LIMIT_LENGTH,8*1024*1024)
            do {
                try execute("PRAGMA trusted_schema=OFF")
                if writable {try execute("PRAGMA synchronous=FULL");try execute("PRAGMA fullfsync=ON")}
                let objects=try query("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name")
                var lines=try objects.map {row->String in
                    guard row.count==3,case .text(let type)=row[0],case .text(let name)=row[1],case .text(let sql)=row[2] else{throw failure}
                    return type+"|"+name+"|"+sql.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").lowercased()
                }
                lines += try query("SELECT version,success,hex(checksum) FROM _sqlx_migrations ORDER BY version").map {row->String in
                    guard row.count==3,case .integer(let version)=row[0],case .integer(let success)=row[1],case .text(let checksum)=row[2] else{throw failure}
                    return "\(version)|\(success)|\(checksum)"
                }
                let digest=SHA256.hash(data:Data(lines.joined(separator:"\n").utf8)).map{String(format:"%02x",$0)}.joined()
                guard digest==schema else{throw failure}
                try check()
            } catch {close();throw error}
        }
        deinit {close()}
        private func close(){if !closed{closed=true;sqlite3_close(db)}}
        func check()throws {guard try CodexThreadHistoryTransfer.identity(path)==identity else{throw failure}}
        private func statement(_ sql:String,_ cells:[Cell])throws->OpaquePointer {
            var pointer:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&pointer,nil)==SQLITE_OK,let pointer else{sqlite3_finalize(pointer);throw failure}
            do {
                for (offset,value) in cells.enumerated() {
                    let index=Int32(offset+1),result:Int32
                    switch value {
                    case .null:result=sqlite3_bind_null(pointer,index)
                    case .integer(let value):result=sqlite3_bind_int64(pointer,index,value)
                    case .text(let value):result=value.withCString{sqlite3_bind_text(pointer,index,$0,Int32(value.utf8.count),transient)}
                    }
                    guard result==SQLITE_OK else{throw failure}
                }
                return pointer
            } catch {sqlite3_finalize(pointer);throw error}
        }
        func execute(_ sql:String,_ cells:[Cell]=[])throws {
            let value=try statement(sql,cells);defer{sqlite3_finalize(value)}
            guard sqlite3_step(value)==SQLITE_DONE else{throw failure}
        }
        func query(_ sql:String,_ cells:[Cell]=[])throws->[[Cell]] {
            let value=try statement(sql,cells);defer{sqlite3_finalize(value)}
            var rows=[[Cell]](),size=0
            while true {
                let step=sqlite3_step(value);if step==SQLITE_DONE{return rows}
                guard step==SQLITE_ROW,rows.count<100_000 else{throw failure}
                var row=[Cell]()
                for column in 0..<sqlite3_column_count(value) {
                    switch sqlite3_column_type(value,column) {
                    case SQLITE_NULL:row.append(.null)
                    case SQLITE_INTEGER:row.append(.integer(sqlite3_column_int64(value,column)))
                    case SQLITE_TEXT:
                        let count=Int(sqlite3_column_bytes(value,column));size+=count
                        guard size<=64*1024*1024,let bytes=sqlite3_column_text(value,column),
                              let text=String(data:Data(bytes:bytes,count:count),encoding:.utf8) else{throw failure}
                        row.append(.text(text))
                    default:throw failure
                    }
                }
                rows.append(row)
            }
        }
        func snapshot(_ thread:String)throws->Snapshot {
            var selected=[[[Cell]]]()
            for table in tables {
                let order=table=="thread_history_projection_state" ? "thread_id":table=="thread_realtime_items" ? "thread_id,item_id":table=="thread_turns" ? "thread_id,turn_id":"thread_id,turn_id,item_id"
                selected.append(try query("SELECT * FROM \(table) WHERE thread_id=? ORDER BY \(order)",[.text(thread)]))
            }
            return .init(rows:selected)
        }
        func install(_ source:Snapshot,thread:String)throws {
            for (index,table) in tables.enumerated() {
                try execute("DELETE FROM \(table) WHERE thread_id=?",[.text(thread)])
                for row in source.rows[index] {
                    guard row.first == .text(thread) else{throw failure}
                    let placeholders=Array(repeating:"?",count:row.count).joined(separator:",")
                    try execute("INSERT INTO \(table) VALUES (\(placeholders))",row)
                }
            }
        }
    }
    static func install(id:UUID,sourceHome:String,destinationHome:String,threadID:String,replacingRetired:Bool,
                        store:AuditStore,checkpoint:()throws->Void)throws {
        guard UUID(uuidString:threadID)?.uuidString.lowercased()==threadID,sourceHome != destinationHome else{throw failure}
        let sourcePath=sourceHome+"/thread_history_1.sqlite"
        var info=stat()
        if lstat(sourcePath,&info) != 0 {guard errno==ENOENT else{throw failure};return}
        let source=try Database(home:sourceHome,writable:false)
        let destination=try Database(home:destinationHome,writable:true)
        try source.execute("BEGIN");defer{try? source.execute("ROLLBACK")}
        let snapshot=try source.snapshot(threadID),digest=try snapshot.digest()
        let key="codexThreadHistoryTransfer:"+id.uuidString.lowercased()
        let intent:Intent
        if let saved=store.value(key) {
            intent=try JSONDecoder().decode(Intent.self,from:Data(saved.utf8))
            guard intent.threadID==threadID,intent.sourceHome==sourceHome,intent.destinationHome==destinationHome,
                  intent.sourceIdentity==source.identity,intent.destinationIdentity==destination.identity,
                  intent.sourceDigest==digest,intent.replacingRetired==replacingRetired else{throw failure}
        } else {
            // Capture the exact selected destination before any overwrite.
            // A new target must be empty or already equal; a return requires
            // the caller's verified retirement/ownership proof as well.
            try destination.execute("BEGIN");let before:Snapshot
            do {before=try destination.snapshot(threadID);try destination.execute("COMMIT")}
            catch {try? destination.execute("ROLLBACK");throw error}
            let previous=try before.digest()
            guard replacingRetired || before.empty || previous==digest else{throw failure}
            intent = .init(threadID:threadID,sourceHome:sourceHome,destinationHome:destinationHome,
                sourceIdentity:source.identity,destinationIdentity:destination.identity,sourceDigest:digest,
                destinationDigest:previous,replacingRetired:replacingRetired)
            try store.set(key,String(decoding:try JSONEncoder().encode(intent),as:UTF8.self))
        }
        try checkpoint();try source.check();try destination.check()
        try destination.execute("BEGIN IMMEDIATE");var committed=false
        defer{if !committed{try? destination.execute("ROLLBACK")}}
        let current=try destination.snapshot(threadID).digest()
        guard current==intent.sourceDigest || current==intent.destinationDigest else{throw failure}
        if current != intent.sourceDigest {try destination.install(snapshot,thread:threadID)}
        guard try destination.snapshot(threadID)==snapshot else{throw failure}
        try checkpoint();try source.check();try destination.check()
        try destination.execute("COMMIT");committed=true
        try checkpoint()
    }
    static func completed(id:UUID,sourceHome:String,destinationHome:String,threadID:String,store:AuditStore)throws->Bool {
        var info=stat()
        if lstat(sourceHome+"/thread_history_1.sqlite",&info) != 0 {guard errno==ENOENT else{throw failure};return true}
        guard let saved=store.value("codexThreadHistoryTransfer:"+id.uuidString.lowercased()) else{return false}
        let intent=try JSONDecoder().decode(Intent.self,from:Data(saved.utf8))
        let target=try Database(home:destinationHome,writable:false)
        guard intent.threadID==threadID,intent.sourceHome==sourceHome,intent.destinationHome==destinationHome,
              intent.destinationIdentity==target.identity else{throw failure}
        try target.execute("BEGIN");defer{try? target.execute("ROLLBACK")}
        let observed=try target.snapshot(threadID).digest()
        try target.check()
        return observed==intent.sourceDigest
    }
    static func validateHomeIfPresent(_ home:String)throws {
        var info=stat()
        if lstat(home+"/thread_history_1.sqlite",&info) != 0 {guard errno==ENOENT else{throw failure};return}
        let connection=try Database(home:home,writable:false)
        try connection.check()
    }
}
