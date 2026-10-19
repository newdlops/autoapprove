import Foundation
import AutoApproveCore

private func terminalCode(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
private func terminalList(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let result = NSAppleEventDescriptor.list()
    for value in values { result.insert(value, at: result.numberOfItems + 1) }
    return result
}
private func terminalStrings(_ values: [String]) -> NSAppleEventDescriptor { terminalList(values.map { .init(string: $0) }) }
private func terminalProperty(_ query: NSAppleEventDescriptor) -> UInt32 {
    query.forKeyword(terminalCode("seld"))?.typeCodeValue ?? 0
}
private func terminalTarget(_ query: NSAppleEventDescriptor) -> String? {
    query.forKeyword(terminalCode("from"))?.forKeyword(terminalCode("seld"))?
        .forKeyword(terminalCode("obj2"))?.stringValue
}
private func terminalBatchTargets(_ query: NSAppleEventDescriptor) -> [String]? {
    guard let predicate = query.forKeyword(terminalCode("from"))?.forKeyword(terminalCode("seld")),
          predicate.descriptorType == terminalCode("logi"),
          predicate.forKeyword(terminalCode("logc"))?.enumCodeValue == terminalCode("OR  "),
          let terms = predicate.forKeyword(terminalCode("term")), terms.numberOfItems > 1 else { return nil }
    return (1...terms.numberOfItems).compactMap { terms.atIndex($0)?.forKeyword(terminalCode("obj2"))?.stringValue }
}

extension ApprovalTests {
    func testNativeTerminalDiagnosticsTagExactSendWithoutRetainingSourceText() throws {
        let timing = RemoteTerminalPerformance()
        let reader = TerminalAppleEventReader(diagnostics:timing,purpose:.validation) { _,_ in
            throw NSError(domain:NSOSStatusErrorDomain,code:-1712,userInfo:[NSLocalizedDescriptionKey:"PRIVATE_SOURCE_TEXT"])
        }
        try expectThrows(try reader.screens(ttys:["/dev/PRIVATE_TTY"],includeTitles:false))
        let events = timing.snapshot().nativeReads!.events
        try expectEqual(events.count,1)
        try expectEqual(events.first?.purpose,.validation); try expectEqual(events.first?.query,.text)
        try expectEqual(events.first?.targets,1); try expectEqual(events.first?.failure,.timeout)
        let text = String(decoding:try JSONEncoder().encode(timing.snapshot()),as:UTF8.self)
        try expect(!text.contains("PRIVATE"))
    }

    func testNativeTerminalFirstTextSkipsAllPresentationQueries() throws {
        var queries = 0
        let raw = "원본 é 🙂\n\u{1b}[31mtext\u{1b}[0m\u{0}\n"
        let reader = TerminalAppleEventReader { query, _ in
            queries += 1
            try expectEqual(terminalProperty(query), terminalCode("pcnt"), "A cold text read must not wait for any title, window or cursor metadata")
            try expectEqual(terminalTarget(query), "/dev/first")
            return terminalStrings([raw])
        }
        let result = try reader.screens(ttys: ["/dev/first", "/dev/first"], includeTitles: false)
        try expectEqual(queries, 1)
        try expectEqual(result.screens.first?.contents, raw)
        try expectNil(result.screens.first?.title); try expectNil(result.screens.first?.cursor)
    }

    func testNativeTerminalPresentationBindsAndRechecksSelectedWindow() throws {
        for mode in ["visible", "changed", "ambiguous", "denied", "unselected"] {
            var metadata = 0, callbacks: [UInt32] = []
            let reader = TerminalAppleEventReader { query, _ in
                if terminalProperty(query) == terminalCode("pcnt") {
                    try expectEqual(terminalTarget(query), "/dev/first")
                    return terminalStrings(["original"])
                }
                metadata += 1
                try expectEqual(terminalProperty(query), terminalCode("ID  "))
                let window = query.forKeyword(terminalCode("from"))!
                try expectEqual(window.forKeyword(terminalCode("want"))?.typeCodeValue, terminalCode("cwin"))
                let predicate = window.forKeyword(terminalCode("seld"))!
                try expectEqual(predicate.forKeyword(terminalCode("obj2"))?.stringValue, "/dev/first")
                let tty = predicate.forKeyword(terminalCode("obj1"))!
                try expectEqual(terminalProperty(tty), terminalCode("ttty"))
                try expectEqual(terminalProperty(tty.forKeyword(terminalCode("from"))!), terminalCode("tcnt"))
                if mode == "denied" { throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
                let ids: [Int32] = mode == "unselected" ? [] : metadata == 2 && mode == "changed" ? [9] : [7, 8, 7]
                return terminalList(ids.map { .init(int32: $0) })
            }
            do {
                let result = try reader.screens(ttys: ["/dev/first"], includeTitles: false, presentation: { text, id in
                    callbacks.append(id)
                    if id == 8 && mode != "ambiguous" { return nil } // Hidden native tab group.
                    return TerminalTextSnapshot(screen: text, cursor: TerminalCursor(offset: 1))
                })
                try expect(mode != "denied", "A denied metadata read cannot return even an already read screen")
                try expectEqual(result.screens.first?.contents, "original")
                try expectEqual(result.screens.first?.cursor != nil, mode == "visible")
                try expectEqual(result.screens.first?.display != nil, mode == "visible")
                try expectEqual(metadata, ["visible", "changed"].contains(mode) ? 2 : 1)
                try expectEqual(Set(callbacks).count, callbacks.count, "Duplicate window IDs cannot duplicate Accessibility reads")
            } catch let error as TerminalAdapterError {
                try expectEqual(mode, "denied"); try expectEqual(error, .permissionDenied)
            }
        }
    }

    func testNativeTerminalReadUsesExactPredicatesAndPreservesText() throws {
        let ttys = (0..<20).map { "/dev/native-\($0)" }
        var contentTargets = [String](), queries = 0
        let raw = "한글 é 🙂\n\u{1b}[31moriginal\u{1b}[0m\u{0}\n"
        let reader = TerminalAppleEventReader(batchTitles: false, batchContents: false) { query, budget in
            queries += 1
            try expect(budget > 0 && budget <= 8)
            try expectEqual(query.descriptorType, terminalCode("obj "))
            try expectEqual(query.forKeyword(terminalCode("want"))?.typeCodeValue, terminalCode("prop"))
            let property = terminalProperty(query)
            if let tty = terminalTarget(query) {
                try expect(ttys.contains(tty), "No native query may address an unrelated TTY")
                let tab = query.forKeyword(terminalCode("from"))!
                try expectEqual(tab.forKeyword(terminalCode("want"))?.typeCodeValue, terminalCode("ttab"))
                try expectEqual(tab.forKeyword(terminalCode("form"))?.enumCodeValue, terminalCode("test"))
                let left = tab.forKeyword(terminalCode("seld"))!.forKeyword(terminalCode("obj1"))!
                try expectEqual(terminalProperty(left), terminalCode("ttty"))
                let windows = tab.forKeyword(terminalCode("from"))!
                try expectEqual(windows.forKeyword(terminalCode("seld"))?.descriptorType, terminalCode("abso"))
                if property == terminalCode("pcnt") { contentTargets.append(tty); return terminalList([terminalList([]), terminalStrings([raw + tty])]) }
                try expectEqual(property, terminalCode("titl"))
                return terminalStrings([tty == ttys[1] ? " Custom title " : ""])
            }
            if property == terminalCode("ID  ") { return terminalList((1...20).map { .init(int32: Int32($0)) }) }
            if property == terminalCode("ttty") { return terminalStrings(ttys) }
            try expectEqual(property, terminalCode("pnam"))
            return terminalStrings(ttys.indices.map { "Window \($0)" })
        }
        let result = try reader.screens(ttys: ttys + ttys)
        try expectEqual(contentTargets, ttys)
        try expectEqual(result.screens.map(\.contents), ttys.map { raw + $0 }, "Unicode, control characters and exact original text must survive without JSON/script conversion")
        try expectEqual(result.screens[0].title, "Window 0")
        try expectEqual(result.screens[1].title, "Custom title")
        try expectEqual(queries, 44, "Read contents/title per exact TTY and share four window metadata queries")
        try expect(result.failures.isEmpty)
        let beforeEmpty = queries
        let empty = try reader.screens(ttys: [])
        try expect(empty.screens.isEmpty)
        try expectEqual(queries, beforeEmpty)
    }

    func testNativeTerminalBatchesOnlyRequestedContentsAndTitlesWithStableIdentities() throws {
        let ttys = (0..<20).map { "/dev/batch-\($0)" }
        var queries = 0, contentBatches = 0, titleBatches = 0, identityBatches = 0, individualTargets = 0
        let reader = TerminalAppleEventReader { query, _ in
            queries += 1
            let property = terminalProperty(query)
            if let targets = terminalBatchTargets(query) {
                try expectEqual(targets, ttys, "Only unique enrolled TTYs may enter the OR predicate")
                let tabs = query.forKeyword(terminalCode("from"))!
                try expectEqual(tabs.forKeyword(terminalCode("want"))?.typeCodeValue, terminalCode("ttab"))
                let windows = tabs.forKeyword(terminalCode("from"))!
                try expectEqual(windows.forKeyword(terminalCode("seld"))?.descriptorType, terminalCode("abso"))
                let terms = tabs.forKeyword(terminalCode("seld"))!.forKeyword(terminalCode("term"))!
                for index in 1...terms.numberOfItems {
                    let comparison = terms.atIndex(index)!
                    try expectEqual(comparison.descriptorType, terminalCode("cmpd"))
                    try expectEqual(terminalProperty(comparison.forKeyword(terminalCode("obj1"))!), terminalCode("ttty"))
                }
                if property == terminalCode("ttty") { identityBatches += 1; return terminalList([terminalList([]), terminalStrings(ttys)]) }
                if property == terminalCode("pcnt") { contentBatches += 1; return terminalStrings(ttys.map { "Original\n\u{1b}[31m한글🙂\u{0}" + $0 }) }
                try expectEqual(property, terminalCode("titl"))
                titleBatches += 1
                return terminalList([terminalList([]), terminalStrings(ttys.indices.map { $0 == 1 ? " Custom 🧪 " : "" })])
            }
            if terminalTarget(query) != nil { individualTargets += 1; throw AppError.message("A verified batch must not fall back to a per-TTY read") }
            if property == terminalCode("ID  ") { return terminalList((1...20).map { .init(int32: Int32($0)) }) }
            if property == terminalCode("ttty") { return terminalStrings(ttys) }
            try expectEqual(property, terminalCode("pnam"))
            return terminalStrings(ttys.indices.map { "Window \($0)" })
        }
        let result = try reader.screens(ttys: ttys + ttys)
        try expectEqual(contentBatches, 1); try expectEqual(titleBatches, 1); try expectEqual(identityBatches, 4)
        try expectEqual(individualTargets, 0); try expectEqual(queries, 10, "Six contents/title batch sends plus four window metadata sends")
        try expectEqual(result.screens.map(\.contents), ttys.map { "Original\n\u{1b}[31m한글🙂\u{0}" + $0 })
        try expectEqual(result.screens[0].title, "Window 0"); try expectEqual(result.screens[1].title, "Custom 🧪")
        try expect(result.failures.isEmpty)
    }

    func testNativeTerminalDisablesStructurallyInvalidContentsBatch() throws {
        let ttys = (0..<4).map { "/dev/partial-batch-\($0)" }
        var unavailable = 0, batchContentReads = 0, exactReads = 0
        let reader = TerminalAppleEventReader(batchTitles: false,
            batchContents: true, contentsBatchUnavailable: { unavailable += 1 }) { query, _ in
            let property = terminalProperty(query)
            if terminalBatchTargets(query) != nil {
                if property == terminalCode("ttty") { return terminalStrings(ttys) }
                try expectEqual(property, terminalCode("pcnt"))
                batchContentReads += 1
                // Simulate Terminal returning an incomplete list. Exact reads
                // below remain safe, but this batch must not be retried later.
                return terminalStrings(["partial"])
            }
            guard let tty = terminalTarget(query) else { throw AppError.message("Expected exact TTY fallback") }
            try expectEqual(property, terminalCode("pcnt"))
            exactReads += 1
            return terminalStrings(["fresh " + tty])
        }
        let result = try reader.screens(ttys: ttys, includeTitles: false)
        try expectEqual(result.screens.map(\.contents), ttys.map { "fresh " + $0 })
        try expectEqual(batchContentReads, 1)
        try expectEqual(exactReads, ttys.count)
        try expectEqual(unavailable, 1)
        try expect(result.failures.isEmpty)
    }

    func testNativeTerminalKeepsSmallMultiTabReadsIndividual() throws {
        for count in 2...3 {
            let ttys = (0..<count).map { "/dev/small-batch-\($0)" }
            var queries = 0, contentReads = 0, titleReads = 0
            let reader = TerminalAppleEventReader(batchTitles:false,batchContents:false) { query, _ in
                queries += 1
                guard let tty = terminalTarget(query), ttys.contains(tty) else {
                    throw AppError.message("Small multi-tab reads should use exact TTY predicates")
                }
                if terminalProperty(query) == terminalCode("pcnt") {
                    contentReads += 1
                    return terminalStrings(["screen:" + tty])
                }
                try expectEqual(terminalProperty(query),terminalCode("titl"))
                titleReads += 1
                return terminalStrings(["title:" + tty])
            }
            let result = try reader.screens(ttys: ttys)
            try expectEqual(contentReads,count)
            try expectEqual(titleReads,count)
            try expectEqual(queries,count*2,"One exact get event per content/title beats or matches the three-event batch for \(count) TTYs")
            try expectEqual(result.screens.map(\.contents), ttys.map { "screen:" + $0 })
            try expectEqual(result.screens.map(\.title), ttys.map { "title:" + $0 })
            try expect(result.failures.isEmpty)
        }
    }

    func testNativeTerminalReadsTitlesOnlyForExpiredTTYs() throws {
        let ttys = (0..<3).map { "/dev/title-cache-\($0)" }
        var queries = 0, titleQueries = 0
        let reader = TerminalAppleEventReader { query, _ in
            queries += 1
            let property = terminalProperty(query)
            if let targets = terminalBatchTargets(query) {
                try expectEqual(targets,ttys,"The screen batch still reads every exact enrolled TTY")
                if property == terminalCode("ttty") { return terminalStrings(ttys) }
                try expectEqual(property,terminalCode("pcnt"))
                return terminalStrings(ttys.map { "screen:" + $0 })
            }
            guard let tty = terminalTarget(query) else { throw AppError.message("Expected an exact TTY query") }
            if property == terminalCode("pcnt") { return terminalStrings(["screen:" + tty]) }
            try expectEqual(tty,ttys[1],"Only the stale title's TTY may be queried")
            try expectEqual(property,terminalCode("titl"))
            titleQueries += 1
            return terminalStrings(["fresh title"])
        }
        let result = try reader.screens(ttys:ttys,titleTTYS:[ttys[1]])
        try expectEqual(result.screens.map(\.contents),ttys.map { "screen:" + $0 })
        try expectEqual(result.screens.map(\.title),[nil,"fresh title",nil])
        try expectEqual(titleQueries,1)
        try expectEqual(queries,4,"A stale title must not expand into title reads for the other tabs")
    }

    func testSlowBulkContentsIdentityQueryRequestsTemporaryPerTTYFallback() throws {
        let ttys = (0..<4).map { "/dev/slow-batch-\($0)" }
        for mode in ["fast", "slow", "timeout"] {
            var now = 0.0, identityReads = 0, fallbackRequests = 0
            let reader = TerminalAppleEventReader(timeout:8, clock:{now}, batchTitles:false,
                slowContentsBatch:{ fallbackRequests += 1 }) { query, _ in
                guard terminalBatchTargets(query) == ttys else { throw AppError.message("Only the exact enrolled TTYs may be batched") }
                switch terminalProperty(query) {
                case terminalCode("ttty"):
                    identityReads += 1
                    if identityReads == 1, mode != "fast" { now += 2 }
                    if identityReads == 1, mode == "timeout" { throw NSError(domain:NSOSStatusErrorDomain,code:-1712) }
                    return terminalStrings(ttys)
                case terminalCode("pcnt"): return terminalStrings(ttys.map { "screen:" + $0 })
                default: throw AppError.message("Unexpected Terminal batch property")
                }
            }
            if mode == "timeout" { try expectThrows(try reader.screens(ttys:ttys,includeTitles:false)) }
            else {
                let result = try reader.screens(ttys:ttys,includeTitles:false)
                try expectEqual(result.screens.map(\.contents),ttys.map { "screen:" + $0 })
            }
            try expectEqual(fallbackRequests,mode == "fast" ? 0 : 1,
                "Only a slow/timed-out bulk identity lookup should enter temporary exact-TTY mode")
        }
    }

    func testSlowBulkTitleQueriesRequestTemporaryTitleFallback() throws {
        let ttys = (0..<4).map { "/dev/slow-title-\($0)" }
        for slowRead in 0...3 {
            var now = 0.0, titleReads = 0, fallbackRequests = 0
            let reader = TerminalAppleEventReader(timeout:8, clock:{now}, batchContents:false,
                slowTitlesBatch:{ fallbackRequests += 1 }) { query, _ in
                let property = terminalProperty(query)
                if let targets = terminalBatchTargets(query) {
                    try expectEqual(targets, ttys)
                    guard property == terminalCode("ttty") || property == terminalCode("titl") else {
                        return terminalStrings(targets)
                    }
                    titleReads += 1
                    if titleReads == slowRead { now += 2 }
                    if property == terminalCode("ttty") { return terminalStrings(ttys) }
                    return terminalStrings(ttys.map { "title:" + $0 })
                }
                guard let tty = terminalTarget(query) else { throw AppError.message("Unexpected slow-title query") }
                if property == terminalCode("pcnt") { return terminalStrings(["fresh:" + tty]) }
                return terminalStrings([tty])
            }
            let result = try reader.screens(ttys:ttys)
            try expectEqual(titleReads,3)
            try expectEqual(fallbackRequests,slowRead == 0 ? 0 : 1)
            try expectEqual(result.screens.map(\.contents),ttys.map { "fresh:" + $0 })
        }
    }

    func testNativeTerminalTitleBatchRejectsUnstableAndUnsupportedMetadata() throws {
        let ttys = (0..<4).map { "/dev/batch-\($0)" }
        for mode in ["reordered", "duplicate", "count", "unknown", "unsupported", "malformed", "closed"] {
            var bulk = 0, exactTitles = 0, unavailable = 0
            let reader = TerminalAppleEventReader(titleBatchUnavailable: { unavailable += 1 }, batchContents: false) { query, _ in
                let property = terminalProperty(query)
                if let _ = terminalBatchTargets(query) {
                    bulk += 1
                    if mode == "unsupported" { throw NSError(domain: NSOSStatusErrorDomain, code: -1708) }
                    if mode == "closed" { throw NSError(domain: NSOSStatusErrorDomain, code: -1728) }
                    if property == terminalCode("titl") {
                        return terminalStrings(Array(repeating: "Unverified neighbour title", count: mode == "count" ? 3 : 4))
                    }
                    if mode == "malformed" { return .init(int32: 42) }
                    if mode == "duplicate" { return terminalStrings([ttys[0], ttys[0], ttys[2], ttys[3]]) }
                    if mode == "unknown" { return terminalStrings(ttys.dropLast() + ["/dev/unrelated"]) }
                    return terminalStrings(mode == "reordered" && bulk == 3 ? Array(ttys.reversed()) : ttys)
                }
                if ["unsupported", "malformed"].contains(mode) {
                    if property == terminalCode("ID  ") { return terminalList((1...4).map { .init(int32:Int32($0)) }) }
                    if property == terminalCode("ttty") { return terminalStrings(ttys) }
                    if property == terminalCode("pnam") { return terminalStrings(ttys.indices.map { "Window \($0)" }) }
                }
                guard let tty = terminalTarget(query) else { throw AppError.message("Missing exact fallback target for property \(property), mode \(mode), bulk \(bulk)") }
                try expect(ttys.contains(tty), "Fallback must preserve the exact original target")
                if property == terminalCode("titl") { exactTitles += 1; return terminalStrings(["Exact " + tty]) }
                try expectEqual(property, terminalCode("pcnt"))
                return terminalStrings(["Original " + tty])
            }
            let result = try reader.screens(ttys: ttys)
            try expectEqual(result.screens.map(\.contents), ttys.map { "Original " + $0 })
            let expectedTitles = ["unsupported", "malformed"].contains(mode)
                ? ttys.indices.map { "Window \($0)" } : ttys.map { "Exact " + $0 }
            try expectEqual(result.screens.map(\.title), expectedTitles)
            try expectEqual(exactTitles, ["unsupported", "malformed"].contains(mode) ? 0 : 4)
            try expect(result.failures.isEmpty)
            try expectEqual(unavailable, mode == "closed" ? 0 : 1,
                "Every unstable or unsupported bulk title result disables future bulk attempts for this Terminal PID")
            try expectEqual(bulk, ["unsupported", "closed"].contains(mode) ? 1 : 3)
        }
    }

    func testNativeTerminalTitleBatchStopsOnDenialDeadlineAndCancellation() async throws {
        let ttys = (0..<4).map { "/dev/batch-\($0)" }
        for status in [-1743, -1744, -1712] {
            var queries = 0, unavailable = 0
            let reader = TerminalAppleEventReader(titleBatchUnavailable: { unavailable += 1 }, batchContents: false) { _, _ in
                queries += 1
                if status != -1712 || queries == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: status) }
                return terminalStrings(["fresh content"])
            }
            var error: Error?
            do { _ = try reader.screens(ttys: ttys) } catch let caught { error = caught }
            if status == -1712 {
                try expect(error == nil, "A title-only timeout must preserve later exact content reads")
                try expectEqual(queries, 2 * ttys.count + 1)
            } else {
                try expectNotNil(error); try expectEqual(queries, 1); try expectEqual(unavailable, 0)
                try expectEqual(error as? TerminalAdapterError, .permissionDenied)
            }
        }
        var now = 0.0, queries = 0
        let reader = TerminalAppleEventReader(timeout: 1, clock: { now }) { _, _ in
            queries += 1; now = 2; return terminalStrings(ttys)
        }
        try expectThrows(reader.screens(ttys: ttys)); try expectEqual(queries, 1)
        let cancelled = Task { _ = try reader.screens(ttys: ttys) }; cancelled.cancel()
        do { try await cancelled.value; try expect(false, "Cancelled batch must stop before transport") }
        catch is CancellationError {}
        try expectEqual(queries, 1)
    }

    func testNativeTerminalReadIsolatesClosedAndAmbiguousTargetsAndStopsOnDenial() throws {
        for mode in ["closed", "ambiguous", "denied", "malformed"] {
            var queries = 0
            let reader = TerminalAppleEventReader(batchTitles:false, batchContents:false) { query, _ in
                queries += 1
                let tty = terminalTarget(query)!
                if terminalProperty(query) == terminalCode("titl") { return terminalStrings(["Custom"]) }
                if tty == "/dev/first" {
                    if mode == "closed" { throw NSError(domain: NSOSStatusErrorDomain, code: -1728) }
                    if mode == "denied" { throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
                    if mode == "malformed" { return .init(int32: 42) }
                    return terminalStrings(["first", "another original"])
                }
                return terminalStrings(["healthy original"])
            }
            if mode == "closed" || mode == "ambiguous" {
                let result = try reader.screens(ttys: ["/dev/first", "/dev/second"])
                try expectEqual(result.screens.map(\.tty), ["/dev/second"])
                try expectEqual(result.screens[0].contents, "healthy original")
                try expectEqual(result.failures.count, 1)
                try expectEqual(result.failures[0].tty, "/dev/first")
            } else {
                var thrown: Error?
                do { _ = try reader.screens(ttys: ["/dev/first", "/dev/second"]) } catch { thrown = error }
                try expectNotNil(thrown)
                if mode == "denied" { try expectEqual(thrown as? TerminalAdapterError, .permissionDenied) }
                try expectEqual(queries, 1, "Denial and invalid wire types must stop before another TTY is read")
            }
        }
    }

    func testNativeTerminalReadBudgetsCancellationAndRejectsReorderedMetadata() async throws {
        var now = 0.0, queries = 0
        let timed = TerminalAppleEventReader(timeout: 1, clock: { now }) { _, _ in
            queries += 1; now = 2; return terminalStrings(["original"])
        }
        var didTimeout = false
        do { _ = try timed.screens(ttys: ["/dev/first", "/dev/second"]) } catch { didTimeout = true }
        try expect(didTimeout); try expectEqual(queries, 1, "One deadline covers the entire host read")
        let cancelled = Task { _ = try timed.screens(ttys: ["/dev/first"]) }
        cancelled.cancel()
        do { try await cancelled.value; try expect(false, "Cancelled reads must stop") } catch is CancellationError { }
        try expectEqual(queries, 1)

        var identityReads = 0
        let changed = TerminalAppleEventReader { query, _ in
            if let _ = terminalTarget(query) {
                return terminalStrings([terminalProperty(query) == terminalCode("pcnt") ? "same original" : ""])
            }
            let property = terminalProperty(query)
            if property == terminalCode("ID  ") {
                identityReads += 1
                return terminalList((identityReads == 1 ? [1, 2] : [2, 1]).map { .init(int32: Int32($0)) })
            }
            if property == terminalCode("ttty") { return terminalStrings(["/dev/first", "/dev/unrelated"]) }
            return terminalStrings(["Wrong after reorder", "Other"])
        }
        let result = try changed.screens(ttys: ["/dev/first"])
        try expectEqual(result.screens.first?.contents, "same original")
        try expect(result.screens.first?.title == nil, "Changing window order must not assign a neighbour's title")
    }
}
