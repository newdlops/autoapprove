import Foundation

/// Honor Port Manager's declared namespace without changing its configuration.
public enum RemoteLoopback {
    public static func isAddress(_ host:String)->Bool {
        let pieces=host.split(separator:".",omittingEmptySubsequences:false)
        return pieces.count==4 && pieces[0]=="127" && pieces.allSatisfy {part in
            guard let value=UInt8(part),String(value)==part else {return false};return true
        }
    }
    public static func portManagerHost(environment:[String:String] = ProcessInfo.processInfo.environment)->String? {
        guard environment["PORT_MANAGER_HOOK"] != "0",environment["PORT_MANAGER_HOOK_DISABLED"] != "1" else {return nil}
        return ["PORT_MANAGER_ACTUAL_LOOPBACK_HOST","PORT_MANAGER_NETWORK_LOOPBACK_HOST"].compactMap {environment[$0]}.first {isAddress($0) && $0 != "127.0.0.1"}
    }
    public static func host(requestedPort:UInt16,environment:[String:String] = ProcessInfo.processInfo.environment)->String {
        guard let managed=portManagerHost(environment:environment) else {return "127.0.0.1"}
        // The global scope keeps port-zero listeners host-local for IPC peers.
        if requestedPort==0 && (environment["PORT_MANAGER_NETWORK_IS_GLOBAL"]=="1" || environment["PORT_MANAGER_NETWORK_ID"]=="network-global") {return "127.0.0.1"}
        if requestedPort>0,environment["PORT_MANAGER_PRESERVE_LISTEN_PORTS"]?.split(separator:",").contains(where:{$0.trimmingCharacters(in:.whitespaces)==String(requestedPort)})==true {return "127.0.0.1"}
        return managed
    }
    static func healthOrigins(preferred:String?,port:UInt16)->[String] {
        var values:[String]=[]
        if let preferred,let parts=URLComponents(string:preferred),parts.scheme=="http",let host=parts.host,isAddress(host),parts.port==Int(port),
           parts.user==nil,parts.password==nil,parts.query==nil,parts.fragment==nil,["","/"].contains(parts.path) {values.append("http://\(host):\(port)")}
        for host in [Self.host(requestedPort:port),"127.0.0.1"] {
            let url="http://\(host):\(port)";if !values.contains(url){values.append(url)}
        }
        return values
    }
}
