import Foundation

package struct TerminalGroupGoal: Codable {
    var revision = UUID().uuidString
    var action: String
    var objective: String?
    var delivery: String

    package static func command(agent: AgentKind, action: String, objective: String?) throws -> String {
        guard agent == .claude || agent == .agy else { throw RemoteHTTPError(400, "대상 CLI를 확인해주세요.") }
        if ["pause","clear"].contains(action) {
            return agent == .claude ? "/goal clear" : "Cancel the current goal and stop working toward it."
        }
        guard ["set","create","edit","resume"].contains(action), let objective, !objective.isEmpty,
              objective.count <= SessionGroupOrchestration.maximumTaskLength,
              objective.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }),
              SessionGroupOrchestration.commandPrefix(objective) == nil,
              agent != .claude || !["clear","stop","off","reset","none","cancel"].contains(objective.lowercased()) else {
            throw RemoteHTTPError(400, "한 줄로 된 Goal 목표를 지정해주세요. CLI 명령과 Goal 해제 예약어는 목표로 사용할 수 없습니다.")
        }
        let text = "/goal " + objective
        try RemoteTerminalInput(kind:.message,text:text).validate()
        return text
    }
}

package struct ClaudeGroupGoalEvidence {
    package var objective: String?
    package var revision: String

    package static func read(_ bytes: Data, id: String, complete: Bool) -> Self? {
        var evidence: Self? = complete ? Self(objective:nil,revision:"none") : nil
        for line in bytes.split(separator:10) where line.range(of:Data("goal".utf8)) != nil {
            guard let row = (try? JSONSerialization.jsonObject(with:Data(line))) as? JSONObject,
                  row["isSidechain"] as? Bool != true, (row["sessionId"] as? String)?.lowercased() == id,
                  let revision = row["uuid"] as? String, UUID(uuidString:revision) != nil else { continue }
            if row["type"] as? String == "attachment", let entry = row["attachment"] as? JSONObject,
               entry["type"] as? String == "goal_status" {
                if entry["sentinel"] as? Bool == true, entry["met"] as? Bool == false, let condition = entry["condition"] as? String {
                    evidence = Self(objective:condition,revision:revision)
                } else if entry["met"] as? Bool == true || entry["cleared"] as? Bool == true || entry["failed"] as? Bool == true {
                    evidence = Self(objective:nil,revision:revision)
                }
            } else if row["type"] as? String == "system", row["subtype"] as? String == "local_command",
                      (row["commandRun"] as? JSONObject)?["command"] as? String == "goal",
                      let content = row["content"] as? String, content.hasPrefix("<local-command-stdout>Goal cleared:") || content.hasPrefix("<local-command-stdout>No goal set") {
                evidence = Self(objective:nil,revision:revision)
            }
        }
        return evidence
    }
}
