import Foundation

public struct AgentAccountState:Codable,Sendable {
    public let agent:String,phase:String,method:String
    public init(agent:String,phase:String,method:String="") {self.agent=agent;self.phase=phase;self.method=method}
}

public struct AgentAccountServices:Sendable {
    public var home:String
    public var check:@Sendable(String) async throws -> AgentAccountState
    public var launch:@Sendable(String) throws -> ManagedPTY
    public init(home:String,check:@escaping @Sendable(String) async throws -> AgentAccountState,launch:@escaping @Sendable(String) throws -> ManagedPTY) {self.home=home;self.check=check;self.launch=launch}
    public static var live:Self {
        let home=NSHomeDirectory()
        var environment=ProcessInfo.processInfo.environment
        environment["HOME"]=home;environment["BROWSER"]="true";environment["NO_COLOR"]="1"
        // Match the login-shell environment used by AutoApprove's normal PTYs.
        // Never read/copy auth.json, API keys or credential-store entries here.
        let env=environment
        return Self(home:home,check:{agent in
            try await Task.detached(priority:.utility) {
                let args=agent=="codex" ? "login status" : "auth status --json"
                let result=try CommandRunner.run("/bin/zsh",["-l","-i","-c","command -v \(agent) >/dev/null 2>&1 || exit 127; exec \(agent) \(args)"],timeout:8,environment:env,inheritEnvironment:false,outputLimit:32768,errorLimit:32768)
                if result.status==127 {return AgentAccountState(agent:agent,phase:"missing")}
                if agent=="claude",let data=result.output.data(using:.utf8),let json=try? JSONSerialization.jsonObject(with:data) as? JSONObject,let logged=json["loggedIn"] as? Bool {
                    let raw=json["authMethod"] as? String ?? ""
                    let method=["api_key","api_key_helper","third_party","oauth_token","claude.ai"].contains(raw) ? raw:""
                    return AgentAccountState(agent:agent,phase:logged ? "authenticated":"signedOut",method:method)
                }
                let text=(result.output+"\n"+result.error).lowercased()
                if agent=="codex",result.status==0,text.contains("logged in") {return AgentAccountState(agent:agent,phase:"authenticated",method:text.contains("api key") ? "api_key":"chatgpt")}
                if text.contains("not logged in") || text.contains("not authenticated") {return AgentAccountState(agent:agent,phase:"signedOut")}
                return AgentAccountState(agent:agent,phase:"unknown")
            }.value
        },launch:{agent in
            try ManagedPTY(cwd:home,program:"shell",command:["/usr/bin/env","BROWSER=true","SSH_CONNECTION=127.0.0.1 0 127.0.0.1 0","NO_COLOR=1"]+(agent=="codex" ? ["codex","login","--device-auth"]:["claude","auth","login","--claudeai"]),columns:240,rows:40,environment:env)
        })
    }
}

public enum AgentAccountOutput {
    public struct Challenge {public var url:String?,code:String?}
    public static func challenge(_ text:String,agent:String)->Challenge {
        let clean=text.replacingOccurrences(of:#"\x1B\[[0-?]*[ -/]*[@-~]"#,with:"",options:.regularExpression)
        var answer=Challenge()
        let regex=try! NSRegularExpression(pattern:#"https://[^\s\u0000-\u001F\u007F<>\"']+"#)
        for match in regex.matches(in:clean,range:NSRange(clean.startIndex...,in:clean)) {
            guard let range=Range(match.range,in:clean) else {continue}
            let value=String(clean[range]).trimmingCharacters(in:CharacterSet(charactersIn:".)"))
            if validURL(value,agent:agent) {answer.url=value;break}
        }
        if agent=="codex",let range=clean.range(of:#"\b[A-Z0-9]{4,6}-[A-Z0-9]{4,6}\b"#,options:.regularExpression) {answer.code=String(clean[range])}
        return answer
    }
    public static func validURL(_ text:String,agent:String)->Bool {
        guard text.utf8.count<=8192,let url=URLComponents(string:text),url.scheme=="https",url.user==nil,url.password==nil,url.port==nil,let host=url.host?.lowercased() else {return false}
        return agent=="codex" ? host=="auth.openai.com" && url.path=="/codex/device" : host=="claude.com" && url.path=="/cai/oauth/authorize" || ["claude.ai","console.anthropic.com","platform.claude.com","console.claude.ai"].contains(host) && url.path=="/oauth/authorize"
    }
}
