import Foundation

public struct AgentAccountState:Codable,Sendable {
    public let agent:String,phase:String,method:String
    public init(agent:String,phase:String,method:String="") {self.agent=agent;self.phase=phase;self.method=method}
}

public struct AgentAccountServices:Sendable {
    public var home:String
    public var check:@Sendable(String) async throws -> AgentAccountState
    package typealias PreparedLaunch = @Sendable () throws -> ManagedPTY
    package var prepareLaunch: (@Sendable (String) throws -> PreparedLaunch)?
    public var launch:@Sendable(String) throws -> ManagedPTY {
        didSet { prepareLaunch = nil }
    }
    public init(home:String,check:@escaping @Sendable(String) async throws -> AgentAccountState,launch:@escaping @Sendable(String) throws -> ManagedPTY) {self.home=home;self.check=check;self.launch=launch}
    public static var live:Self { local(codexHome:nil,executable:nil) }
    public static func codex(_ target:CodexAccountTransitionTarget) throws -> Self {
        guard target.home.hasPrefix("/"), !target.home.contains("\0"),
              target.executable == "codex" || target.executable.hasPrefix("/") && !target.executable.contains("\0") else {throw AppError.message("로그인할 Codex 위치를 확인해주세요.")}
        return local(codexHome:target.home,executable:target.executable,browser:true,witnesses:target.witnesses)
    }
    // The verifier is an internal fixture seam; public factories always attest
    // original OpenAI code. Claude's command and shell environment are unchanged.
    static func local(userHome:String=NSHomeDirectory(),codexHome:String?,executable:String?,browser:Bool=false,
                      witnesses:[CodexAccountTransitionWitness]=[],
                      verifyExecutable:@escaping @Sendable (String)throws->Void = {try CodexOfficialExecutable.verify($0)}) -> Self {
        let home=userHome
        var environment=ProcessInfo.processInfo.environment
        environment["HOME"]=home;environment["BROWSER"]="true";environment["NO_COLOR"]="1"
        if let codexHome {environment["CODEX_HOME"]=codexHome}
        // Match the login-shell environment used by AutoApprove's normal PTYs.
        // Never read/copy auth.json, API keys or credential-store entries here.
        let env=environment
        let resolve:@Sendable ()throws->CodexCLIContext? = {
            let selectedHome=codexHome ?? env["CODEX_HOME"] ?? home+"/.codex"
            let records=witnesses.prefix(50).flatMap {witness in
                ((try? ProcessDiscovery.read(pid:witness.pid)) ?? []).filter{$0.pid==witness.pid && $0.started==witness.started && "/dev/"+$0.tty==witness.tty}
            }
            return try CodexOfficialExecutable.resolve(home:selectedHome,userHome:home,
                executable:executable=="codex" ? nil:executable,records:records,environment:env,verifyExecutable:verifyExecutable)
        }
        let prepare: @Sendable (String) throws -> PreparedLaunch = { agent in
            let nativeBrowser=browser && agent=="codex"
            var prefix=nativeBrowser ? ["/usr/bin/env","-u","SSH_CONNECTION","-u","SSH_TTY","-u","SSH_CLIENT","-u","BROWSER","NO_COLOR=1"] : ["/usr/bin/env","BROWSER=true","SSH_CONNECTION=127.0.0.1 0 127.0.0.1 0","NO_COLOR=1"]
            let command:[String],launchEnvironment:[String:String], verifiedCLI: CodexCLIContext?
            if agent=="codex" {
                guard let cli=try resolve() else {throw AppError.message("공식 Codex CLI를 찾지 못했습니다.")}
                verifiedCLI = cli
                prefix.insert(contentsOf:["-u","AUTOAPPROVE_NATIVE_RUNTIME_ROOT","-u","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"],at:1)
                command=["HOME="+home,"CODEX_HOME="+cli.environment["CODEX_HOME"]!,"PATH="+cli.environment["PATH",default:"/usr/bin:/bin"],cli.executable,"login"]+(nativeBrowser ? []:["--device-auth"])
                launchEnvironment=cli.environment
            } else {verifiedCLI = nil; command=["claude","auth","login","--claudeai"];launchEnvironment=env}
            let arguments = prefix + command
            return {
                try verifiedCLI?.verifyUnchanged()
                return try ManagedPTY(cwd:home,program:"shell",command:arguments,columns:240,rows:40,environment:launchEnvironment)
            }
        }
        var services = Self(home:home,check:{agent in
            try await Task.detached(priority:.utility) {
                let result:CommandResult
                if agent=="codex" {
                    guard let cli=try resolve() else{return .init(agent:agent,phase:"missing")}
                    result=try cli.run(["login","status"])
                } else {
                    let script="command -v -- \"$1\" >/dev/null 2>&1 || exit 127; exec \"$1\" auth status --json"
                    result=try CommandRunner.run("/bin/zsh",["-l","-i","-c",script,"autoapprove-login",agent],timeout:8,environment:env,inheritEnvironment:false,outputLimit:32768,errorLimit:32768)
                }
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
        },launch:{ try prepare($0)() })
        services.prepareLaunch = prepare
        return services
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
        if agent=="codex-browser" {
            guard host=="auth.openai.com",url.percentEncodedPath=="/oauth/authorize",url.fragment==nil,
                  let items=url.queryItems,items.count<=32,Set(items.map(\.name)).count==items.count else {return false}
            let params=Dictionary(uniqueKeysWithValues:items.map{($0.name,$0.value ?? "")})
            guard params["client_id"]=="app_EMoamEEZ73f0CkXaXp7hrann",params["response_type"]=="code",params["code_challenge_method"]=="S256",
                  let challenge=params["code_challenge"],challenge.range(of:#"^[A-Za-z0-9_-]{43}$"#,options:.regularExpression) != nil,
                  let state=params["state"],(16...1024).contains(state.utf8.count),
                  let redirect=params["redirect_uri"],let callback=URLComponents(string:redirect),callback.scheme=="http",
                  ["127.0.0.1","localhost"].contains(callback.host ?? ""),let port=callback.port,(1...65535).contains(port),
                  callback.user==nil,callback.password==nil,callback.percentEncodedPath=="/auth/callback",callback.query==nil,callback.fragment==nil else {return false}
            return true
        }
        if agent=="codex" {return host=="auth.openai.com" && url.path=="/codex/device"}
        guard agent=="claude" else {return false}
        return host=="claude.com" && url.path=="/cai/oauth/authorize" || ["claude.ai","console.anthropic.com","platform.claude.com","console.claude.ai"].contains(host) && url.path=="/oauth/authorize"
    }
}
