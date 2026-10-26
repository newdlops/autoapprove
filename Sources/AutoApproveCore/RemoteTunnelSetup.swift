import Foundation

/// Read pasted setup values as data. No pasted command is ever executed.
public enum RemoteTunnelSetup {
    public static let dashboardURL=URL(string:"https://dash.cloudflare.com/?to=/:account/tunnels")!
    public static let guideURL=URL(string:"https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/")!
    public static func origin(_ supplied:String) throws -> String {
        let value=supplied.trimmingCharacters(in:.whitespacesAndNewlines)
        return try RemoteTunnelConfiguration.origin(value.contains("://") ? value : "https://"+value)
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
