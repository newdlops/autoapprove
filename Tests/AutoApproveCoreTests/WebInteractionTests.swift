import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

private let formFields: [JSONObject] = [
    ["id": "environment", "question": "어떤 환경을 테스트할까요?", "options": [["label": "개발", "description": "격리한 개발 환경"], ["label": "운영"]]],
    ["id": "checks", "question": "어떤 항목을 확인할까요?", "multiSelect": true, "options": [["label": "화면"], ["label": "입력"]]]
]
private actor CaptureCount {
    var count = 0
    func captured() { count += 1 }
}
private func fixtureImage() throws -> TerminalNativeImage {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); try expect(CGImageDestinationFinalize(destination))
    return TerminalNativeImage(data: (data as Data).base64EncodedString(), width: 8, height: 8)
}

extension ApprovalTests {
    func testWebQuestionAnswersAreExplicitAndBounded() throws {
        let fields = try WebQuestionField.parse(formFields)
        let answer: JSONObject = ["environment": ["choices": ["개발"], "text": ""], "checks": ["choices": ["화면", "입력"], "text": "한글🧪도 확인"]]
        let values = try WebQuestionField.answers(answer, for: fields)
        try expectEqual(values["어떤 환경을 테스트할까요?"], "개발")
        try expectEqual(values["어떤 항목을 확인할까요?"], "화면, 입력\n한글🧪도 확인")
        try expectThrows(try WebQuestionField.answers([:], for: fields))
        var invalid = answer; invalid["environment"] = ["choices": ["개발", "운영"], "text": ""]
        try expectThrows(try WebQuestionField.answers(invalid, for: fields))
        invalid["environment"] = ["choices": ["없는 선택지"], "text": ""]
        try expectThrows(try WebQuestionField.answers(invalid, for: fields))
        invalid["environment"] = ["choices": [], "text": " "]
        try expectThrows(try WebQuestionField.answers(invalid, for: fields))
        try expectThrows(try WebQuestionField.parse([formFields[0], formFields[0]]))
        try expectThrows(try WebQuestionField.parse([["question": "Q", "options": "broken"]]))
    }

    func testWebQuestionOwnershipExpiryAndNoDefaultAnswer() throws {
        let inbox = WebQuestionInbox(), now = Date()
        let first = try inbox.create(["questions": formFields], owner: "first", at: now)
        let second = try inbox.create(["questions": formFields], owner: "second", at: now)
        try expectEqual(inbox.pending(at: now).count, 2)
        try expectNil(try inbox.get(first.id, owner: "first", at: now).answers)
        try expectThrows(try inbox.get(first.id, owner: "second", at: now))
        try inbox.answer(first.id, answers: ["environment": ["choices": ["개발"], "text": ""], "checks": ["choices": [], "text": "전부"]], at: now)
        try expectEqual(try inbox.get(first.id, owner: "first", at: now).phase, "answered")
        try expectEqual(inbox.pending(at: now).map(\.id), [second.id])
        try expectThrows(try inbox.answer(first.id, answers: [:], at: now))
        inbox.cancel(owner: "second")
        try expectEqual(try inbox.get(second.id, owner: "second", at: now).phase, "cancelled")
        let third = try inbox.create(["questions": formFields], owner: "first", at: now)
        try expectEqual(try inbox.get(third.id, owner: "first", at: now.addingTimeInterval(601)).phase, "expired")
        try expectThrows(try inbox.answer(third.id, answers: [:], at: now.addingTimeInterval(601)))
    }

    func testTestScreenCaptureIsExplicitAndStops() async throws {
        let count = CaptureCount(), image = try fixtureImage()
        let source = TestScreenSource(id: 1, scope: "display", title: "격리 시험 화면", width: 8, height: 8)
        var requests = [Bool]()
        let service = TestScreenSharing(permission: { requested in requests.append(requested); return true }, sources: { [source] }, capture: { _ in await count.captured(); return image })
        _ = try await service.availableSources(); try expectEqual(await count.count, 0); try expectEqual(requests, [false])
        let share = try await service.start(["sourceID": 1], owner: "first")
        try expectEqual(share.source.scope, "display"); try expectEqual(await count.count, 0, "Starting a capability alone must not capture a desktop")
        let first = try await service.frame(share.id), second = try await service.frame(share.id)
        try expectEqual(first.image, image); try expectEqual(second.image, image); try expectEqual(await count.count, 1)
        try expectThrows(try service.stop(share.id, owner: "other"))
        try service.stop(share.id, owner: "first"); try expect(service.active.isEmpty)
        do { _ = try await service.frame(share.id); throw AppError.message("Stopped share still captured") } catch let error as RemoteHTTPError { try expectEqual(error.status, 410) }
        try expectEqual(await count.count, 1)
        let denied = TestScreenSharing(permission: { _ in false }, sources: { [source] }, capture: { _ in await count.captured(); return image })
        do { _ = try await denied.start([:], owner: "first"); throw AppError.message("Permission denial was ignored") } catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
        // Turning off sharing while the source list is still loading must revoke that start as well.
        let delayed = TestScreenSharing(permission: { _ in true }, sources: { try await Task.sleep(nanoseconds: 80_000_000); return [source] }, capture: { _ in await count.captured(); return image })
        let starting = Task { try await delayed.start([:], owner: "first") }
        try await Task.sleep(nanoseconds: 20_000_000); delayed.stopAll()
        do { _ = try await starting.value; throw AppError.message("Stopped service published an in-flight share") } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expect(delayed.active.isEmpty); try expectEqual(await count.count, 1)
    }

    func testMCPStdioProtocolAndToolErrors() throws {
        let initialize = AutoApproveMCPServer.response(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]]) { _, _ in throw AppError.message("Must not call") }
        try expectEqual((initialize?["result"] as? JSONObject)?["protocolVersion"] as? String, "2025-11-25")
        let list = AutoApproveMCPServer.response(["jsonrpc": "2.0", "id": "list", "method": "tools/list"]) { _, _ in [:] }
        try expectEqual(((list?["result"] as? JSONObject)?["tools"] as? [JSONObject])?.count, 5)
        try expectNil(AutoApproveMCPServer.response(["jsonrpc": "2.0", "method": "notifications/initialized"]) { _, _ in [:] })
        let success = AutoApproveMCPServer.response(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "ask_user", "arguments": ["questions": formFields]]]) { name, input in
            try expectEqual(name, "ask_user"); try expectEqual((input["questions"] as? [JSONObject])?.count, 2); return ["phase": "waiting"]
        }
        try expectEqual((success?["result"] as? JSONObject)?["isError"] as? Bool, false)
        let failed = AutoApproveMCPServer.response(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "start_screen_share"]]) { _, _ in throw AppError.message("Permission required") }
        try expectEqual((failed?["result"] as? JSONObject)?["isError"] as? Bool, true)
    }
}
