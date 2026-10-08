import Foundation
import AutoApproveCore

final class FakeMouseActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    private var allowed = true
    private var screen: MouseActivitySession = .active
    private var failed = false
    private var sent: [TimeInterval] = []
    private var checks = 0
    private var prompts = 0
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var now: TimeInterval { get { locked { time } } set { locked { time = newValue } } }
    var permission: Bool { get { locked { allowed } } set { locked { allowed = newValue } } }
    var session: MouseActivitySession { get { locked { screen } } set { locked { screen = newValue } } }
    var failure: Bool { get { locked { failed } } set { locked { failed = newValue } } }
    var pulses: [TimeInterval] { locked { sent } }
    var reads: Int { locked { checks } }
    var requests: Int { locked { prompts } }
    var control: MouseActivityControl {
        MouseActivityControl(uptime: { self.now }, permission: { self.locked { self.checks += 1; return self.allowed } },
            session: { self.locked { self.checks += 1; return self.screen } }, pulse: {
                try self.locked {
                    if self.failed { throw AppError.message("이벤트 생성 실패") }
                    self.sent.append(self.time)
                }
            }, requestPermission: { self.locked { self.prompts += 1; return self.allowed } })
    }
}

extension ApprovalTests {
    @MainActor func testMouseActivityMinuteSchedule() throws {
        let fake = FakeMouseActivity()
        let timer = MouseActivity(control: fake.control)
        timer.evaluate(); try expectEqual(fake.reads, 0); try expectEqual(fake.requests, 0)
        timer.setEnabled(true)
        try expectEqual(fake.pulses, [], "Enabling arms the first minute without sending immediately")
        fake.now += 59; timer.evaluate(); try expectEqual(fake.pulses, [])
        fake.now += 1; timer.evaluate(); try expectEqual(fake.pulses, [1_060]); try expectEqual(timer.status.phase, .active)
        try expect(timer.status.lastSentAt != nil)
        // Repeated enable requests and checks cannot reset or duplicate the minute schedule.
        fake.now += 30; timer.setEnabled(true); timer.evaluate(); try expectEqual(fake.pulses.count, 1)
        fake.now += 30; timer.evaluate(); timer.evaluate(); try expectEqual(fake.pulses, [1_060, 1_120])
        fake.now += 600; timer.evaluate(); try expectEqual(fake.pulses, [1_060, 1_120, 1_720], "Missed minutes are not replayed")
        fake.now += 1; timer.evaluate(); try expectEqual(fake.pulses.count, 3)
        timer.setEnabled(false); fake.now += 120; timer.evaluate(); try expectEqual(fake.pulses.count, 3)
        try expectEqual(timer.status.phase, .off)
        timer.setEnabled(true); timer.stop(); fake.now += 120; timer.evaluate(); try expectEqual(fake.pulses.count, 3)
        timer.setEnabled(true); fake.now += 60; timer.evaluate(); try expectEqual(fake.pulses.count, 4)
        try expectEqual(fake.requests, 0, "Timers never request macOS permission")
        timer.stop()
    }

    @MainActor func testMouseActivityLockAndPermission() throws {
        let fake = FakeMouseActivity()
        let mouse = MouseActivity(control: fake.control)
        fake.session = .locked; mouse.setEnabled(true)
        try expectEqual(mouse.status.phase, .locked)
        for _ in 0..<3 { fake.now += 60; mouse.evaluate() }
        try expectEqual(fake.pulses, [], "An already locked screen gets no events or unlock action")
        fake.session = .unavailable; fake.now += 60; mouse.evaluate()
        try expectEqual(mouse.status.phase, .unavailable); try expectEqual(fake.pulses, [])
        fake.session = .active; fake.permission = false; fake.now += 60; mouse.evaluate()
        try expectEqual(mouse.status.phase, .permission); try expectEqual(fake.requests, 0)
        fake.permission = true; fake.now += 60; mouse.evaluate()
        try expectEqual(fake.pulses.count, 1)
        let lastSent = mouse.status.lastSentAt
        fake.session = .locked; fake.now += 60; mouse.evaluate()
        try expectEqual(fake.pulses.count, 1); try expectEqual(mouse.status.lastSentAt, lastSent)
        fake.session = .active; fake.failure = true; fake.now += 60; mouse.evaluate()
        try expectEqual(mouse.status.phase, .failed); try expectEqual(fake.pulses.count, 1)
        fake.failure = false; fake.now += 60; mouse.evaluate()
        try expectEqual(mouse.status.phase, .active); try expectEqual(fake.pulses.count, 2)
        mouse.stop()
    }
}
