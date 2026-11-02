import Foundation
import Darwin
import AutoApproveCore

/// Opt-in external transport regression. Only a synthetic, authenticated gateway
/// is published; no engine, real session, account or existing tunnel is loaded.
@main struct NativeFallbackCheck {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),wrapper=CommandLine.arguments[2]
  let events=root.appendingPathComponent("events.jsonl")
  let controller=RemoteTunnelController(directory:root,handler:{request in
   guard request.method=="GET",request.path=="/api/fixture" else {return .init(status:403,body:Data())}
   return .init(body:Data("synthetic transport fixture".utf8),contentType:"text/plain")
  },recovery:RemoteNetworkRecovery(observesSystem:false),onStatus:{_ in})
  defer {controller.stop(waitForExit:true)}
  var config=RemoteTunnelConfiguration();config.provider = .quick;config.executable=wrapper
  try await controller.start(config)
  let began=ProcessInfo.processInfo.systemUptime
  var observations:[[String:Any]]=[]
  while ProcessInfo.processInfo.systemUptime-began<55 {
   if let data=try? String(contentsOf:events,encoding:.utf8) {
    observations=data.split(separator:"\n").compactMap {try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
   }
   if observations.contains(where:{$0["kind"] as? String=="fallback-http2" || $0["kind"] as? String=="registered-quic"}) {break}
   try await Task.sleep(for:.milliseconds(100))
  }
  let fallback=observations.first(where:{$0["kind"] as? String=="fallback-http2"})?["seconds"] as? Double
  let quic=observations.contains(where:{$0["kind"] as? String=="registered-quic"})
  let passed=fallback != nil || quic
  let value:[String:Any]=["passed":passed,"fallbackSeconds":fallback as Any? ?? NSNull(),"quicRegistered":quic,
   "quicTimeouts":observations.filter {$0["kind"] as? String=="quic-timeout"}.count,
   "elapsedSeconds":Int(ProcessInfo.processInfo.systemUptime-began),"userTerminalInputs":0,"userCredentialsUsed":false,
   "scope":"Production controller/gateway and official cloudflared over the current external route; QUIC may remain healthy, otherwise HTTP2 must be tried before the 60-second readiness watchdog. Does not assert HTTP2 TLS readiness or full relay health."]
  let data=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
  try data.write(to:root.appendingPathComponent("report.json"),options:.atomic)
  print(String(decoding:data,as:UTF8.self));fflush(stdout)
  controller.stop(waitForExit:true)
  if !passed {exit(1)}
 }
}
