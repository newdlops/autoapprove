import Foundation
import AutoApproveCore

@main struct Check {
    static func main() throws {
        let app = URL(fileURLWithPath: "/Applications/AutoApprove.app")
        let plan = try JSONSerialization.jsonObject(with: Data(TerminalInputInstaller.prepare(app: app).utf8)) as! [String: Any]
        precondition(plan["registration"] as? String == "Accessibility")
        precondition(plan["privilegedService"] as? Bool == false && plan["administratorShell"] as? Bool == false)
        precondition(plan["requiresAccessibility"] as? Bool == true && plan["application"] as? String == app.path)
        precondition(TerminalInputStatus.available.message.contains("손쉬운 사용"))
        precondition(TerminalInputStatus.notInstalled.message.contains("손쉬운 사용"))
        print("PASS: CLI preparation requires Accessibility and explicitly disables privileged services and administrator installation; no setup or input performed.")
    }
}
