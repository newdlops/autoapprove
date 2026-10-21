import Foundation
import Darwin
import AutoApproveCore

/// Only synthetic text and the production parser; no file, network or terminal.
@main private enum StatusParserBench {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() {throw AppError.message(message)}
    }
    static func usage() -> (cpu:Double,rss:Int) {
        var value=rusage();precondition(getrusage(RUSAGE_SELF,&value)==0)
        return (Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6,Int(value.ru_maxrss))
    }
    static func bounded(_ row: String, ending: String = "") -> String {
        let count=(1_048_576-ending.utf8.count)/row.utf8.count
        return String(repeating:row,count:count)+ending
    }
    static func fixture(_ mode:String) throws -> (String,LocalDashboardAddress.Status,Int) {
        switch mode {
        case "empty":return ("",.missing,2048)
        case "small":return ("127.0.0.1 localhost\n::1 localhost\n127.0.0.1 autoapprove\n::1 autoapprove\n",.ready,1024)
        case "blanks":return (String(repeating:"\n",count:1_048_576),.missing,1)
        case "comments":return (bounded("#x\n"),.missing,1)
        case "records":return (bounded("127.0.0.1 local.example # keep\n",ending:"::1 autoapprove\n"),.ready,1)
        case "long":return (String(repeating:"x",count:1_048_576),.missing,1)
        case "unicode","foreign":
            let source=bounded("# 한글 e\u{301}🙂\u{2028}",ending:"::1\u{2003}AUTOAPPROVE.\u{0085}")
            if mode=="unicode" {return (source,.ready,1)}
            let units=Array(source.utf16)
            let value=units.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) }
            return (value as String,.ready,1)
        default:throw AppError.message("Unknown parser workload")
        }
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {throw AppError.message("Expected one parser workload")}
        let mode=CommandLine.arguments[1],(text,expected,iterations)=try fixture(mode)
        let contiguous=text.utf8.withContiguousStorageIfAvailable {_ in true} ?? false
        if mode=="foreign" {try require(!contiguous,"The Cocoa workload must actually use noncontiguous UTF-8 storage")}
        let bytes=text.utf8.count
        let before=usage(),start=ProcessInfo.processInfo.systemUptime
        var matches=0
        for _ in 0..<iterations {
            let status=autoreleasepool {LocalDashboardAddress.status(in:text)}
            if status==expected {matches+=1}
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-start,after=usage()
        try require(matches==iterations,"Parser result changed")
        let result:[String:Any]=["mode":mode,"inputBytes":bytes,"iterations":iterations,"matchingStatuses":matches,
            "contiguousUTF8":contiguous,"cpuSeconds":after.cpu-before.cpu,"wallSeconds":elapsed,
            "peakResidentBytesBefore":before.rss,"peakResidentBytes":after.rss,"peakIncreaseBytes":after.rss-before.rss,
            "systemFileReads":0,"systemFileWrites":0,"originalInputs":0,"captures":0,
            "scope":"Actual Core parser, synthetic in-memory text. Input construction precedes measurement; one autorelease pool per parse. Not a file-read, whole-app or phone comparison."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
