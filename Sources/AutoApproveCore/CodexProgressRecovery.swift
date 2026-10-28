import Foundation

public struct CodexProgressRecovery:Codable,Equatable,Sendable {
    public enum Phase:String,Codable,Sendable {case watching,interrupting,waiting,asking,requested,review}
    public var phase:Phase
    public var lastProgressAt:Date
    public var checkedAt:Date?
    public var checks:Int
    public var detail:String
    public var historyAvailable:Bool
    public init(phase:Phase = .watching,lastProgressAt:Date,checkedAt:Date?=nil,checks:Int=0,detail:String,historyAvailable:Bool=false) {
        self.phase=phase;self.lastProgressAt=lastProgressAt;self.checkedAt=checkedAt;self.checks=checks;self.detail=detail;self.historyAvailable=historyAvailable
    }
    public static let timeout:TimeInterval=30*60
    public static let prompt="진행 확인 요청입니다. 지금까지 실제로 완료한 변경과 검증 결과, 막힌 지점과 다음 단계를 짧게 알려주세요. 기존 작업 내용과 요청을 유지하고, 가능한 다음 단계부터 이어서 진행하세요."
}

/// Silence is a recovery heuristic, never proof that a model has stopped.
public struct CodexProgressTracker:Sendable {
    public private(set) var status:CodexProgressRecovery
    private var fingerprint:String
    private var generation:String
    private var observedAt:Date
    private var historyToken:String?
    public init(fingerprint:String,generation:String,at:Date,historyToken:String?=nil,previous:CodexProgressRecovery?=nil) {
        self.fingerprint=fingerprint;self.generation=generation;self.observedAt=at;self.historyToken=historyToken
        status = .init(lastProgressAt:at,detail:"30분 동안 진척 신호가 없으면 진행 상황을 확인합니다.",historyAvailable:historyToken != nil)
        if let previous {
            status.checks=previous.checks;status.checkedAt=previous.checkedAt
            if [.interrupting,.waiting,.asking,.review].contains(previous.phase) {
                status.phase = .review;status.detail="이전 진행 확인의 전달 결과를 확인해주세요. 자동으로 같은 입력을 다시 보내지 않습니다."
            }
        }
    }
    public mutating func observe(fingerprint:String,generation:String,at now:Date,historyToken:String?=nil) {
        let gap=now.timeIntervalSince(observedAt)
        let reset=generation != self.generation || gap<0 || gap>45
        let changed=fingerprint != self.fingerprint || historyToken != self.historyToken
        if reset || changed {status.lastProgressAt=now;if reset {status.checks=0;status.checkedAt=nil}}
        if status.phase == .requested,changed {status.phase = .watching;status.detail="새 출력 또는 기록 갱신을 감지했습니다. 진척 감시를 계속합니다."}
        if status.phase == .review,changed {status.phase = .watching;status.checks=0;status.detail="새 진척 신호를 확인해 감시를 다시 시작했습니다."}
        self.fingerprint=fingerprint;self.generation=generation;observedAt=now;self.historyToken=historyToken
        status.historyAvailable=historyToken != nil
    }
    public func isDue(at now:Date,timeout:TimeInterval=CodexProgressRecovery.timeout)->Bool {
        [.watching,.requested].contains(status.phase) && status.checks<3 && now.timeIntervalSince(observedAt)<=6 &&
            now.timeIntervalSince(status.lastProgressAt)>=timeout && (status.checkedAt.map {now.timeIntervalSince($0)>=timeout} ?? true)
    }
    public mutating func set(_ phase:CodexProgressRecovery.Phase,detail:String,at:Date?=nil) {
        status.phase=phase;status.detail=detail
        if let at {status.checkedAt=at;status.checks+=1;status.lastProgressAt=at}
    }
}

public enum CodexProgressScreen {
    /// The empty composer must be visible even while Working is displayed.
    public static func workingFingerprint(_ raw:String)->String? {
        let tail=ActivityDetector.nonemptyTail(raw).map {String($0.prefix(2048))}.joined(separator:"\n")
        guard ActivityDetector.detect(tail,agent:.codex).phase == .working,
              !RemoteMessageReadiness.hasMenu(tail,agent:.codex),emptyComposer(tail) else {return nil}
        let rows=ActivityDetector.nonemptyTail(tail).map {line -> String in
            var text=String(line.prefix(2048))
            text=String(text.unicodeScalars.drop(while:{(0x2800...0x28ff).contains($0.value)||CharacterSet.whitespaces.contains($0)}))
            if text.localizedCaseInsensitiveContains("esc to interrupt") || text.localizedCaseInsensitiveContains("tab to queue") {
                text=text.replacingOccurrences(of:#"\([^\n]*(?:esc to interrupt|tab to queue)[^\n]*\)"#,with:"(busy)",options:[.regularExpression,.caseInsensitive])
                text=text.replacingOccurrences(of:#"\b\d+(?:\.\d+)?\s*(?:ms|s|secs?|m|mins?|h|hrs?)\b"#,with:"time",options:.regularExpression)
            }
            return text
        }
        return PromptDetector.fingerprint(rows.joined(separator:"\n"))
    }
    public static func emptyComposer(_ raw:String)->Bool {
        let rows=ActivityDetector.nonemptyTail(raw)
        guard let line=rows.last(where:{$0.hasPrefix("›")||$0.hasPrefix("»")}) else {return false}
        let text=String(line.dropFirst()).trimmingCharacters(in:.whitespaces)
        return text.isEmpty || text.range(of:#"^(?:Ask Codex to do anything|Ask anything|Explain this codebase|Summarize recent commits|Find and fix a bug in @filename|Write tests for @filename|Improve documentation in @filename|Implement \{feature\}|Use /skills to list available skills)$"#,options:.regularExpression) != nil
    }
    public static func ready(_ raw:String)->Bool {
        ActivityDetector.detect(raw,agent:.codex).phase == .idle && emptyComposer(raw) && !RemoteMessageReadiness.hasMenu(raw,agent:.codex)
    }
}
