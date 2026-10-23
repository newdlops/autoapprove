import Foundation
import Darwin
import AutoApproveCore

private func require(_ condition: Bool, _ detail: String) throws {
    guard condition else { throw AppError.message(detail) }
}
private func cpu() -> Double {
    var usage = rusage();getrusage(RUSAGE_SELF,&usage)
    return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
}
private func payload(_ labels:[String])->JSONObject {
    ["questions":[["question":"Continue with this request?","multiSelect":false,"options":labels.map{["label":$0]}]]]
}
private final class Context {
    let texts:[String:[String]] = [
        "plain-short":["Yes","No","Allow","Cancel","Don't allow","Allow for this session"],
        "plain-long":[String(repeating:"Unchanged ASCII local fixture context ",count:64)+"end"],
        "unicode-labels":[" 허용 (추천) ","e\u{301}","Don’t allow (esc)","  예!!"]
    ]
    let normalized:[String:[String]] = [
        "plain-short":["Yes","No","Allow","Cancel","Don't allow","Allow for this session"],
        "plain-long":[String(repeating:"Unchanged ASCII local fixture context ",count:64)+"end"],
        "unicode-labels":["허용","é","Don't allow","예"]
    ]
    let menus:[JSONObject] = [payload(["Yes","No"]),payload(["Allow","Allow for this session","Always allow","Cancel"]),payload(["Yes (y).","No"]),payload(["허용","항상 허용","거부"])]
    let answers:[String] = ["Yes","Allow","Yes (y).","허용"]
    let choices:[JSONObject] = [payload(["Yes, use staging","No, use production"]),payload(["First","Second"]),payload(["Allow preview","Allow production","Cancel"])]
    init() throws {
        for(name,values)in texts{for(index,value)in values.enumerated(){try require(BenchConfirmation.oracleClean(value).utf8.elementsEqual(normalized[name]![index].utf8),"Wrong cleanup fixture")}}
        for(index,input)in menus.enumerated(){try require(YesNoConfirmation.detect(input)?.answer==answers[index],"Wrong permission fixture")}
        for input in choices{try require(YesNoConfirmation.detect(input)==nil,"Task fixture was approved")}
    }
    func measure(_ name:String,rounds:Int,offset:Int)throws->[String:Any] {
        try require(rounds>0&&rounds<=16000&&offset>=0,"Invalid owned block")
        let initialCPU=cpu(),start=Date();var matched=0,checksum=0
        for step in 0..<rounds {
            try autoreleasepool {
                let index=offset+step
                if let values=texts[name],let expected=normalized[name] {
                    let position=index%values.count,result=BenchConfirmation.oracleClean(values[position])
                    try require(result.utf8.elementsEqual(expected[position].utf8),"Cleanup result changed")
                    checksum+=result.utf8.count
                }else if name=="permission-menus" {
                    let position=index%menus.count,result=YesNoConfirmation.detect(menus[position])?.answer
                    try require(result==answers[position],"Permission result changed");checksum+=result!.utf8.count
                }else if name=="task-choices" {
                    try require(YesNoConfirmation.detect(choices[index%choices.count])==nil,"Task choice was approved");checksum+=1
                }else{throw AppError.message("Unknown owned workload")}
                matched+=1
            }
        }
        let processCPU=cpu()-initialCPU,wall=Date().timeIntervalSince(start);var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        return["name":name,"rounds":rounds,"offset":offset,"matches":matched,"checksum":checksum,"cpuSeconds":processCPU,"wallSeconds":wall,"peakResidentBytes":usage.ru_maxrss]
    }
}
@main struct ConfirmationFixture {
    static let workloads=["plain-short":16000,"plain-long":4000,"unicode-labels":4000,"permission-menus":2000,"task-choices":2000]
    static func emit(_ value:[String:Any])throws{FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)+Data([10]))}
    static func main()async{
        var context:Context?
        do{for try await line in FileHandle.standardInput.bytes.lines{
            guard let data=line.data(using:.utf8),let input=try JSONSerialization.jsonObject(with:data)as?[String:Any],let op=input["op"]as?String else{throw AppError.message("Invalid owned control")}
            if op=="setup"{context=try Context();try emit(["op":"ready","workloads":workloads,"scope":"First3 use exact renamed source copies; permission/task cases use actual linked Core. Autorelease pools bound each operation."])}
            else if op=="measure",let name=input["name"]as?String,let rounds=input["rounds"]as?Int,let offset=input["offset"]as?Int,let context{try emit(["op":"measured","result":context.measure(name,rounds:rounds,offset:offset)])}
            else if op=="quit"{context=nil;try emit(["op":"closed"]);return}
            else{throw AppError.message("Unknown owned control")}
        }}catch{FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
    }
}
