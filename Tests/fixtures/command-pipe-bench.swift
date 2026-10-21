import Foundation
import Darwin
import AutoApproveCore

@main struct CommandPipeProbe {
    static func usage() -> rusage { var value=rusage(); getrusage(RUSAGE_SELF,&value); return value }
    static func cpu(_ value:rusage) -> Double {
        Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
    }
    static func main() throws {
        let mode=CommandLine.arguments[1],helper=CommandLine.arguments[2],root=CommandLine.arguments[3]
        let counts:[String:(Int,Int)]=["empty":(0,0),"small":(4096,1024),"stdout":(33_554_432,0),"stderr":(0,8_388_608),"both":(8_388_608,8_388_608)]
        var arguments:[String],input:Data?,timeout:TimeInterval=5
        let unicode=String(repeating:"한글 e\u{301} 👨‍👩‍👧‍👦 literal $() `x`\0\n",count:512)
        if let count=counts[mode] { arguments = mode=="empty" ? ["empty"] : ["bytes",String(count.0),String(count.1)] }
        else if mode=="unicode" {arguments=["echo"];input=Data(unicode.utf8)}
        else if mode=="hold" {arguments=["hold",root+"/child.pid"];timeout=1.0}
        else if mode=="timeout" {arguments=["sleep","2400"];timeout=0.05}
        else {fatalError("Unknown owned fixture mode")}
        for _ in 0..<2 {let warm=try CommandRunner.run(helper,["empty"],timeout:3);precondition(warm.status==0)}
        let before=usage(),start=ProcessInfo.processInfo.systemUptime
        var results:[CommandResult]=[],failure:String?
        let calls = ["empty","small","unicode"].contains(mode) ? 5 : 1
        do {for _ in 0..<calls {results.append(try CommandRunner.run(helper,arguments,timeout:timeout,input:input))}}
        catch {failure=error.localizedDescription}
        let wall=ProcessInfo.processInfo.systemUptime-start,after=usage()
        var report:[String:Any]=["mode":mode,"timeout":timeout,"wallSeconds":wall,"cpuSeconds":cpu(after)-cpu(before),
            "beforePeakResidentBytes":before.ru_maxrss,"peakResidentBytes":after.ru_maxrss,
            "peakIncreaseBytes":max(0,after.ru_maxrss-before.ru_maxrss),"threw":failure != nil,
            "originalInputs":0,"captures":0,"systemConfigurationChanges":0,"ownedWarmupChildren":2,"ownedTimedCommands":calls,"successfulResults":results.count]
        for result in results {
            report["status"]=result.status;report["stdoutBytes"]=result.output.utf8.count;report["stderrBytes"]=result.error.utf8.count
            if let count=counts[mode] {
                precondition(result.status==0&&result.output.utf8.count==count.0&&result.error.utf8.count==count.1)
                precondition(result.output.utf8.allSatisfy{$0==97}&&result.error.utf8.allSatisfy{$0==101})
            } else if mode=="unicode" {precondition(result.output==unicode&&result.status==0)}
            else if mode=="hold" {precondition(result.output=="parent\nchild\n"&&result.status==0)}
        }
        if let failure {report["failure"]=failure}
        if mode=="timeout" {precondition(failure != nil)}
        if mode=="hold",let text=try? String(contentsOfFile:root+"/child.pid",encoding:.utf8),let pid=Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)) {
            report["ownedDescendantPID"]=pid
            report["descendantHasAtMost2400msWork"]=true
        }
        report["scope"]="Actual immutable Core CommandRunner with a short-lived owned C fixture, not original terminals, real helpers, GUI or LAN. Input/validation construction is outside timing; process peak includes preparation."
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
