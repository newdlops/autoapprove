import Foundation
import AutoApproveCore

enum AgentAccountFixture {
    static func services(_ root:URL) throws -> AgentAccountServices {
        let fm=FileManager.default
        // Synthetic home and auth commands only. No real account/credential or
        // user terminal is touched, and no process may launch a user browser.
        let home=root.appendingPathComponent("home");try fm.createDirectory(at:home,withIntermediateDirectories:true)
        try fm.createDirectory(at:home.appendingPathComponent("bin"),withIntermediateDirectories:true)
        let shell="export PATH='\(home.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin'\n"
        for name in [".zshrc",".zlogin"] {try Data(shell.utf8).write(to:home.appendingPathComponent(name))}
        for agent in ["codex","claude"] {
            let script=agent=="codex" ? """
            #!/bin/zsh -f
            if [[ -f '\(root.path)/expire-codex' ]]; then print 'Authentication expired'; exit 1; fi
            print 'https://auth.openai.com/codex/device'
            print 'ABCD-12345'
            while [[ ! -f '\(root.path)/signed-codex' ]]; do sleep 0.1; done
            exit 0
            """ : """
            #!/bin/zsh -f
            if [[ -f '\(root.path)/expire-claude' ]]; then print 'Authentication expired'; exit 1; fi
            print 'https://claude.com/cai/oauth/authorize?state=SYNTHETIC-ONLY&code_challenge=FIXTURE'
            print 'Paste code here if prompted:'
            read -r value
            print -r -- "$value" >> '\(root.path)/submitted-codes'
            if [[ "$value" != 'SYNTHETIC-CODE#state' ]]; then exit 1; fi
            touch '\(root.path)/signed-claude'
            exit 0
            """
            let file=root.appendingPathComponent(agent+"-login");try Data(script.utf8).write(to:file);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
            let executable=home.appendingPathComponent("bin/"+agent)
            let normal="#!/bin/zsh -f\nprint 'SYNTHETIC CLI READY'\ntouch '\(root.path)/started-\(agent)'\nread -r command\n"
            try Data(normal.utf8).write(to:executable);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        }
        return AgentAccountServices(home:home.path,check:{agent in
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("missing-"+agent).path) {return AgentAccountState(agent:agent,phase:"missing")}
            return AgentAccountState(agent:agent,phase:FileManager.default.fileExists(atPath:root.appendingPathComponent("signed-"+agent).path) ? "authenticated":"signedOut")
        },launch:{agent in
            try ManagedPTY(cwd:home.path,program:"shell",command:[root.appendingPathComponent(agent+"-login").path],columns:240,rows:40,environment:["HOME":home.path,"ZDOTDIR":home.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"])
        })
    }
}
