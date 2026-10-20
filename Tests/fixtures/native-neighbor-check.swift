import Foundation
import Darwin
#if CORE_NEIGHBOR_CHECK
import AutoApproveCore
#endif

@main struct NativeNeighborCheck {
    static var checks = 0
    static func expect(_ value: Bool, _ detail: String) throws {
        guard value else { throw NSError(domain:detail,code:1) }; checks += 1
    }
    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw NSError(domain:"Malformed input accepted",code:1)
    }
    static func record(ip: [UInt8] = [192,168,43,9], index: UInt16 = 4, hardware: [UInt8] = [1,2,3,4,5,6],
                       name: [UInt8] = [], selector: [UInt8] = [], zeroMask: Bool = false, extraAddress: Bool = false) -> Data {
        var destination = Data(repeating:0,count:20); destination[0] = 20; destination[1] = UInt8(AF_INET)
        destination.replaceSubrange(4..<8,with:ip)
        var link = Data([UInt8(8+name.count+hardware.count+selector.count),UInt8(AF_LINK),0,0,6,UInt8(name.count),UInt8(hardware.count),UInt8(selector.count)])
        var index = index; withUnsafeBytes(of:&index) { link.replaceSubrange(2..<4,with:$0) }
        link.append(contentsOf:name+hardware+selector)
        while link.count % 4 != 0 { link.append(0) }
        var payload = destination+link
        if zeroMask { payload.append(contentsOf:[0,0,0,0]) }
        if extraAddress { payload.append(Data([16,UInt8(AF_INET)]+Array(repeating:0,count:14))) }
        var header = rt_msghdr(); header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size+payload.count)
        header.rtm_version = UInt8(RTM_VERSION); header.rtm_type = UInt8(RTM_GET); header.rtm_index = index
        header.rtm_flags = RTF_LLINFO; header.rtm_addrs = RTA_DST | RTA_GATEWAY
        if zeroMask { header.rtm_addrs |= RTA_NETMASK }
        if extraAddress { header.rtm_addrs |= RTA_IFA }
        return withUnsafeBytes(of:&header) { Data($0) } + payload
    }
    static func parse(_ bytes: Data) throws -> [NativeNeighborCache.Entry] {
        try NativeNeighborCache.entries(from:bytes,interfaceName:{ [4:"en0",7:"en7",9:"utun4"][$0] })
    }
    static func run() throws {
        let regular = record(), header = MemoryLayout<rt_msghdr>.size
        try expect(try parse(Data()).isEmpty,"Empty table")
        try expect(try parse(regular) == [.init(address:"192.168.43.9",interfaceName:"en0",broadcast:false)],"Exact IPv4 and interface")
        try expect(try parse(record(name:Array("en0".utf8),selector:[1,2],zeroMask:true,extraAddress:true)).count == 1,"Variable link lengths, four-byte padding, zero mask and IFA")
        try expect(try parse(record(hardware:[])).isEmpty,"Incomplete neighbor")
        try expect(try parse(record(hardware:Array(repeating:255,count:6))).first?.broadcast == true,"Six-byte broadcast")
        try expect(try parse(record(hardware:[255,255,255])).first?.broadcast == false,"Preserve the legacy exact six-byte exclusion")
        try expect(try parse(record(index:400)).isEmpty,"Unknown interface index")
        let alignedSlice = (Data([99])+regular).dropFirst()
        try expect(try parse(alignedSlice) == parse(regular),"Unaligned Data slice")
        try rejects { _ = try parse(Data([1])) }
        try rejects { _ = try parse(regular.dropLast()) }
        try rejects { _ = try parse(regular+Data([0])) }
        for count in [0,MemoryLayout<rt_msghdr>.size-1,regular.count+1] {
            var value = regular, length = UInt16(count)
            withUnsafeBytes(of:&length) { value.replaceSubrange(0..<2,with:$0) }
            try rejects { _ = try parse(value) }
        }
        var version = regular; version[2] = UInt8(RTM_VERSION+1); try rejects { _ = try parse(version) }
        var type = regular; type[3] = UInt8(RTM_ADD); try rejects { _ = try parse(type) }
        var missing = regular, flags = Int32(RTA_DST)
        let flagsOffset = MemoryLayout<rt_msghdr>.offset(of:\.rtm_addrs)!
        withUnsafeBytes(of:&flags) { missing.replaceSubrange(flagsOffset..<(flagsOffset+4),with:$0) }
        try rejects { _ = try parse(missing) }
        flags = Int32(1<<15); withUnsafeBytes(of:&flags) { missing.replaceSubrange(flagsOffset..<(flagsOffset+4),with:$0) }
        try rejects { _ = try parse(missing) }
        var link = regular; link[header+20+6] = 255; try rejects { _ = try parse(link) }
        var short = regular; short[header] = 0; try rejects { _ = try parse(short) }
        var family = regular; family[header+1] = UInt8(AF_INET6); try expect(try parse(family).isEmpty,"Other address family")
        family = regular; family[header+20+1] = UInt8(AF_INET); try expect(try parse(family).isEmpty,"Other link family")
        var repeated = Data(); for _ in 0..<2048 { repeated.append(regular) }
        var lookups = 0
        let entries = try NativeNeighborCache.entries(from:repeated+Data([0]),interfaceName:{ _ in lookups += 1; return "en0" })
        try expect(entries.count == 2048 && lookups == 1,"Exact 2048-row budget and one lookup per index")
        lookups = 0
        try expect(try NativeNeighborCache.entries(from:regular+regular,interfaceName:{ _ in lookups += 1; return nil }).isEmpty && lookups == 1,"Missing name also resolved once")
        try expect(try NativeNeighborCache.entries(from:regular,interfaceName:{_ in "en7"}).first?.interfaceName == "en7","Each read refreshes interface names")
        var calls = 0
        let empty = try NativeNeighborCache.snapshot { _,size in calls += 1; size = 0 }
        try expect(empty.isEmpty && calls == 1,"Empty sysctl does not allocate or retry")
        calls = 0
        let grown = try NativeNeighborCache.snapshot { output,size in
            calls += 1
            if output == nil { size = calls == 1 ? 4 : regular.count; return }
            if calls == 2 { throw POSIXError(.ENOMEM) }
            regular.withUnsafeBytes { output!.copyMemory(from:$0.baseAddress!,byteCount:$0.count) }; size = regular.count
        }
        try expect(grown == regular && calls == 4,"Growth retries with a fresh size and complete bytes")
        calls = 0
        try rejects { _ = try NativeNeighborCache.snapshot { output,size in calls += 1; if output == nil { size = 4 } else { throw POSIXError(.ENOMEM) } } }
        try expect(calls == 6,"At most three attempts")
        for invalidSize in [-1,NativeNeighborCache.maximumBytes+1] {
            calls = 0
            try rejects { _ = try NativeNeighborCache.snapshot { output,size in calls += 1; size = invalidSize } }
            try expect(calls == 1,"Bad estimates cannot allocate")
        }
        try rejects { _ = try NativeNeighborCache.snapshot { output,size in if output == nil { size = 4 } else { size = 5 } } }
        try rejects { _ = try NativeNeighborCache.snapshot { _,_ in throw POSIXError(.EPERM) } }
        var liveChecks = 0
#if CORE_NEIGHBOR_CHECK
        if CommandLine.arguments.contains("--live") {
            let interfaces = RemoteLAN.interfaces(refresh:true)
            func urls(_ entries: [NativeNeighborCache.Entry]) -> [String] {
                let text = entries.map { "? (\($0.address)) at \($0.broadcast ? "ff:ff:ff:ff:ff:ff" : "1:2:3:4:5:6") on \($0.interfaceName)" }.joined(separator:"\n")
                return RemoteLAN.neighborURLs(from:text,interfaces:interfaces)
            }
            for _ in 0..<3 {
                let before = urls(try NativeNeighborCache.read())
                let legacy = try CommandRunner.run("/usr/sbin/arp",["-an"],timeout:1)
                try expect(legacy.status == 0,"Read-only legacy oracle succeeds")
                let expected = RemoteLAN.neighborURLs(from:legacy.output,interfaces:interfaces)
                let actual = RemoteLAN.neighborURLs()
                let after = urls(try NativeNeighborCache.read())
                try expect(before == after && actual == before && actual == expected,"Stable live snapshot and actual Core URL order agree")
                liveChecks += 1
            }
        }
#endif
        var output: [String:Any] = [:]
        output["passed"] = true; output["checks"] = checks; output["liveParityRounds"] = liveChecks
        output["terminalInputs"] = 0; output["networkMutations"] = 0; output["neighborDataRetained"] = false
        print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
    }
    static func main() {
        do { try run() } catch { fputs("Native neighbor check failed: \(error)\n",stderr); exit(1) }
    }
}
