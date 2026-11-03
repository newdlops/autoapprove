import Foundation

/// A status card is accepted only after this app requested a fresh /status.
/// No account text or terminal contents are persisted in the reservation.
public struct CodexStatusIdentity: Codable {
    public var counts:[String:Int]
    public var requested:Date
    public var threadID:String?
    public var fingerprint:String?
    public init(screen:String) {counts=Self.cards(screen);requested=Date()}
    public static func cards(_ screen:String)->[String:Int] {
        var result:[String:Int]=[:]
        let lines=screen.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:"│┃╭╮╰╯" )).trimmingCharacters(in:.whitespaces)}
        var card:[String]=[]
        func accept() {
            guard card.contains(where:{$0.hasPrefix("Model:")}),card.contains(where:{$0.hasPrefix("Directory:")}),card.contains(where:{$0.hasPrefix("Permissions:")}),card.contains(where:{$0.hasPrefix("Agents.md:")}) else{return}
            var ids:[String]=[]
            for (i,line) in card.enumerated() where line.hasPrefix("Session:") {
                var id=String(line.dropFirst("Session:".count)).trimmingCharacters(in:.whitespaces)
                var next=i+1
                while id.count<36,next<card.count,!card[next].isEmpty,card[next].allSatisfy({$0.isHexDigit || $0=="-"}) {id+=card[next];next+=1}
                if id.count==36,UUID(uuidString:id) != nil {ids.append(id.lowercased())}
            }
            if ids.count==1 {result[ids[0],default:0]+=1}
        }
        for line in lines {
            if line.hasPrefix(">_ OpenAI Codex (v") {accept();card=[line]}
            else if !card.isEmpty {
                if line.hasPrefix("›") || line.hasPrefix("»") {accept();card=[]}
                else {card.append(line)}
            }
        }
        accept();return result
    }
    public func freshThread(in screen:String)->String? {
        let now=Self.cards(screen),fresh=now.keys.filter{now[$0,default:0]>counts[$0,default:0]}
        return fresh.count==1 ? fresh[0]:nil
    }
    public mutating func identify(_ screen:String)->Bool {
        guard let thread=freshThread(in:screen) else{return false}
        threadID=thread;fingerprint=PromptDetector.fingerprint(screen);return true
    }
    public func matches(_ screen:String,thread:String)->Bool {
        threadID==thread && fingerprint==PromptDetector.fingerprint(screen)
    }
}
