import Foundation
import Darwin
import AutoApproveCore

@main struct RiskWindowBenchmark {
    struct Workload { let name:String;let text:String;let rounds:Int;let expected:SystemCommandRisk.Kind? }
    static func cpu()->Double { var usage=rusage();getrusage(RUSAGE_SELF,&usage);return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000 }
    static func make() throws -> [Workload] {
        let ordinary=String(repeating:"Completed ordinary local project checks.\n",count:160)
        let mixed=String(repeating:"한글 ordinary e\u{301} 👩🏽‍💻 local project checks.\n",count:160)
        let foreign=NSAppleEventDescriptor(string:mixed).stringValue!
        guard ordinary.isContiguousUTF8 && mixed.isContiguousUTF8 && !foreign.isContiguousUTF8 else {
            throw AppError.message("Incorrect prebuilt storage")
        }
        let workloads=[
            Workload(name:"short-negative",text:"npm test",rounds:20_000,expected:nil),
            Workload(name:"long-negative",text:ordinary,rounds:1_000,expected:nil),
            Workload(name:"unicode-negative",text:mixed,rounds:1_000,expected:nil),
            Workload(name:"foreign-negative",text:foreign,rounds:1_000,expected:nil),
            Workload(name:"late-positive",text:ordinary+"\nsudo id",rounds:1_000,expected:.privileged),
            Workload(name:"unicode-positive",text:"ſudo id",rounds:10_000,expected:.privileged),
            Workload(name:"read-only-candidate",text:"cat ~/Library/LaunchAgents/a.plist",rounds:10_000,expected:nil),
            Workload(name:"short-positive",text:"sudo id",rounds:10_000,expected:.privileged),
            Workload(name:"single-token-negative",text:String(repeating:"fixture",count:1024),rounds:1_000,expected:nil),
            Workload(name:"blank-ascii",text:String(repeating:" \t\r\n",count:16384),rounds:100,expected:nil)
        ]

        return workloads
    }
    static func emit(_ value:[String:Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])+Data([10]))
    }
    @MainActor static func main() async {
        do {
            let workloads=try make()
            for row in workloads {guard SystemCommandRisk.detect(row.text)?.kind==row.expected else {throw AppError.message("Changed warm policy: "+row.name)}}
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let data=line.data(using:.utf8),let input=try JSONSerialization.jsonObject(with:data) as? [String:Any],let op=input["op"] as? String else {throw AppError.message("Invalid owned policy command")}
                if op=="setup" {
                    try emit(["op":"ready","workloads":workloads.map{["name":$0.name,"rounds":$0.rounds,"bytes":$0.text.utf8.count,"foreign":!$0.text.isContiguousUTF8] as [String:Any]}])
                }else if op=="measure" {
                    guard let name=input["name"] as? String,let rounds=input["rounds"] as? Int,rounds>0,rounds<=20000,let row=workloads.first(where:{$0.name==name}) else {throw AppError.message("Invalid policy block")}
                    let bytes=Array(row.text.utf8),storage=row.text.isContiguousUTF8
                    let beforeCPU=cpu(),before=Date();var matches=0
                    for _ in 0..<rounds {if SystemCommandRisk.detect(row.text)?.kind==row.expected {matches += 1}}
                    let wall=Date().timeIntervalSince(before),usedCPU=cpu()-beforeCPU
                    guard matches==rounds,row.text.utf8.elementsEqual(bytes),row.text.isContiguousUTF8==storage else {throw AppError.message("Changed exact policy or storage: "+name)}
                    var usage=rusage();getrusage(RUSAGE_SELF,&usage)
                    try emit(["op":"measured","result":["name":name,"rounds":rounds,"matches":matches,"cpuSeconds":usedCPU,"wallSeconds":wall,"bytes":bytes.count,"foreign":!storage,"peakResidentBytes":usage.ru_maxrss]])
                }else if op=="quit" {try emit(["op":"closed"]);return}
                else {throw AppError.message("Unknown policy operation")}
            }
        }catch{FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
    }
}
