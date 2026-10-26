import Foundation
import CoreFoundation
import Network
import Darwin
import AutoApproveCore

enum OriginalAddress {
    public static func isLocalHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let address = IPv6Address(host.components(separatedBy: "%")[0]) {
            let bytes = Array(address.rawValue)
            if bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255] {
                return isLocalHost(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            return address == IPv6Address("::1") || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
        return false
    }
    public static func endpoint(_ supplied: String) throws -> NWEndpoint {
        let value = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value.contains("://") ? value : "http://" + value),
              url.scheme == "http", url.user == nil, url.password == nil, let host = url.host,
              isLocalHost(host), ["", "/"].contains(url.path), url.query == nil, url.fragment == nil,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 8765) ?? 0), port.rawValue > 0 else {
            throw RemoteHTTPError(400, "Mac에 표시된 사설 IP 또는 .local 주소와 포트를 입력해주세요.")
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

@main struct NumericIPv4APICheck {
    enum Failure: Error { case invalid(String) }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.invalid(message) } }
    static func emit(_ value: [String:Any]) throws {
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self)); fflush(stdout)
    }
    static func oldOrigin(_ request: RemoteHTTPRequest) throws {
        let headers = request.headers, method = request.method, path = request.path
        guard let host = headers["host"], let authority = URLComponents(string: "http://" + host),
              authority.user == nil, authority.password == nil, let hostname = authority.host,
              (OriginalAddress.isLocalHost(hostname) || ["approve", "approve.", "autoapprove", "autoapprove."].contains(hostname.lowercased())),
              authority.path.isEmpty, authority.query == nil, authority.fragment == nil else {
            throw RemoteHTTPError(403, "같은 네트워크의 Mac 주소로 접속해주세요.")
        }
        if let origin = headers["origin"], origin.lowercased() != "http://" + host.lowercased() {
            throw RemoteHTTPError(403, "다른 웹사이트에서 보낸 요청은 처리할 수 없습니다.")
        }
        if let fetchSite = headers["sec-fetch-site"], !["same-origin", "none"].contains(fetchSite) {
            // A shared phone link and a newer Mac's page are top-level navigation.
            // Allow only the read-only entry document; API/subresource/iframe and
            // POST requests still require the exact page origin.
            guard method == "GET", ["/", "/index.html"].contains(path),
                  headers["sec-fetch-mode"] == "navigate", headers["sec-fetch-dest"] == "document" else {
                throw RemoteHTTPError(403, "AutoApprove 페이지에서 직접 요청해주세요.")
            }
        }
    }
    static func oldIPv4(_ address: String) -> UInt32? {
        IPv4Address(address)?.rawValue.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func oldMask(_ interface:RemoteLANInterface) -> UInt32? {
        guard let value=oldIPv4(interface.netmask),value != 0 else{return nil}
        let inverse = ~value
        return inverse & (inverse &+ 1) == 0 ? value : nil
    }
    static func oldRoute(_ address:String,_ interfaces:[RemoteLANInterface]) -> RemoteLANInterface? {
        guard let host=oldIPv4(address) else{return nil}
        return interfaces.sorted{($0.kind == .wifi ? 0:1,$0.name,$0.address)<($1.kind == .wifi ? 0:1,$1.name,$1.address)}
            .filter{guard let own=oldIPv4($0.address),let mask=oldMask($0) else{return false};return own & mask == host & mask}
            .sorted{(oldMask($0) ?? 0)>(oldMask($1) ?? 0)}.first
    }
    static func cocoa(_ text:String) -> String {
        let units=Array(text.utf16)
        guard !units.isEmpty else{return NSString(string:"") as String}
        return units.withUnsafeBufferPointer{unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
    }
    static func raw(_ value:String) -> [UInt16] {
        let ns=value as NSString
        return (0..<ns.length).map{ns.character(at:$0)}
    }
    static func outcome(_ body:()throws->String) -> String {
        do{return "ok:"+(try body())}catch let error as RemoteHTTPError{return "error:\(error.status):\(error.message)"}catch{return "other:\(error)"}
    }
    static func request(_ host:String,_ path:String="/api/state",origin:String?=nil,site:String?="same-origin",method:String="GET") throws -> RemoteHTTPRequest {
        var text="\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nSec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: document\r\n"
        if method == "POST"{text += "Content-Length: 0\r\n"}
        if let origin{text += "Origin: \(origin)\r\n"};if let site{text += "Sec-Fetch-Site: \(site)\r\n"}
        guard let request=try RemoteHTTPRequest.parse(Data((text+"\r\n").utf8)) else{throw Failure.invalid("Incomplete fixture request")}
        return request
    }
    static let numeric=["10.23.45.67","192.168.43.2","172.20.10.1","169.254.255.1","127.0.0.1","8.8.8.8","172.32.0.1","192.169.0.1","0.0.0.0","255.255.255.255","10.0.0.1","172.16.0.1","172.31.255.255","192.168.255.255","169.253.0.1","127.255.255.255"]
    static let dns=["mac.local","MAC.LOCAL.","localhost","example.com","approve","other-machine.local","autoapprove.example.com","localhost."]
    static let v6=["::1","fe80::1","fd00::1","2001:4860:4860::8888","::ffff:192.168.1.2","::ffff:8.8.8.8","[::1]","fe80::123%en0"]
    static let fallback=["not-an-address","::1","10.0.0","10.0.0.01","256.0.0.1","192.168.0.2.example.com","10.0.0.1\u{0}tail","١٠.0.0.1"]
    static let two:[RemoteLANInterface]=[
        .init(name:"en1",address:"172.20.10.2",netmask:"255.255.255.240",kind:.wifi),
        .init(name:"en0",address:"10.23.45.6",netmask:"255.255.255.0",kind:.ethernet)]
    static let sixteen:[RemoteLANInterface]=(0..<16).map{ i in
        .init(name:"en\(i)",address:"10.\(i).0.2",netmask:i % 4 == 0 ? "255.0.0.0":"255.255.0.0",kind:i % 3 == 0 ? .wifi:.ethernet)
    }
    static func correctness() throws {
        let routeSelection=try RouteSelectionCases.run()
        var cases=0,foreign=0,routeCases=0,originCases=0,endpointCases=0,digest:UInt64=0
        func check(_ supplied:String,_ kind:Int=0) throws {
            let value=kind == 0 ? supplied:cocoa(supplied),before=raw(kind == 0 ? supplied:cocoa(supplied)),native=value.isContiguousUTF8
            let original=oldIPv4(value)
            let expected=OriginalAddress.isLocalHost(value),actual=RemoteNetworkAddress.isLocalHost(value)
            try require(actual==expected,"Actual Core host mismatch: \(value.debugDescription)")
            try require(raw(value)==before && value.isContiguousUTF8==native,"Caller string changed")
            cases+=1;if !native{foreign+=1};digest=(digest &* 1099511628211) ^ UInt64(original ?? 0) ^ UInt64(actual ? 1:0) ^ UInt64(value.utf8.count)
        }
        for prefix in 0..<65536 {
            for suffix in [0,1,255,65535] {
                let value="\(prefix >> 8).\(prefix & 255).\(suffix >> 8).\(suffix & 255)"
                try check(value);try check(value,1)
            }
        }
        for position in 0..<4 {for value in 0...255 {var parts=["10","0","1","2"];parts[position]=String(value);try check(parts.joined(separator:"."))}}
        var random:UInt64=0x9e3779b97f4a7c15
        for i in 0..<50000 {
            random=random &* 6364136223846793005 &+ 1442695040888963407
            let number=UInt32(truncatingIfNeeded:random),value="\(number >> 24).\((number >> 16)&255).\((number >> 8)&255).\(number & 255)"
            try check(value,i&1)
            let bad=[" ","\u{0}",".","０","+","-","a","%","\r","\u{202e}"][i % 10]
            try check(i % 2 == 0 ? bad+value:value+bad,i&1)
        }
        let special=numeric+dns+v6+fallback+["","1","127.1","0x7f000001","0177.0.0.1","10.000.0.1","[10.0.0.1]","[[10.0.0.1]]","10.0.0.1\n","10.0.0.1.","10..0.1","1.2.3.4.5",String(repeating:"1",count:20000),"::ffff:10.0.0.1","::ffff:172.16.0.1","::ffff:192.168.1.1","[fe80::1%en0]","MÁC.LOCAL","not.local.example.com"]
        for value in special {for kind in 0..<2{try check(value,kind)}}
        for value in [String(repeating:"한글🙂e\u{301}",count:64),String(repeating:"한글🙂",count:32)+".local"]{try check(value);try check(value,1)}
        let chars=["","0","00","01","000","001","1","9","10","99","100","255","256","999","-1","+1"," 1","1 ","１","١","²","\u{0}","\u{fffd}","\u{202e}","1\u{0}2","1.2","\u{200b}"]
        for position in 0..<4 {for a in chars {for b in chars {
            var parts=["10","0","1","2"];parts[position]=a;parts[(position+1)%4]=b
            for kind in 0..<2 {try check(parts.joined(separator:"."),kind)}
        }}}
        let sets=[two,Array(two.reversed()),sixteen,Array(sixteen.reversed()),two+two,[RemoteLANInterface(name:"en0",address:"10.0.0.2",netmask:"255.0.255.0",kind:.wifi)],
            [RemoteLANInterface(name:"en0",address:"10.0.0.2",netmask:"0.0.0.0",kind:.wifi)],
            [RemoteLANInterface(name:"en0",address:"10.0.0.2",netmask:"255.255.255.255",kind:.wifi)],
            [RemoteLANInterface(name:"en0",address:"10.0.0.02",netmask:"255.255.255.0",kind:.wifi)],[]]
        var routeInputs=numeric+fallback+v6+special.prefix(20)
        for i in 0..<1024 {routeInputs.append("10.\(i % 256).\(i / 256).\(i % 255)")}
        for interfaces in sets {for address in routeInputs {
            let expected=oldRoute(address,interfaces),actual=RemoteLAN.route(to:address,interfaces:interfaces)
            try require(actual==expected,"Actual Core route mismatch: \(address.debugDescription)");routeCases+=1
            digest=(digest &* 1099511628211) ^ UInt64(actual?.name.utf8.count ?? 0)
        }}
        for address in special.prefix(70) {for suffix in ["",":8765","/","/path","?x=1","#x"] {
            let supplied=address+suffix
            let expected=outcome{String(describing:try OriginalAddress.endpoint(supplied))},actual=outcome{String(describing:try RemoteNetworkAddress.endpoint(supplied))}
            try require(expected==actual,"Actual Core endpoint mismatch: \(supplied.debugDescription)");endpointCases+=1
        }}
        let hosts=numeric+dns+v6+fallback+["approve","approve.","AUTOAPPROVE.","user@10.0.0.1","10.0.0.1/path","10.0.0.1?x=1","10.0.0.1#x","10.0.0.1:8765","[::1]:8765","8.8.8.8:8765"]
        for host in hosts {for origin in [nil,"http://"+host,"https://"+host,"http://attacker.example"] as [String?] {for site in [nil,"same-origin","none","same-site","cross-site"] as [String?] {for path in ["/api/state","/"] {for method in ["GET","POST"] {
            let expected=outcome{try oldOrigin(request(host,path,origin:origin,site:site,method:method));return "accepted"}
            let actual=outcome{try request(host,path,origin:origin,site:site,method:method).validateOrigin();return "accepted"}
            try require(expected==actual,"Actual Core origin mismatch: \(host.debugDescription)");originCases+=1
        }}}}}
        try require(cases>600000 && foreign>0 && routeCases>10000 && originCases>2000,"Corpus coverage incomplete: cases=\(cases) foreign=\(foreign) route=\(routeCases) origin=\(originCases)")
        try emit(["passed":true,"actualCoreLocalHostCases":cases,"foreignStorageCases":foreign,"actualCoreRouteCases":routeCases,"actualCoreEndpointCases":endpointCases,"actualCoreOriginCases":originCases,"digest":String(digest),"actualCompiledCoreAPIs":true,"onlyIndependentNetworkBasedOracle":true,"routeSelection":routeSelection,"powerCommands":0,"originalTerminalActions":0])
    }
    static func main(){do{try correctness()}catch{fputs("Numeric IPv4 API check failed: \(error)\n",stderr);exit(1)}}
}

// The independent old selector lives in NumericIPv4APICheck.oldRoute and uses
// Network's parser and the original two stable sorts. No new selector copy.
enum RouteSelectionCases {
    static func run() throws -> [String:Any] {
        var cases=0,foreign=0,consumerCases=0,bindingCases=0,digest:UInt64=0
        func require(_ value:Bool,_ reason:String)throws{try NumericIPv4APICheck.require(value,reason)}
        func raw(_ value:String)->[UInt16]{NumericIPv4APICheck.raw(value)}
        func text(_ value:RemoteLANInterface?)->[[UInt16]]?{value.map{[raw($0.name),raw($0.address),raw($0.netmask)]}}
        func state(_ input:[RemoteLANInterface])->[([UInt16],[UInt16],[UInt16],Bool,Bool,Bool)] {
            input.map{(raw($0.name),raw($0.address),raw($0.netmask),$0.name.isContiguousUTF8,$0.address.isContiguousUTF8,$0.netmask.isContiguousUTF8)}
        }
        func check(_ host:String,_ input:[RemoteLANInterface])throws{
            let before=state(input),hostBefore=raw(host),hostNative=host.isContiguousUTF8
            let expected=NumericIPv4APICheck.oldRoute(host,input),actual=RemoteLAN.route(to:host,interfaces:input)
            try require(actual==expected && text(actual)==text(expected),"Route value/raw UTF16 mismatch: \(host.debugDescription)")
            if let actual,let expected {
                try require(actual.name.isContiguousUTF8==expected.name.isContiguousUTF8 && actual.address.isContiguousUTF8==expected.address.isContiguousUTF8 && actual.netmask.isContiguousUTF8==expected.netmask.isContiguousUTF8,"Selected string representation changed")
                for field in text(actual)! {for unit in field{digest=(digest &* 1099511628211) ^ UInt64(unit)}}
            }else{digest=digest &* 1099511628211}
            let after=state(input);try require(before.count==after.count && raw(host)==hostBefore && host.isContiguousUTF8==hostNative,"Caller host/array changed")
            for i in before.indices {
                try require(before[i].0==after[i].0 && before[i].1==after[i].1 && before[i].2==after[i].2 && before[i].3==after[i].3 && before[i].4==after[i].4 && before[i].5==after[i].5,"Caller interface text/storage changed")
                if !before[i].3 || !before[i].4 || !before[i].5{foreign+=1}
            }
            cases+=1
        }
        func ip(_ value:UInt32)->String{"\(value >> 24).\((value >> 16)&255).\((value >> 8)&255).\(value & 255)"}
        let nfc="en-long-한글-é-selected-first",nfd="en-long-한글-e\u{301}-selected-first"
        try require(nfc==nfd && raw(nfc) != raw(nfd),"Missing normalization-equivalent raw tie")
        let base:[RemoteLANInterface]=[
            .init(name:"en1",address:"172.20.10.2",netmask:"255.255.255.240",kind:.wifi),
            .init(name:"en0",address:"172.20.10.4",netmask:"255.255.255.240",kind:.ethernet),
            .init(name:"en9",address:"172.20.0.2",netmask:"255.255.0.0",kind:.wifi),
            .init(name:"en4",address:"10.0.0.2",netmask:"255.0.0.0",kind:.ethernet),
            .init(name:NumericIPv4APICheck.cocoa(nfc),address:"172.20.10.3",netmask:"255.255.255.255",kind:.wifi),
            .init(name:NumericIPv4APICheck.cocoa(nfd),address:"172.20.10.3",netmask:"255.255.255.255",kind:.wifi),
            .init(name:"en-invalid",address:"172.20.10.8",netmask:"255.0.255.0",kind:.wifi)]
        let hosts=["172.20.10.1","172.20.10.3","172.20.10.0","172.20.10.15","10.4.5.6","192.168.1.1","::1","10.0.0.01"]
        var permutation=base
        func permutations(_ index:Int)throws{
            if index==permutation.count{for host in hosts{try check(host,permutation)};return}
            for next in index..<permutation.count{permutation.swapAt(index,next);try permutations(index+1);permutation.swapAt(index,next)}
        }
        try permutations(0)
        let own:UInt32=0x0a141e28
        for prefix in 1...32 {
            let mask=UInt32.max << (32-prefix),network=own & mask,broadcast=network | ~mask
            let interfaces=[RemoteLANInterface(name:"en1",address:ip(own),netmask:ip(mask),kind:.wifi)]
            for host in [own,network,broadcast,network &- 1,broadcast &+ 1] {try check(ip(host),interfaces);try check(NumericIPv4APICheck.cocoa(ip(host)),interfaces)}
            for other in 1...32 {
                let more=RemoteLANInterface(name:"en0",address:ip(own),netmask:ip(UInt32.max << (32-other)),kind:.ethernet)
                for host in [own,network,broadcast]{try check(ip(host),interfaces+[more]);try check(ip(host),[more]+interfaces)}
            }
        }
        var seed:UInt64=0x123456789abcdef
        func random(_ upper:Int)->Int{seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Int((seed >> 32)%UInt64(upper))}
        for iteration in 0..<6000 {
            var input=[RemoteLANInterface]()
            for i in 0..<random(25){
                let prefix=random(34),mask=prefix==0 ? "0.0.0.0":prefix==33 ? "255.0.255.0":ip(UInt32.max << (32-prefix))
                let address=i%17==0 ? "10.0.0.01":"10.\(random(8)).\(random(4)).\(random(255))"
                let name=i%5==0 ? (i%2==0 ? nfc:nfd):"en\(random(8))"
                input.append(.init(name:iteration%2==0 ? NumericIPv4APICheck.cocoa(name):name,address:iteration%3==0 ? NumericIPv4APICheck.cocoa(address):address,netmask:mask,kind:random(2)==0 ? .wifi:.ethernet))
            }
            if iteration%4==0,let first=input.first{input.append(first)}
            let target="10.\(random(8)).\(random(4)).\(random(255))"
            for host in [target,"192.168.1.1",iteration%2==0 ? "10.0.0.01":"10.0.0.1\u{0}tail"]{try check(host,input);try check(host,Array(input.reversed()))}
        }
        for address in ["10.0.0.2","10.0.0.02","10.0.0.1\u{0}tail","not-an-address","[10.0.0.2]","::1"] {
            for mask in ["0.0.0.0","255.255.255.255","255.0.255.0","255.255.255.0","255.255.255.000","255.255.255.256",""] {
                let input=[RemoteLANInterface(name:nfc,address:address,netmask:mask,kind:.wifi),RemoteLANInterface(name:nfd,address:"10.0.0.2",netmask:"255.255.255.0",kind:.wifi)]
                for host in ["10.0.0.1","10.0.0.0","10.0.0.255","10.0.1.1"]{try check(host,input);try check(host,Array(input.reversed()))}
            }
        }
        for input in [base,Array(base.reversed()),[],[base[0]],Array(base.prefix(4))] {
            for address in hosts+NumericIPv4APICheck.numeric {
                for supplied in ["http://\(address):8765",address,"%%% invalid"] {
                    let expected:String
                    if let host=URLComponents(string:supplied)?.host {
                        expected=NumericIPv4APICheck.oldRoute(host,input)?.name ?? host.split(separator:".").prefix(3).joined(separator:".")
                    }else{expected=supplied}
                    let actual=RemoteLAN.discoveryLane(supplied,interfaces:input)
                    try require(actual==expected && raw(actual)==raw(expected),"Discovery grouping changed");consumerCases+=1
                }
                for client in [nil,"::1","127.0.0.1","172.20.10.3","10.0.0.4","192.168.1.1"] as [String?] {
                    let expected:Bool
                    if client==nil || client=="::1" || client!.hasPrefix("127."){expected=true}
                    else if let source=NumericIPv4APICheck.oldRoute(client!,input),let target=NumericIPv4APICheck.oldRoute(address,input){expected=source.name==target.name}
                    else{expected=false}
                    try require(RemoteLAN.sharesClientLAN(address,client:client,interfaces:input)==expected,"Client LAN sharing changed");consumerCases+=1
                }
            }
            for host in ["127.0.0.1","172.20.10.2","172.20.10.3","172.20.10.14","10.0.0.4","192.168.1.1"] {
                let source=NumericIPv4APICheck.oldRoute(host,input),local=host.hasPrefix("127.") || input.contains{$0.address==host}
                do{
                    let parameters=try RemoteLAN.tcpParameters(to:.hostPort(host:NWEndpoint.Host(host),port:8765),interfaces:input)
                    if local{try require(parameters.requiredLocalEndpoint==nil,"Loopback/own endpoint bound to a LAN")}
                    else if let source{
                        try require(parameters.requiredLocalEndpoint == .hostPort(host:NWEndpoint.Host(source.address),port:.any),"Wrong bound source address")
                        try require(parameters.requiredInterfaceType == (source.kind == .wifi ? .wifi:.wiredEthernet),"Wrong physical interface type")
                    }else{throw NumericIPv4APICheck.Failure.invalid("Missing route accepted")}
                    try require(parameters.prohibitedInterfaceTypes?.contains(.other)==true && parameters.prohibitedInterfaceTypes?.contains(.cellular)==true,"Tunnel/cellular restrictions changed")
                }catch let error as RemoteHTTPError{try require(!local && source==nil && error.status==503,"Unexpected binding error")}
                bindingCases+=1
            }
        }
        try require(cases>80000 && foreign>0 && consumerCases==1080 && bindingCases==30,"Route corpus incomplete: \(cases)/\(foreign)/\(consumerCases)/\(bindingCases)")
        return ["passed":true,"cases":cases,"foreignInterfaceVisits":foreign,"consumerCases":consumerCases,"bindingCases":bindingCases,"rawUTF16AndFirstTieExact":true,"callerTextAndStoragePreserved":true,"digest":String(digest),"socketsOpened":0,"systemRouteChanges":0]
    }
}
