import Foundation
import AutoApproveCore

@main struct TerminalProfileQueryScripts {
    static func main() throws {
        let entry=TerminalProfileEntry(title:"Query fixture",agent:"codex",cwd:"/tmp/profile-query-fixture",
            conversationID:"00000000-0000-4000-8000-000000000001",
            terminalTab:.init(window:UUID(),windowOrder:0,tabOrder:1,settingsName:"Pro",customTitle:"Query fixture"))
        let rows=try [1,20,128].map {count -> JSONObject in
            let anchor="/dev/ttys700",target="/dev/ttys\(700+count)",previous=(0..<count).map {"/dev/ttys\(700+$0)"}
            return ["existing":count,"anchor":anchor,"target":target,"previous":previous,
                "prepare":try TerminalProfileTabOpener.prepareScript(anchorTTY:anchor,settingsName:"Pro"),
                "confirm":try TerminalProfileTabOpener.confirmationScript(anchorTTY:anchor,windowID:77,previousTTYs:previous),
                "launch":try TerminalProfileLauncher.script(entry,targetTTY:target),
                "select":try TerminalProfileLauncher.selectionScript(anchor)]
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]),as:UTF8.self))
    }
}
