import Foundation
import Darwin
import CryptoKit

@main struct SelectionChecks {
    static func entry(_ pid: Int32, _ parent: Int32, _ name: String, tty: Bool = true) -> kinfo_proc {
        var value = kinfo_proc()
        value.kp_proc.p_pid = pid; value.kp_eproc.e_ppid = parent; value.kp_eproc.e_tdev = tty ? 16 << 24 : -1
        withUnsafeMutableBytes(of: &value.kp_proc.p_comm) { target in
            for (index, byte) in name.utf8.prefix(target.count-1).enumerated() { target[index] = byte }
        }
        return value
    }
    static func reference(_ entries: [kinfo_proc]) -> [Int] {
        let candidates = entries.compactMap { entry -> Int32? in
            let bytes = withUnsafeBytes(of: entry.kp_proc.p_comm) { Array($0.prefix { $0 != 0 }) }
            let name = String(decoding: bytes, as: UTF8.self).lowercased()
            let candidate = name == "codex" || name == "claude" || entry.kp_eproc.e_tdev != -1 &&
                (name == "node" || bytes.first.map { (48...57).contains($0) } == true)
            return candidate ? entry.kp_proc.p_pid : nil
        }
        var parents: [Int32:Int32] = [:]
        for entry in entries where parents[entry.kp_proc.p_pid] == nil { parents[entry.kp_proc.p_pid] = entry.kp_eproc.e_ppid }
        var selected = Set<Int32>()
        for candidate in candidates {
            var current = candidate
            for _ in 0..<60 where current > 0 && selected.insert(current).inserted {
                guard let parent = parents[current] else { break }; current = parent
            }
        }
        return entries.indices.filter { selected.contains(entries[$0].kp_proc.p_pid) }
    }
    static func main() async throws {
        var seed: UInt64 = 0x170c0de, cases = 0, selected = 0, hash = SHA256()
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        func check(_ entries: [kinfo_proc]) throws {
            let expected = reference(entries), actual = try NativeProcessReader.sessionIndices(entries)
            precondition(actual == expected,"Selection changed at graph \(cases)")
            precondition(actual == actual.sorted() && Set(actual).count == actual.count)
            cases += 1; selected += actual.count
            hash.update(data:Data((String(entries.count)+":"+actual.map(String.init).joined(separator:",")+";").utf8))
        }
        try check([]);try check([entry(0,0,"codex")]);try check([entry(1,0,"launchd",tty:false)])
        for length in [1,2,59,60,61,62,120,1000] {
            var chain: [kinfo_proc] = []
            for index in 0..<length {
                let pid = Int32(index) + 1, parent = Int32(index) + 2
                let name = index == 0 ? "codex" : "worker"
                chain.append(entry(pid,parent,name))
            }
            try check(chain);try check(Array(chain.reversed()))
            var cycle = chain;cycle[cycle.count-1].kp_eproc.e_ppid = 1;try check(cycle)
            var duplicate = chain;duplicate += [entry(1,0,"worker"),entry(Int32(length+2),1,"claude")];try check(duplicate)
        }
        let names = ["codex","Codex","CODEX","claude","CLAUDE","node","Node","2.1.0","9worker","worker","codex-other","","코덱스","ℂodex"]
        for _ in 0..<3000 {
            let count = Int(next()%240), boundary = Int32(count+12)
            var entries: [kinfo_proc] = []
            for index in 0..<count {
                let pid = next()%9 == 0 ? Int32(next()%UInt64(max(1,count))) : Int32(index+1)
                let parent = Int32(next()%UInt64(boundary))-2
                let name = names[Int(next()%UInt64(names.count))]
                entries.append(entry(pid,parent,name,tty:next()%3 != 0))
            }
            try check(entries)
        }
        let task = Task.detached { () throws -> [Int] in
            while !Task.isCancelled { await Task.yield() }
            return try NativeProcessReader.sessionIndices([entry(1,0,"codex")])
        }
        task.cancel()
        do { _ = try await task.value;preconditionFailure("Cancellation was ignored") } catch is CancellationError { }
        print("SELECTION "+String(cases)+" cases "+String(selected)+" selected indices; cancellation preserved; sha256 "+hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
}
