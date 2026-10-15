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

extension ApprovalTests {
    func testNativeTerminalReadUsesExactPredicatesAndPreservesText() throws {
        let ttys = (0..<20).map { "/dev/native-\($0)" }
        var contentTargets = [String](), queries = 0
        let raw = "한글 é 🙂\n\u{1b}[31moriginal\u{1b}[0m\u{0}\n"
        let reader = TerminalAppleEventReader { query, budget in
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

    func testNativeTerminalReadIsolatesClosedAndAmbiguousTargetsAndStopsOnDenial() throws {
        for mode in ["closed", "ambiguous", "denied", "malformed"] {
            var queries = 0
            let reader = TerminalAppleEventReader { query, _ in
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
