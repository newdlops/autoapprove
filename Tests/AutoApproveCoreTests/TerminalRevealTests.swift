import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
    func testTerminalMetadataNeverMeasuresOrChangesWindows() throws {
        for host in [ScreenHost.terminal, .iterm] {
            let context = JSContext()!
            context.evaluateScript("""
            var boundsCalls = 0, activations = 0;
            var wanted = {tty:() => '/dev/fixture', selected:() => true};
            var tab = {id:() => 5, sessions:() => [wanted], currentSession:() => wanted};
            var target = {id:() => 42, miniaturized:() => false, selectedTab:() => wanted,
              currentTab:() => tab, tabs:() => \(host == .terminal ? "[wanted]" : "[tab]")};
            Object.defineProperty(target, 'bounds', {
              get:() => { boundsCalls++; throw Error('window is resizing'); },
              set:() => { boundsCalls++; throw Error('must not resize'); }
            });
            function Application() { return {running:() => true, windows:() => [target], activate:() => {activations++;}}; }
            """)
            let script = try TerminalAdapter.windowMetadataScript(tty: "/dev/fixture", host: host)
            for _ in 0..<12 {
                let value = context.evaluateScript(script)!
                try expectNil(context.exception)
                let record = try JSONSerialization.jsonObject(with: Data(value.toString().utf8)) as! JSONObject
                try expectEqual(record["windowID"] as? Int, 42)
                try expectEqual(record["selected"] as? Bool, true)
                try expectEqual(record["minimized"] as? Bool, false)
                try expectNil(record["bounds"])
            }
            try expectEqual(context.evaluateScript("boundsCalls + activations")!.toInt32(), 0)
            context.evaluateScript("target.tabs = () => {throw Object.assign(Error('denied'), {errorNumber:-1743});}")
            context.evaluateScript(script)
            try expect(context.exception?.toString().contains("denied") == true,
                "Removing an optional geometry query must not hide Automation denial")
        }
    }

    func testTerminalRevealTarget() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var activated = 0;
        var targetTab = {tty: () => '/dev/ttys042'};
        var targetWindow = {tabs: () => [{tty: () => {throw Error('closed tab');}}, targetTab],
          miniaturized: true, index: 7, selectedTab: null,
          id: () => 42, bounds: () => {throw Error('Terminal must not measure itself for a marker');}};
        var otherWindow = {tabs: () => [{tty: () => '/dev/ttys001'}], miniaturized: true, index: 2, selectedTab: null};
        function Application() { return {running: () => true, windows: () => [
          {tabs: () => {throw Error('closed window (-1728)');}}, otherWindow, targetWindow,
          {tabs: () => {throw Error('must return immediately after finding target');}}
        ], activate: () => {activated++;}}; }
        """)
        let result = context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/ttys042"))
        try expectNil(context.exception)
        let revealed = try JSONSerialization.jsonObject(with: Data(result!.toString().utf8)) as! [String: Any]
        try expectEqual(revealed["windowID"] as? Int, 42)
        try expect(context.evaluateScript("targetWindow.selectedTab === targetTab && targetWindow.miniaturized === false && targetWindow.index === 1")!.toBool())
        try expect(context.evaluateScript("otherWindow.selectedTab === null && otherWindow.miniaturized === true && otherWindow.index === 2")!.toBool())
        try expectEqual(context.evaluateScript("activated")!.toInt32(), 1)
        for invalidID in ["0", "-1", "4294967296", "1.5", "NaN", "Infinity"] {
            context.evaluateScript("targetWindow.id = () => \(invalidID)")
            let value = context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/ttys042"))
            try expectNil(context.exception)
            try expectEqual(value?.toString(), "{\"windowID\":null}", "Invalid decoration metadata must not retry or fail the completed reveal")
        }
        context.evaluateScript("targetWindow.id = () => {throw Error('closed metadata');}")
        try expectEqual(context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/ttys042"))?.toString(), "{\"windowID\":null}")
        context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/missing"))
        try expectNotNil(context.exception)
        context.exception = nil
        context.evaluateScript("Application = () => ({running: () => true, windows: () => [{tabs: () => {throw Error('not authorized (-1743)');}}]});")
        context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/ttys042"))
        try expect(context.exception?.toString().contains("-1743") == true)
    }

    func testTerminalHighlightCoordinates() throws {
        func bounds(_ values: [String: Double]) throws -> TerminalWindowBounds {
            try JSONDecoder().decode(TerminalWindowBounds.self, from: JSONSerialization.data(withJSONObject: values))
        }
        let main = try bounds(["x": 100, "y": 80, "width": 1040, "height": 700]).appKitFrame(primaryScreenHeight: 1080)
        try expectEqual(main?.minY, 300)
        try expectEqual(main?.width, 1040)
        let left = try bounds(["x": -1400, "y": 100, "width": 900, "height": 600]).appKitFrame(primaryScreenHeight: 1080)
        try expectEqual(left?.minX, -1400)
        try expectEqual(left?.minY, 380)
        let upper = try bounds(["x": 100, "y": -900, "width": 900, "height": 600]).appKitFrame(primaryScreenHeight: 1080)
        try expectEqual(upper?.minY, 1380)
        let invalid = try bounds(["x": 0, "y": 0, "width": 0, "height": 600])
        try expectNil(invalid.appKitFrame(primaryScreenHeight: 1080))
        try expectNil(invalid.appKitFrame(primaryScreenHeight: .infinity))
    }
}
