import Foundation
import CoreFoundation
import CryptoKit
import AutoApproveCore

@main struct CanonicalResponseAPICheck {
    enum Failure: Error { case mismatch(String) }
    static var scalars = 0, units = 0, frames = 0, foreign = 0, checks = 0
    static var digest: UInt64 = 1469598103934665603
    static let reference: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    static func require(_ value: Bool, _ message: String) throws { checks += 1; if !value { throw Failure.mismatch(message) } }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    static func raw(_ text: String) -> [UInt16] {
        let value = text as NSString; var output = [UInt16](repeating:0,count:value.length)
        if !output.isEmpty { output.withUnsafeMutableBufferPointer { value.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count)) } }
        return output
    }
    static func stored(_ input: [UInt16], _ kind: Int) -> String {
        if kind == 0 { return String(decoding:input,as:UTF16.self) }
        return input.withUnsafeBufferPointer {
            if kind == 1 { return NSString(characters:$0.baseAddress!,length:$0.count) as String }
            return unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String
        }
    }
    static func probe(_ template: RemoteDashboard, text: String, key: String? = nil, conditional: Bool = false) throws {
        let native = text.isContiguousUTF8, original = raw(text)
        if !native { foreign += 1 }
        var value = template
        value.updatedAt = Date(timeIntervalSince1970:1_800_000_000.5)
        value.nodes[0].state!.sessions[0].session.detail = text
        value.nodes[0].state!.sessions[0].title = text
        if let key {
            var update = LANUpdateStatus(); let otherKey = key == "z" ? "other" : "z"; update.diagnostics = [key:text,otherKey:"last"]
            value.nodes[0].state!.update = update
        }
        var canonical = value; canonical.updatedAt = Date(timeIntervalSince1970:0)
        let tag = "W/\"" + hash(try reference.encode(canonical)) + "\"", expected = try reference.encode(value)
        let response = try value.response(ifNoneMatch:nil)
        try require(response.status == 200 && response.body == expected && response.entityTag == tag && response.observedAt == value.updatedAt,"Actual Core dashboard bytes/tag/observation changed at frame \(frames)")
        let state = value.nodes[0].state!.inventory, stateBytes = try reference.encode(state), stateTag = "\"" + hash(stateBytes) + "\""
        let inventory = try state.response(ifNoneMatch:nil)
        try require(inventory.status == 200 && inventory.body == stateBytes && inventory.entityTag == stateTag,"Actual Core inventory bytes/strong validator changed")
        if conditional {
            for validator in [tag, String(tag.dropFirst(2)), "\"other\", " + tag, "*"] {
                let same = try value.response(ifNoneMatch:validator)
                try require(same.status == 304 && same.body.isEmpty && same.entityTag == tag && same.observedAt == value.updatedAt,"Actual Core dashboard conditional behavior changed")
            }
            for validator in [stateTag,"W/"+stateTag,"*"] {
                let same = try state.response(ifNoneMatch:validator)
                try require(same.status == 304 && same.body.isEmpty && same.entityTag == stateTag,"Actual Core inventory conditional behavior changed")
            }
        }
        for byte in response.body { digest = (digest ^ UInt64(byte)) &* 1099511628211 }
        try require(text.isContiguousUTF8 == native && raw(text) == original,"Actual Core mutated input storage")
        frames += 1
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-json-api-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let record = ProcessDiscovery.parse("930001 1 ttys999 930001 930001 Mon Oct 12 09:00:00 2026 /fixture/codex")[0]
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),claudeRegistryReader:{_ in []},processReader:{[record]},terminalInputAvailable:{false},terminalInputIdentity:{_ in nil})
        defer { engine.stop() }
        var session = AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/ttys999",cwd:"/fixture/project",terminal:.iterm)
        session.phase = .working; session.lastActivity = Date(timeIntervalSince1970:1_800_000_000)
        engine.updateDiscovery([session],records:[record])
        let service = RemoteNetworkService(engine:engine,nodeID:"json-api-fixture",name:"Synthetic Mac",bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{_ in})
        defer { service.stop() }
        let template = try await service.dashboard(localAddressReady:false)
        try require(template.nodes[0].state?.sessions.count == 1,"Missing synthetic model")
        var block = ""
        for value in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(value) else { continue }
            scalars += 1; block.unicodeScalars.append(scalar)
            if scalars % 256 == 0 {
                for kind in 0..<3 { try probe(template,text:stored(Array(block.utf16),kind),conditional:scalars%16384 == 0) }
                block = ""
            }
        }
        try require(block.isEmpty,"Incomplete scalar group")
        var data: [UInt16] = []
        for value in UInt32(0)...65535 {
            units += 1; data += [0xd800,UInt16(value),0xdc00]
            if units % 128 == 0 {
                for kind in 0..<3 { try probe(template,text:stored(data,kind),conditional:units%4096 == 0) }
                data = []
            }
        }
        try require(data.isEmpty,"Incomplete UTF16 group")
        for key in ["A","a2","a11","z","é","e"+String(UnicodeScalar(0x301)!),"한글","👩🏽‍💻"] {
            for kind in 0..<3 { try probe(template,text:"quoted\"/\\\n한글🙂",key:stored(Array(key.utf16),kind),conditional:true) }
        }
        for length in [0,1,63,64,65,4095,4096,4097,999999,1000000,3999999,4000000] {
            try probe(template,text:String(repeating:"x",count:length))
        }
        try require(scalars == 1112064 && units == 65536 && foreign > 8000,"Incomplete actual API corpus")
        print("CANONICAL_RESPONSE_API scalars \(scalars); utf16Units \(units); frames \(frames); foreign \(foreign); checks \(checks); checksum \(digest)")
    }
}
