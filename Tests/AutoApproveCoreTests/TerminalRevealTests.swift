import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
    func testTerminalRevealTarget() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var activated = 0;
        var targetTab = {tty: () => '/dev/ttys042'};
        var targetWindow = {tabs: () => [{tty: () => {throw Error('closed tab');}}, targetTab],
          miniaturized: true, index: 7, selectedTab: null,
          bounds: () => ({x:-1200,y:100,width:900,height:600})};
        var otherWindow = {tabs: () => [{tty: () => '/dev/ttys001'}], miniaturized: true, index: 2, selectedTab: null};
        function Application() { return {running: () => true, windows: () => [
          {tabs: () => {throw Error('closed window (-1728)');}}, otherWindow, targetWindow,
          {tabs: () => {throw Error('must return immediately after finding target');}}
        ], activate: () => {activated++;}}; }
        """)
        let result = context.evaluateScript(try TerminalAdapter.revealScript(tty: "/dev/ttys042"))
        try expectNil(context.exception)
        let bounds = try JSONDecoder().decode(TerminalWindowBounds.self, from: Data(result!.toString().utf8))
        try expectEqual(bounds.x, -1200)
        try expectEqual(bounds.width, 900)
        try expect(context.evaluateScript("targetWindow.selectedTab === targetTab && targetWindow.miniaturized === false && targetWindow.index === 1")!.toBool())
        try expect(context.evaluateScript("otherWindow.selectedTab === null && otherWindow.miniaturized === true && otherWindow.index === 2")!.toBool())
        try expectEqual(context.evaluateScript("activated")!.toInt32(), 1)
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
