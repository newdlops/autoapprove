import Foundation
import AutoApproveCore

private func hookFixtureHelper(_ root:URL,_ parent:String) throws -> String {
    let file=root.appendingPathComponent(parent+"/AutoApprove.app/Contents/MacOS/autoapprove")
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to:file)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
    return file.path
}
private func hookSettings(_ url:URL) throws -> JSONObject {try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! JSONObject}
private func hookJSON(_ object:JSONObject) throws -> Data {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])}

extension ApprovalTests {
    func testHookRelocationMovesSameHomeWithBackupAndIdempotence() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-relocation-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let current=try hookFixtureHelper(root,"Applications literal '$()"),home=root.appendingPathComponent("data '$() home").path
        for oldExists in [false,true] {
            let old=root.appendingPathComponent("dist/AutoApprove.app/Contents/MacOS/autoapprove").path
            if oldExists {_ = try hookFixtureHelper(root,"dist")}
            let url=root.appendingPathComponent("settings.json")
            var original=HookInstaller.merged(["env":["KEEP":"unchanged"],"permissions":["deny":["Bash(secret *)"]]],executable:old,home:home)
            var groups=original["hooks"] as! [String:[JSONObject]]
            groups["StopFailure"]=[]
            groups["PreToolUse"]!.append(["matcher":"Bash","hooks":[["type":"command","command":"unrelated-helper","timeout":7]]])
            original["hooks"]=groups
            let before=try hookJSON(original);try before.write(to:url)
            let backup=try HookInstaller.upgradeTimeouts(executable:current,home:home,url:url)
            try expectNotNil(backup,"A moved bundled helper must be repaired even while the old build still exists")
            if let backup {try expectEqual(try Data(contentsOf:backup),before)}
            var expected=HookInstaller.merged(["env":["KEEP":"unchanged"],"permissions":["deny":["Bash(secret *)"]]],executable:current,home:home)
            var expectedGroups=expected["hooks"] as! [String:[JSONObject]];expectedGroups["StopFailure"]=[]
            expectedGroups["PreToolUse"]!.append(["matcher":"Bash","hooks":[["type":"command","command":"unrelated-helper","timeout":7]]]);expected["hooks"]=expectedGroups
            try expectEqual(try hookJSON(hookSettings(url)),try hookJSON(expected))
            try expectNil(try HookInstaller.upgradeTimeouts(executable:current,home:home,url:url))
        }
    }
    func testHookRelocationKeepsForeignDisabledAndNoncanonicalCommands() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-boundary-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let current=try hookFixtureHelper(root,"Applications"),home=root.appendingPathComponent("home").path
        let old=root.appendingPathComponent("dist/AutoApprove.app/Contents/MacOS/autoapprove").path,url=root.appendingPathComponent("settings.json")
        let cases:[JSONObject]=[
            HookInstaller.merged([:],executable:old,home:home+"-other"),
            HookInstaller.merged([:],executable:old),
            HookInstaller.merged([:],executable:root.appendingPathComponent("custom/autoapprove").path,home:home),
            HookInstaller.merged(["disableAllHooks":true],executable:old,home:home),
            ["hooks":["PreToolUse":[["matcher":"Bash","hooks":[["type":"command","command":"AUTOAPPROVE_HOME="+HookInstaller.quote(home)+" "+HookInstaller.quote(old)+"; echo foreign hook --autoapprove-managed"]]]]]]
        ]
        for original in cases {
            let before=try hookJSON(original);try before.write(to:url)
            try expectNil(try HookInstaller.upgradeTimeouts(executable:current,home:home,url:url))
            try expectEqual(try Data(contentsOf:url),before)
        }
        let foreignCommand="AUTOAPPROVE_HOME="+HookInstaller.quote(home+"-other")+" "+HookInstaller.quote(current)+" hook --autoapprove-managed"
        let foreign:[String:Any]=["hooks":["PreToolUse":[["matcher":"Bash","hooks":[["type":"command","command":foreignCommand,"timeout":1]]]]]]
        let foreignBefore=try hookJSON(foreign);try foreignBefore.write(to:url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable:current,home:home,url:url))
        try expectEqual(try Data(contentsOf:url),foreignBefore,"A shared executable does not give ownership of another data home")
        let before=try hookJSON(HookInstaller.merged([:],executable:old,home:home));try before.write(to:url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable:root.appendingPathComponent("missing/AutoApprove.app/Contents/MacOS/autoapprove").path,home:home,url:url))
        try expectEqual(try Data(contentsOf:url),before)
    }
    func testHookRelocationStartupScopesToEngineHome() throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-hook-engine-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let current=try hookFixtureHelper(root,"Applications"),home=root.appendingPathComponent("state"),url=root.appendingPathComponent("settings.json")
        let old=root.appendingPathComponent("dist/AutoApprove.app/Contents/MacOS/autoapprove").path
        let original=HookInstaller.merged([:],executable:old,home:home.path)
        try hookJSON(original).write(to:url)
        let engine=try ApprovalEngine(paths:AppPaths(directory:home),claudeRegistryReader:{_ in []},processReader:{[]})
        defer{engine.stop()}
        engine.upgradeClaudeHooks(executable:current,settingsURL:url)
        try expectEqual(try hookJSON(hookSettings(url)),try hookJSON(original),"An engine that has not acquired its bridge cannot rewrite hook paths")
        try engine.start(poll:false)
        engine.upgradeClaudeHooks(executable:current,settingsURL:url)
        try expectEqual(try hookJSON(hookSettings(url)),try hookJSON(HookInstaller.merged([:],executable:current,home:home.path)))
        let other=try ApprovalEngine(paths:AppPaths(directory:home),claudeRegistryReader:{_ in []},processReader:{[]})
        defer{other.stop()}
        var rejected=false
        do {try other.start(poll:false)} catch {rejected=true}
        try expect(rejected,"The private bridge belongs to the first engine")
        try hookJSON(original).write(to:url)
        other.upgradeClaudeHooks(executable:current,settingsURL:url)
        try expectEqual(try hookJSON(hookSettings(url)),try hookJSON(original),"A rejected duplicate cannot replace the active app's paths")
        engine.stop();engine.upgradeClaudeHooks(executable:current,settingsURL:url)
        try expectEqual(try hookJSON(hookSettings(url)),try hookJSON(original),"A stopped engine cannot migrate settings")
    }
}
