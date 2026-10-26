import Foundation

/// Read pasted setup values as data. No pasted command is ever executed.
public enum RemoteTunnelSetup {
    public static let dashboardURL=URL(string:"https://dash.cloudflare.com/?to=/:account/tunnels")!
    public static let guideURL=URL(string:"https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/")!
    public static func origin(_ supplied:String) throws -> String {
        let value=supplied.trimmingCharacters(in:.whitespacesAndNewlines)
        return try RemoteTunnelConfiguration.origin(value.contains("://") ? value : "https://"+value)
    }
    public static func subdomain(_ supplied:String) throws -> String {
        let value=supplied.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard value.range(of:#"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#,options:.regularExpression) != nil else {
            throw AppError.message("서브도메인은 영문·숫자·하이픈 1~63자로 입력하세요. 예: a, aa, term. 처음과 끝에는 하이픈을 쓸 수 없습니다.")
        }
        return value
    }
    public static func subdomain(from origin:String,domain:String)->String? {
        guard let canonical=try? Self.origin(origin),let host=URLComponents(string:canonical)?.host,
              host.hasSuffix("."+domain.lowercased()) else {return nil}
        return try? subdomain(String(host.dropLast(domain.count+1)))
    }
    public static func token(_ supplied:String) throws -> String {
        let value=supplied.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.utf8.count <= 32768, !value.contains("\0") else {throw invalidToken()}
        if value.isEmpty {return ""}
        let pattern=#"^[A-Za-z0-9_+/=.-]{16,16384}$"#
        if value.range(of:pattern,options:.regularExpression) != nil {return value}
        // The dashboard can copy either a service-install or tunnel-run line.
        // Find one complete cloudflared invocation, then extract its token only.
        let command=#"(?:^|\s|&&)(?:sudo\s+)?(?:[/A-Za-z0-9_.-]*/)?cloudflared(?:\.exe)?\s+(?:service\s+install\s+|tunnel\s+run\s+--token(?:=|\s+))[\"']?([A-Za-z0-9_+/=.-]{16,16384})[\"']?\s*$"#
        guard let range=value.range(of:command,options:.regularExpression),
              let regex=try? NSRegularExpression(pattern:command),
              let match=regex.firstMatch(in:value,range:NSRange(range,in:value)),
              let tokenRange=Range(match.range(at:1),in:value) else {throw invalidToken()}
        return String(value[tokenRange])
    }
    private static func invalidToken()->AppError {
        .message("Cloudflare의 터널 토큰 또는 cloudflared 설치 명령 전체를 붙여넣어주세요.")
    }
}
