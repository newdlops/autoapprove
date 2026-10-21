import Foundation
import CoreFoundation
import CryptoKit
import Darwin
import AutoApproveCore

@main struct CapacityPrefixCheck {
 static func check(_ condition:Bool,_ message:String) throws {if !condition {throw AppError.message(message)}}
 static func native(_ text:String)->String {String(decoding:Array(text.utf8),as:UTF8.self)}
 static func foreign(_ text:String)->String {
  let units=Array(text.utf16),value=CFStringCreateWithCharacters(kCFAllocatorDefault,units,units.count)!
  return unsafeBitCast(value,to:NSString.self) as String
 }
 static func cocoa(_ text:String)->String {NSAppleEventDescriptor(string:text).stringValue!}
 static func cpu()->Double {var r=rusage();getrusage(RUSAGE_SELF,&r);return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1_000_000}
 static func run() throws {
  var cases=0,hash=SHA256()
  func compare(_ text:String,_ agent:AgentKind)throws {
   let lhs=BaselineCapacityProbe.classify(text,agent:agent),rhs=CandidateCapacityProbe.classify(text,agent:agent)
   try check(lhs==rhs,"Classifier differs at synthetic case \(cases)")
   hash.update(data:Data((String(cases)+":"+(lhs?.rawValue ?? "none")+"\n").utf8));cases += 1
  }
  let explicit:[(String,AgentKind,SessionInterruption.Kind?)]=[
   ("■ Selected model is at capacity. Please try a different model.",.codex,.capacity),
   ("\t■selectedmodelisatcapacity.\u{3000}",.codex,.capacity),
   ("■ stream disconnected before completion: 403 unauthorized",.codex,.authentication),
   ("API Error: 402 billing_error",.claude,.configuration),
   ("■ stream disconnected before completion: network error",.codex,.transport),
   ("API Error: 503 overloaded",.claude,.api),
   ("■ A new provider wording",.codex,.api),
   ("ordinary history followed by ■ error",.codex,nil),
   ("API Error: network failure › user draft",.claude,nil)]
  let stores:[(String,(String)->String)]=[("native",native),("foreign",foreign),("cocoa",cocoa)]
  for (text,agent,expected) in explicit {for (_,store) in stores {
   try check(BaselineCapacityProbe.classify(store(text),agent:agent)==expected,"Released explicit expectation differs")
   try compare(store(text),agent)
  }}
  let prefixes=["","■","■ ","Note: ■ ","API Error:","⎿ API Error:","Error:","⎿ Error:","api error:","■\u{FE0F}","■\u{200D}"]
  let suffixes=["Selected model is at capacity. Please try a different model.","selectedmodelisatcapacity","Selected model is at capacity.",
   "stream disconnected before completion","network error 403 unauthorized","invalid_api_key 500","402 billing_error", "404 model_not_found",
   "429 overloaded", "An error occurred while processing your request", "some new provider wording", "\u{0060}\u{0060}\u{0060} network error", "connection reset › draft", "한글 e\u{301} 👩🏽‍💻"]
  let spaces=[" ","\t","\n","\r\n","\u{00A0}","\u{0085}","\u{2028}","\u{2029}","\u{3000}","\u{200D}"]
  for prefix in prefixes {for suffix in suffixes {for space in spaces {
   for text in [space+prefix+space+suffix+space,(space+prefix+space+suffix+space).uppercased()] {
    for agent in [AgentKind.codex,.claude,.shell] {for (_,store) in stores {try compare(store(text),agent)}}
   }
  }}}
  let variants:[[UniChar]]=[[0xd800],[0xdc00],[0xd800,0xd800],[0xdc00,0xdc00],[0xd800,0xdc00],[0xfffd],[0x20,0xd800,0x20]]
  for units in variants {for prefix in ["","■ ","API Error:"] {for agent in [AgentKind.codex,.claude,.shell] {
   let all=Array(prefix.utf16)+units+Array("network error 403".utf16)
   let value=CFStringCreateWithCharacters(kCFAllocatorDefault,all,all.count)!
   try compare(unsafeBitCast(value,to:NSString.self) as String,agent)
  }}}
  let digest=hash.finalize().map{String(format:"%02x",$0)}.joined()
  print("CORRECTNESS "+String(cases)+" "+digest);fflush(stdout)
  var workloads:[[String:Any]]=[],checksum=0
  for lines in [16,400] {for (storage,store) in stores {
   let body=String(repeating:"Synthetic ordinary output e\u{301} 👩🏽‍💻 /fixture/source.swift\n",count:lines)
   let modes:[(String,String,AgentKind)]=[
    ("ordinary",body,.codex),("noted-capacity","Note: "+body+CodexCapacityStop.message,.codex),
    ("leading-capacity","\t■selectedmodelisatcapacity. ",.codex),("capacity","■ "+CodexCapacityStop.message,.codex),
    ("transport","■ stream disconnected before completion: "+body,.codex),
    ("claude","API Error: 503 server_error "+body,.claude),
    ("auth","■ unauthorized 403 "+body,.codex),("config","■ billing_error 402 "+body,.codex),
    ("draft","■ network error › user draft "+body,.codex),("unknown","■ New provider wording "+body,.codex)]
   for (mode,raw,agent) in modes {
    let cell=store(raw);var trials:[[String:Any]]=[]
    for pair in 0..<4 {for candidate in pair.isMultiple(of:2) ? [false,true]:[true,false] {autoreleasepool {
     let beforeCPU=cpu(),beforeWall=ProcessInfo.processInfo.systemUptime
     for _ in 0..<32 {
      let value=candidate ? CandidateCapacityProbe.classify(cell,agent:agent):BaselineCapacityProbe.classify(cell,agent:agent)
      checksum += value == nil ? 0:1
     }
     trials.append(["candidate":candidate,"cpuSeconds":cpu()-beforeCPU,"wallSeconds":ProcessInfo.processInfo.systemUptime-beforeWall])
    }}}
    workloads.append(["mode":mode,"lines":lines,"storage":storage,"bytes":cell.utf8.count,"rounds":32,"trials":trials])
   }
  }}
  print(String(decoding:try JSONSerialization.data(withJSONObject:["correctnessCases":cases,"resultSHA256":digest,"workloads":workloads,"checksum":checksum,"originalInputs":0,"captures":0,"listeners":0],options:.sortedKeys),as:UTF8.self))
 }
 static func main()throws {try run()}
}
