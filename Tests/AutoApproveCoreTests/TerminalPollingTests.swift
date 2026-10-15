import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
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
}
