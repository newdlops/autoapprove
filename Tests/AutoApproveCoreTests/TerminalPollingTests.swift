import Foundation
import JavaScriptCore
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

extension ApprovalTests {
#if DEBUG
    func testIdleObservationWaitsForChangeOrCancellation() async throws {
        let signal = RemoteTerminalChangeSignal(), observation = signal.observe()
        var entered = false, finished = false
        let waiting = Task {
            entered = true
            await observation.waitForChange()
            finished = true
        }
        while !entered { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        try expectFalse(finished, "An inactive host poller must not wake on an idle timer")
        signal.notify()
        await waiting.value
        try expect(finished, "A host state change must wake its parked poller")

        let cancelled = Task { await observation.waitForChange() }
        cancelled.cancel()
        await cancelled.value
    }
#endif

    private func batchTerminalContext(_ setup: String = "") -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var calls = {bulk:0, enumerations:0, tty:0, contents:0, title:0, byID:0};
        var denied = '', changing = false, wrongSelection = false, closed = false, idReads = 0;
        const windows = Array.from({length:100}, (_, i) => {
          const tty = '/dev/fixture-' + i;
          const tab = {knownTTY:tty, tty:() => { calls.tty++; return tty; },
            customTitle:() => { calls.title++; return i === 1 ? 'Custom title' : ''; }, selected:() => true,
            contents:() => { calls.contents++;
              if (denied === 'contents') throw Object.assign(Error('denied'), {errorNumber:-1743});
              if (closed && i === 0) throw Error('closed tab (-1728)');
              return 'Exact original ' + i;
            }};
          return {id:() => i + 1, name:() => 'Window ' + i, bounds:() => ({x:i,y:0,width:800,height:600}),
            selectedTab:() => ({tty:() => wrongSelection ? '/dev/wrong' : tty}), tabs:() => [tab]};
        });
        function Application() {
          const enumerate = () => { calls.enumerations++; return windows; };
          enumerate.id = () => { calls.bulk++; idReads++; if (denied === 'bulk') throw Object.assign(Error('denied'), {errorNumber:-1743});
            return windows.map(w => w.id() + (changing && idReads > 1 ? 100 : 0)); };
          enumerate.tabs = {whose: predicate => () => {
            calls.bulk++;
            if (predicate._or && predicate._or.length < 2) throw Error('JXA _or requires at least two clauses');
            const allowed = new Set(predicate._or ? predicate._or.map(p => p.tty) : [predicate.tty]);
            return windows.map(w => w.tabs().filter(tab => allowed.has(tab.knownTTY)));
          }};
          enumerate.selectedTab = {tty:() => { calls.bulk++; return windows.map(w => w.tabs()[0].knownTTY); }};
          // A plain JS function's name is read-only, unlike JXA's specifier.
          Object.defineProperty(enumerate, 'name', {value:() => { calls.bulk++; return windows.map(w => w.name()); }});
          enumerate.byId = id => { calls.byID++; return windows[id - 1]; };
          return {running:() => true, windows:enumerate};
        }
        \(setup)
        """)
        return context
    }

    func testTerminalBatchReadsOnlyExactTargetsWithBoundedDiscovery() throws {
        for count in [1, 20] {
            let context = batchTerminalContext()
            let ttys = (0..<count).map { "/dev/fixture-\($0)" }
            let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ttys + ttys, includeCursor: false))!
            try expectNil(context.exception)
            let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
            try expectEqual(Set(snapshot.screens.map(\.tty)), Set(ttys))
            try expectEqual(snapshot.screens.count, count, "Repeated targets must never duplicate a screen")
            try expect(snapshot.screens.allSatisfy { $0.contents == "Exact original " + $0.tty.replacingOccurrences(of: "/dev/fixture-", with: "") })
            try expectEqual(snapshot.screens[0].title, "Window 0")
            if count > 1 { try expectEqual(snapshot.screens[1].title, "Custom title") }
            try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), 0, "Normal reads must not enumerate 100 windows")
            try expect(context.evaluateScript("calls.bulk")!.toInt32() <= 6, "Discovery cost must stay constant as target count grows")
            try expectEqual(context.evaluateScript("calls.tty")!.toInt32(), Int32(count), "Do not read unrelated tab identities")
            try expectEqual(context.evaluateScript("calls.contents")!.toInt32(), Int32(count), "Only requested original content is readable")
            try expectEqual(context.evaluateScript("calls.byID")!.toInt32(), 0, "Background polling must not fetch cursor window metadata")
        }
        let empty = batchTerminalContext()
        let value = empty.evaluateScript(try TerminalAdapter.screenScript(ttys: [], includeCursor: false))!
        try expectNil(empty.exception)
        let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
        try expect(snapshot.screens.isEmpty)
        try expectEqual(empty.evaluateScript("calls.bulk + calls.enumerations")!.toInt32(), 0, "No targets means no window queries")
    }

    func testTerminalBatchPreservesCursorAndIsolatesClosedTabs() throws {
        for wrong in [false, true] {
            let context = batchTerminalContext("wrongSelection = \(wrong ? "true" : "false"); closed = true;")
            let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0", "/dev/fixture-1"]))!
            try expectNil(context.exception)
            let data = Data(value.toString().utf8)
            let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: data)
            try expectEqual(snapshot.screens.count, 1)
            try expectEqual(snapshot.screens[0].tty, "/dev/fixture-1")
            try expectEqual(snapshot.screens[0].contents, "Exact original 1")
            try expectEqual(snapshot.failures.count, 1)
            try expectEqual(snapshot.failures[0].tty, "/dev/fixture-0")
            let metadata = try JSONSerialization.jsonObject(with: data) as! JSONObject
            let window = (metadata["screens"] as! [JSONObject])[0]["cursorWindow"]
            if wrong { try expect(window is NSNull, "Do not attach a different selected TTY's cursor window") }
            else { try expectEqual((window as? JSONObject)?["windowID"] as? Int, 2) }
            try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), 0)
        }
    }

    func testTerminalCursorReadsNeverMeasureWindowsDuringResize() throws {
        for fallback in [false, true] {
            for titles in [false, true] {
                for cursor in [false, true] {
                    let context = batchTerminalContext("""
                    changing = \(fallback ? "true" : "false"); calls.bounds = 0;
                    for (const window of windows) Object.defineProperty(window, 'bounds', {
                      get:() => { calls.bounds++; throw Error('window is resizing'); },
                      set:() => { calls.bounds++; throw Error('must not resize the original'); }
                    });
                    """)
                    let value = context.evaluateScript(try TerminalAdapter.screenScript(
                        ttys: ["/dev/fixture-1"], includeCursor: cursor, includeTitles: titles))!
                    try expectNil(context.exception)
                    let data = Data(value.toString().utf8)
                    let result = try JSONDecoder().decode(TerminalSnapshot.self, from: data)
                    try expectEqual(result.screens.map(\.contents), ["Exact original 1"])
                    try expect(result.failures.isEmpty)
                    let screen = (try JSONSerialization.jsonObject(with: data) as! JSONObject)["screens"] as! [JSONObject]
                    if cursor {
                        let metadata = screen[0]["cursorWindow"] as? JSONObject
                        try expectEqual(metadata?["windowID"] as? Int, 2)
                        try expectEqual(metadata?["title"] as? String, "Window 1")
                        try expectNil(metadata?["bounds"])
                    } else { try expect(screen[0]["cursorWindow"] is NSNull) }
                    try expectEqual(context.evaluateScript("calls.bounds")!.toInt32(), 0,
                        "Cursor discovery must not query or change the resizing source window's bounds")
                    try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), fallback ? 1 : 0)
                }
            }
        }
    }

    func testTerminalBatchRetriesChangedWindowTopologyWithoutHidingDenial() throws {
        let changed = batchTerminalContext("changing = true;")
        let value = changed.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0"], includeCursor: false))!
        try expectNil(changed.exception)
        let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
        try expectEqual(snapshot.screens.first?.tty, "/dev/fixture-0")
        try expectEqual(snapshot.screens.first?.contents, "Exact original 0")
        try expectEqual(changed.evaluateScript("calls.enumerations")!.toInt32(), 1, "Changed window ordering must use a fresh legacy lookup")
        for stage in ["bulk", "contents"] {
            let denied = batchTerminalContext("denied = '\(stage)';")
            denied.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0"], includeCursor: false))
            try expectNotNil(denied.exception)
            // Looking at the context exception must not clear it before inspecting state.
            denied.exception = nil
            try expectEqual(denied.evaluateScript("calls.enumerations")!.toInt32(), 0, "Automation denial must not trigger a fallback or more reads")
        }
    }

    func testTerminalTextOnlyLegacyReadsSkipTitlesWithoutWeakeningIdentity() throws {
        for count in [1, 20] {
            for changed in [false, true] {
                let context = batchTerminalContext("changing = \(changed ? "true" : "false");")
                let ttys = (0..<count).map { "/dev/fixture-\($0)" }
                let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ttys + ttys, includeCursor: false, includeTitles: false))!
                try expectNil(context.exception)
                let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
                try expectEqual(snapshot.screens.map(\.tty), ttys)
                try expectEqual(snapshot.screens.map(\.contents), (0..<count).map { "Exact original \($0)" })
                try expect(snapshot.screens.allSatisfy { $0.title == nil })
                try expect(snapshot.failures.isEmpty)
                try expectEqual(context.evaluateScript("calls.title")!.toInt32(), 0, "Fresh input validation cannot wait on custom-title reads")
                try expectEqual(context.evaluateScript("calls.bulk")!.toInt32(), 3, "Keep both window identity reads and the predicate; skip selected-TTY and window-name metadata")
                try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), changed ? 1 : 0)
                try expectEqual(context.evaluateScript("calls.contents")!.toInt32(), Int32(count))
                try expectEqual(context.evaluateScript("calls.byID")!.toInt32(), 0)
            }
        }
        for stage in ["bulk", "contents"] {
            let context = batchTerminalContext("denied = '\(stage)';")
            context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0"], includeCursor: false, includeTitles: false))
            try expectNotNil(context.exception)
            context.exception = nil
            try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), 0, "A denied content or identity read must stop, with no fallback")
            try expectEqual(context.evaluateScript("calls.title")!.toInt32(), 0)
        }
        let closed = batchTerminalContext("closed = true;")
        let value = closed.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0", "/dev/fixture-1", "/dev/missing"], includeCursor: false, includeTitles: false))!
        try expectNil(closed.exception)
        let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
        try expectEqual(snapshot.screens.map(\.tty), ["/dev/fixture-1"])
        try expectEqual(snapshot.failures.map(\.tty), ["/dev/fixture-0"])

        let cursor = batchTerminalContext()
        let cursorValue = cursor.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-1"], includeCursor: true, includeTitles: false))!
        try expectNil(cursor.exception)
        let object = try JSONSerialization.jsonObject(with: Data(cursorValue.toString().utf8)) as! JSONObject
        let screen = (object["screens"] as! [JSONObject])[0]
        try expect(screen["title"] is NSNull)
        try expectEqual((screen["cursorWindow"] as? JSONObject)?["windowID"] as? Int, 2, "Skipping labels must retain exact selected-window cursor metadata")
        try expectEqual(cursor.evaluateScript("calls.title")!.toInt32(), 0)

        // A requested metadata collection returning null is invalid, not the
        // same as deliberately omitting that collection for a text-only read.
        for titles in [false, true] {
            for field in titles ? ["selected", "names"] : ["selected"] {
                let context = batchTerminalContext("""
                const originalApplication = Application;
                Application = () => {
                  const app = originalApplication();
                  \(field == "selected" ? "app.windows.selectedTab.tty = () => null;" : "Object.defineProperty(app.windows, 'name', {value:() => null});")
                  return app;
                };
                """)
                let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/fixture-0"], includeCursor: true, includeTitles: titles))!
                try expectNil(context.exception)
                let data = Data(value.toString().utf8)
                let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: data)
                try expectEqual(snapshot.screens.count, 1)
                try expectEqual(snapshot.screens[0].contents, "Exact original 0")
                try expectEqual(snapshot.screens[0].title, titles ? "Window 0" : nil)
                try expectEqual(context.evaluateScript("calls.enumerations")!.toInt32(), 1, "Malformed required metadata must retain the fresh per-window fallback")
                let object = try JSONSerialization.jsonObject(with: data) as! JSONObject
                let screen = (object["screens"] as! [JSONObject])[0]
                try expectEqual((screen["cursorWindow"] as? JSONObject)?["windowID"] as? Int, 1)
            }
        }
    }
}
