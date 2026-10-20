// Synthetic AX handles and injected replies never read a user's UI or request permissions.
import AppKit
import ApplicationServices
import Darwin
import AutoApproveCore

extension TerminalWindowBounds {
    init(x: Double, y: Double, width: Double, height: Double) {
        self = try! JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject:
            ["x":x,"y":y,"width":width,"height":height]))
    }
}

private func key(_ element: AXUIElement) -> UInt { UInt(bitPattern:Unmanaged.passUnretained(element).toOpaque()) }
private func point(_ x: Double, _ y: Double) -> AXValue { var value=CGPoint(x:x,y:y);return AXValueCreate(.cgPoint,&value)! }
private func size(_ width: Double, _ height: Double) -> AXValue { var value=CGSize(width:width,height:height);return AXValueCreate(.cgSize,&value)! }
private func range(_ location: Int, _ length: Int) -> AXValue { var value=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&value)! }
private func unsupported() -> AXValue { var value=AXError.attributeUnsupported;return AXValueCreate(.axError,&value)! }

private struct Tree {
    let elements=(0..<12).map { AXUIElementCreateApplication(Int32(900_000+$0)) }
    var values: [UInt:[String:Any]] = [:]
    let screen="한글 e\u{301} 🧪\n"
    let text="scrollback\n한글 e\u{301} 🧪\n"
    let bounds=TerminalWindowBounds(x:80,y:110,width:640,height:400)
    init() {
        values[key(elements[0])]=[kAXWindowsAttribute:Array(elements[1...4])]
        for index in 1...4 {
            values[key(elements[index])]=[kAXTitleAttribute:"fixture-\(index)",kAXPositionAttribute:point(Double(80+(index-1)*100),110),
                kAXSizeAttribute:size(640,400),kAXRoleAttribute:kAXWindowRole,kAXChildrenAttribute:index==1 ? [elements[5],elements[6]] : []]
        }
        for index in 5...10 {
            values[key(elements[index])]=[kAXRoleAttribute:kAXGroupRole,kAXChildrenAttribute:index==5 ? [elements[7],elements[8]] : []]
        }
        values[key(elements[7])]?[kAXChildrenAttribute]=[elements[9],elements[10]]
        values[key(elements[10])]?[kAXChildrenAttribute]=[elements[11]]
        values[key(elements[11])]=[kAXRoleAttribute:kAXTextAreaRole,kAXChildrenAttribute:[AXUIElement](),kAXValueAttribute:text,
            kAXSelectedTextRangeAttribute:range((text as NSString).length-1,0),
            kAXVisibleCharacterRangeAttribute:range(("scrollback\n" as NSString).length,(screen as NSString).length)]
    }
    mutating func set(_ index: Int, _ attribute: String, _ value: Any?) { values[key(elements[index])]?[attribute]=value }
}

private func cpu() -> Double {
    var value=rusage();getrusage(RUSAGE_SELF,&value)
    return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
}
@main struct TerminalCursorReadCheck {
    static func main() throws {
        var cases=0, baselineCases=0, example:[String:Any]=[:]
        for title in [nil,"fixture-1","wrong-title"] as [String?] {
            for variant in 0..<22 {
                var tree=Tree()
                switch variant {
                case 1: tree.set(1,kAXPositionAttribute,point(85,110))
                case 2: tree.set(1,kAXSizeAttribute,size(645,400))
                case 3: tree.set(2,kAXPositionAttribute,point(80,110));tree.set(2,kAXTitleAttribute,"fixture-1")
                case 4: tree.set(1,kAXPositionAttribute,unsupported())
                case 5: tree.set(1,kAXSizeAttribute,NSNull())
                case 6: tree.set(11,kAXSelectedTextRangeAttribute,range((tree.text as NSString).length-1,1))
                case 7: tree.set(11,kAXSelectedTextRangeAttribute,unsupported())
                case 8: tree.set(11,kAXVisibleCharacterRangeAttribute,NSNull())
                case 9: tree.set(11,kAXValueAttribute,42)
                case 10: tree.set(10,kAXChildrenAttribute,[AXUIElement]())
                case 11: tree.set(7,kAXRoleAttribute,unsupported())
                case 12: tree.set(6,kAXRoleAttribute,kAXTextAreaRole);tree.set(6,kAXValueAttribute,tree.text);tree.set(6,kAXSelectedTextRangeAttribute,range((tree.text as NSString).length-1,0));tree.set(6,kAXVisibleCharacterRangeAttribute,NSNull())
                case 13: tree.set(1,kAXPositionAttribute,point(81.99,111.99))
                case 14: tree.set(1,kAXPositionAttribute,point(82,110))
                case 15: tree.set(11,kAXChildrenAttribute,unsupported())
                case 16: tree.set(11,kAXSelectedTextRangeAttribute,range(-1,0))
                case 17: tree.set(11,kAXVisibleCharacterRangeAttribute,range(99_999,1))
                case 18: tree.set(0,kAXWindowsAttribute,NSNull())
                case 19: tree.set(1,kAXChildrenAttribute,NSNull())
                case 20: tree.set(11,kAXSelectedTextRangeAttribute,"invalid")
                case 21: tree.set(11,kAXVisibleCharacterRangeAttribute,unsupported())
                default: break
                }
                var calls=0, fieldReads=0, textBatches=0
                let deadline=Date().addingTimeInterval(10)
                func read(_ element: AXUIElement, _ names: [String]) -> [Any]? {
                    guard Date()<deadline else { return nil }
                    calls+=1;fieldReads+=names.count
                    if names.contains(kAXValueAttribute) {
                        precondition(names == [kAXValueAttribute,kAXSelectedTextRangeAttribute,kAXVisibleCharacterRangeAttribute]);textBatches+=1
                    }
                    return names.map { tree.values[key(element)]?[$0] ?? NSNull() }
                }
                let value=TerminalCursorReader.accessibilitySnapshot(screen:tree.screen,title:title,bounds:tree.bounds,
                    application:tree.elements[0],deadline:deadline,attributes:read)
                if title=="wrong-title" || [1,2,3,4,5,6,7,9,10,12,14,16,18,19,20].contains(variant) {
                    precondition(value==nil,"Unexpected cursor: title \(title ?? "nil"), variant \(variant)")
                } else { precondition(value != nil && value?.screen==tree.screen,"Missing original cursor: variant \(variant)") }
                let currentCalls=calls, currentFields=fieldReads
                #if CURSOR_BASELINE
                calls=0;fieldReads=0;textBatches=0
                let previous=BaselineCursorReader.accessibilitySnapshot(screen:tree.screen,title:title,bounds:tree.bounds,
                    application:tree.elements[0],deadline:deadline,attributes:read)
                precondition(value==previous,"Baseline mismatch: title \(title ?? "nil"), variant \(variant)")
                baselineCases+=1
                if variant==0 && title==nil { example=["beforeCalls":calls,"afterCalls":currentCalls,"beforeFields":fieldReads,"afterFields":currentFields] }
                #else
                if variant==0 && title==nil { example=["afterCalls":currentCalls,"afterFields":currentFields] }
                #endif
                cases+=1
            }
        }
        let transportTree=Tree()
        var transportCases=0
        for failure in [[kAXWindowsAttribute],[kAXPositionAttribute,kAXSizeAttribute],[kAXRoleAttribute,kAXChildrenAttribute],
                        [kAXValueAttribute,kAXSelectedTextRangeAttribute,kAXVisibleCharacterRangeAttribute]] {
            for truncated in [false,true] {
                let value=TerminalCursorReader.accessibilitySnapshot(screen:transportTree.screen,title:nil,bounds:transportTree.bounds,
                    application:transportTree.elements[0],deadline:.distantFuture) { element,names in
                    let fields=names.map { transportTree.values[key(element)]?[$0] ?? NSNull() }
                    if names==failure { return truncated ? Array(fields.dropLast()) : nil }
                    return fields
                }
                precondition(value==nil);transportCases+=1
            }
        }
        var dense=Tree()
        let children=(0..<600).map { AXUIElementCreateApplication(Int32(910_000+$0)) }
        dense.set(1,kAXChildrenAttribute,children)
        var denseCalls=0
        let bounded=TerminalCursorReader.accessibilitySnapshot(screen:dense.screen,title:nil,bounds:dense.bounds,
            application:dense.elements[0],deadline:.distantFuture) { element,names in
            denseCalls+=1;return names.map { dense.values[key(element)]?[$0] ?? NSNull() }
        }
        precondition(bounded==nil && denseCalls==261,"The 256-element traversal budget must remain bounded")
        let bounds=CGRect(x:80,y:110,width:640,height:400)
        let valid:[String:Any]=[kCGWindowNumber as String:UInt32(17),kCGWindowOwnerPID as String:Int32(42),kCGWindowIsOnscreen as String:true,kCGWindowBounds as String:bounds.dictionaryRepresentation]
        var metadataCases=0
        for variant in 0..<10 {
            var window=valid
            switch variant {
            case 1: window[kCGWindowNumber as String]=UInt32(18)
            case 2: window[kCGWindowOwnerPID as String]=Int32(43)
            case 3: window[kCGWindowIsOnscreen as String]=false
            case 4: window.removeValue(forKey:kCGWindowIsOnscreen as String)
            case 5: window[kCGWindowBounds as String]="invalid"
            case 6: window[kCGWindowBounds as String]=CGRect(x:0,y:0,width:0,height:0).dictionaryRepresentation
            case 7: window.removeValue(forKey:kCGWindowOwnerPID as String)
            case 8: window[kCGWindowIsOnscreen as String]="true"
            case 9: window.removeValue(forKey:kCGWindowNumber as String)
            default: break
            }
            precondition(TerminalCursorReader.visibleWindowBounds([window],windowID:17,ownerPID:42)==(variant==0 ? bounds : nil))
            metadataCases+=1
        }
        precondition(TerminalCursorReader.windowInfo(windowID:0).isEmpty)
        var report:[String:Any]=["syntheticCases":cases,"baselineEquivalentCases":baselineCases,"metadataCases":metadataCases,
            "transportFailureCases":transportCases,"boundedTraversalQueries":denseCalls,"healthyNativeRead":example,"liveAXQueries":0]
        if CommandLine.arguments.contains("--live-window-bench") { report["liveWindowMetadata"]=try liveWindowBench() }
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
    static func liveWindowBench() throws -> [String:Any] {
        func all() -> [[String:Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? [] }
        let windows=all()
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.Terminal").first,
              let window=windows.first(where:{ $0[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier }),
              let id=window[kCGWindowNumber as String] as? UInt32 else { throw AppError.message("A visible Terminal window is needed for the metadata-only benchmark") }
        var trials:[[String:Any]]=[]
        for pair in 0..<3 {
            for kind in pair.isMultiple(of:2) ? ["all","target"] : ["target","all"] {
                func read() -> [[String:Any]] { kind=="all" ? all() : TerminalCursorReader.windowInfo(windowID:id) }
                for _ in 0..<5 { _=read() }
                let before=cpu(),began=ProcessInfo.processInfo.systemUptime
                var dictionaries=0
                for _ in 0..<200 {
                    let values=read();dictionaries+=values.count
                    precondition(TerminalCursorReader.visibleWindowBounds(values,windowID:id,ownerPID:app.processIdentifier) != nil)
                    if kind=="target" { precondition(values.count==1) }
                }
                trials.append(["pair":pair,"kind":kind,"iterations":200,"dictionaries":dictionaries,
                    "cpuMS":(cpu()-before)*1_000,"wallMS":(ProcessInfo.processInfo.systemUptime-began)*1_000])
            }
        }
        return ["initialWindows":windows.count,"trials":trials]
    }
}
