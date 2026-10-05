// Uses private mock Unix sockets only. No installed app or user CLI is called.
import Foundation

#if ORCA_STREAM_BASELINE
import AutoApproveCore

@main struct OrcaTerminalStreamCheck {
    static func main() throws {
        let text = try OrcaAdapter.screen(from: ["terminal": ["source": "screen", "tail": ["RED 한글"]]])
        guard text.contains("\u{1b}[38;2;255;0;0m"), text.contains("\u{1b}[2;4H") else {
            throw NSError(domain: "OrcaTerminalStreamCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Existing Orca screen path lost RGB color and cursor state"])
        }
    }
}
#else
@main struct OrcaTerminalStreamCheck {
    static func main() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "snapshot"
        let source = OrcaTerminalStream(userDataURL: directory, timeout: mode == "deadline" ? 0.18 : 2,
                                        maximumConcurrentReads: mode == "admission" ? 1 : 4)
        do {
            if mode == "cancel" || mode == "admission" {
                let first = Task { try await source.snapshot(handle: "terminal-exact") }
                try await Task.sleep(nanoseconds: 80_000_000)
                if mode == "admission" {
                    do {
                        _ = try await source.snapshot(handle: "terminal-exact")
                        printJSON(["status": "wrong", "error": "Concurrent read exceeded admission"])
                        first.cancel(); _ = try? await first.value; return
                    } catch OrcaTerminalStreamError.capacity { }
                }
                let cancelledAt = Date()
                first.cancel()
                do {
                    _ = try await first.value
                    printJSON(["status": "wrong", "error": "Cancelled read returned a frame"]); return
                } catch is CancellationError { }
                let frame = try await source.snapshot(handle: "terminal-exact")
                printJSON(["status": "ok", "ansi": frame.ansi, "ownerPID": frame.ownerPID,
                           "cancelElapsed": Date().timeIntervalSince(cancelledAt)])
            } else {
                let frame = try await source.snapshot(handle: "terminal-exact")
                printJSON(["status": "ok", "ansi": frame.ansi, "columns": frame.columns, "rows": frame.rows,
                           "sequence": frame.sequence, "runtimeID": frame.runtimeID, "ptyID": frame.ptyID,
                           "incarnationID": frame.incarnationID, "ownerPID": frame.ownerPID, "alternateScreen": frame.alternateScreen,
                           "observedAt": frame.observedAt.timeIntervalSince1970])
            }
        } catch is CancellationError { printJSON(["status": "cancelled"]) }
        catch OrcaTerminalStreamError.timedOut { printJSON(["status": "timeout"]) }
        catch { printJSON(["status": "error", "error": error.localizedDescription]) }
    }

    static func printJSON(_ value: [String: Any]) {
        print(String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
#endif
