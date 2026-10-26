import Foundation
import CoreFoundation
import Darwin
import AutoApproveCore

@main struct TypedRouteCheck {
    enum Failure: Error { case mismatch(String) }
    static var cases = 0, calls = 0
    static var state: UInt64 = 0x123456789abcdef
    static func require(_ condition: Bool, _ reason: String) throws { if !condition { throw Failure.mismatch(reason) } }
    static func random(_ limit: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407;return Int((state >> 32) % UInt64(limit)) }
    // Exact released pool route expression,not a replacement implementation.
    @inline(never) static func legacy(_ interfaces: [RemoteLANInterface]) -> String {
        calls += 1
        return interfaces.map { "\($0.name):\($0.address):\($0.netmask):\($0.kind)" }.sorted().joined(separator:"|")
    }
    @inline(never) static func current(_ interfaces: [RemoteLANInterface]) -> [RemoteLANInterface] {
        calls += 1
        return RemoteHTTPReadPool.routeKey(interfaces)
    }
    static func canonical(_ count: Int, variant: Int = 0) -> [RemoteLANInterface] {
        (0..<count).map { index in
            RemoteLANInterface(name:String(format:"en%02d",index),address:"10.\(variant+1).\(index).2",netmask:"255.255.255.0",kind:index < (count+1)/2 ? .wifi : .ethernet)
        }
    }
    static func shuffled(_ rows: [RemoteLANInterface]) -> [RemoteLANInterface] {
        var result=rows
        if result.count > 1 { for index in stride(from:result.count-1,through:1,by:-1) {result.swapAt(index,random(index+1))} }
        return result
    }
    static func raw(_ value: String) -> [UInt16] {
        let string=value as NSString
        var result=[UInt16](repeating:0,count:string.length)
        if !result.isEmpty {result.withUnsafeMutableBufferPointer {string.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}}
        return result
    }
    static func foreign(_ value: String) -> String {
        let units=Array(value.utf16)
        return units.withUnsafeBufferPointer {unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
    }
    static func sameStorage(_ first: [RemoteLANInterface], _ second: [RemoteLANInterface]) -> Bool {
        first.withUnsafeBufferPointer {a in second.withUnsafeBufferPointer {b in a.baseAddress == b.baseAddress}}
    }
    static func permutations(_ values: [RemoteLANInterface], _ visit: ([RemoteLANInterface]) throws -> Void) rethrows {
        var rows=values
        func walk(_ index: Int) throws {
            if index == rows.count {try visit(rows);return}
            for next in index..<rows.count {rows.swapAt(index,next);try walk(index+1);rows.swapAt(index,next)}
        }
        try walk(0)
    }
    static func check() throws {
        var forward:[String:[RemoteLANInterface]]=[:],reverse:[[RemoteLANInterface]:String]=[:]
        func test(_ input: [RemoteLANInterface], shared: Bool = false) throws {
            let saved=input,flags=input.map {($0.name.isContiguousUTF8,$0.address.isContiguousUTF8,$0.netmask.isContiguousUTF8)}
            let units=input.map { [raw($0.name),raw($0.address),raw($0.netmask)] }
            let expected=legacy(input),key=current(input)
            try require(legacy(key)==expected,"Route content/multiplicity changed")
            if let previous=forward[expected] {try require(previous==key,"Equivalent valid routes did not canonicalize equally")}
            if let previous=reverse[key] {try require(previous==expected,"Different valid route values shared a typed key")}
            forward[expected]=key;reverse[key]=expected
            try require(input==saved,"Caller array changed")
            for index in input.indices {
                let item=input[index]
                try require(raw(item.name)==units[index][0] && raw(item.address)==units[index][1] && raw(item.netmask)==units[index][2],"Caller UTF16 changed")
                try require(item.name.isContiguousUTF8==flags[index].0 && item.address.isContiguousUTF8==flags[index].1 && item.netmask.isContiguousUTF8==flags[index].2,"Caller string storage changed")
            }
            if shared {try require(sameStorage(input,key),"Canonical route allocated/copied an interface array")}
            cases += 1
        }
        for count in [0,1,2,4,6,16,64] {
            let input=canonical(count);try test(input,shared:true);try test(Array(input.reversed()))
            if count <= 6 {try permutations(input) {try test($0)}}
        }
        for index in 0..<10000 {
            var input=canonical(random(25),variant:random(8))
            if !input.isEmpty && index%3==0 {input.append(input[random(input.count)])}
            try test(shuffled(input))
        }
        let base=canonical(2),key=current(base),first=base[0]
        let changes=[RemoteLANInterface(name:"en99",address:first.address,netmask:first.netmask,kind:first.kind),
            RemoteLANInterface(name:first.name,address:"10.90.0.2",netmask:first.netmask,kind:first.kind),
            RemoteLANInterface(name:first.name,address:first.address,netmask:"255.255.0.0",kind:first.kind),
            RemoteLANInterface(name:first.name,address:first.address,netmask:first.netmask,kind:.ethernet)]
        for changed in changes {
            let other=current([changed,base[1]])
            try require(key != other,"A changed route field reused a route identity")
            let dictionary=[key:1,other:2];try require(dictionary.count==2 && dictionary[key]==1 && dictionary[other]==2,"Full route equality was lost behind hashing")
            cases += 1
        }
        try require(current(base+[first]) != key,"Duplicate interface multiplicity was discarded");cases += 1
        let masks=[RemoteLANInterface(name:"en0",address:"10.0.0.2",netmask:"255.255.0.0",kind:.wifi),RemoteLANInterface(name:"en0",address:"10.0.0.2",netmask:"255.255.255.0",kind:.wifi)]
        try test(masks,shared:true);try test(Array(masks.reversed()))
        for kind in 0..<3 {for value in ["en-한글 e\u{301} 🙂 a very long interface name", "en-é", "en-e\u{301}"] {
            let name=kind==0 ? value : foreign(value)
            let input=[RemoteLANInterface(name:name,address:"10.0.0.2",netmask:"255.255.255.0",kind:.wifi)]
            try test(input,shared:true)
        }}
        // Public structs may contain arbitrary text,even though OS interfaces
        // are validated. Typed fields must not inherit delimiter collisions.
        let a=[RemoteLANInterface(name:"en:a",address:"b",netmask:"c",kind:.wifi)],b=[RemoteLANInterface(name:"en",address:"a:b",netmask:"c",kind:.wifi)]
        try require(legacy(a)==legacy(b) && current(a) != current(b),"Typed identity must separate delimiter-ambiguous fields");cases += 1
        print("TYPED_ROUTE cases \(cases); canonical buffer shared; fields and multiplicity exact; caller storage exact; collision separation exact")
    }
    static func main() throws {try check()}
}
