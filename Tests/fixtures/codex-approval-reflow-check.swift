import Foundation
import AutoApproveCore

// All output and input belongs to this fixture's child, never an existing CLI.
@main struct CodexApprovalReflowCheck {
    static func main() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        let program=directory.appendingPathComponent("render.py")
        try """
        import base64, os, sys, termios
        attr=termios.tcgetattr(0); attr[3] &= ~termios.ECHO; termios.tcsetattr(0, termios.TCSANOW, attr)
        dialog=base64.b64decode(sys.argv[1]); frame=0
        def draw():
            os.write(1, b'\\x1b[2J\\x1b[Hsynthetic-frame-'+str(frame).encode()+b'\\n'+dialog)
        draw()
        for line in sys.stdin:
            frame += 1
            draw()
        """.write(to:program,atomically:true,encoding:.utf8)
        let dialog="Would you like to run the following command?\n\nThread: synthetic [explorer]\n\nReason: Inspect the synthetic workspace.\nAllow the sandboxed process to inspect the fixture.\n\n  $ echo synthetic_한글🙂\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `echo synthetic-long-command-prefix` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel or o to open thread"
        let identity=PromptDetector.detect(dialog,agent:.codex)!.requestIdentity
        let environment=["HOME":directory.path,"ZDOTDIR":directory.path,"PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8"]
        let terminal=try ManagedPTY(cwd:directory.path,command:["/usr/bin/python3","-B",program.path,Data(dialog.utf8).base64EncodedString()],columns:20,rows:80,environment:environment)
        defer{terminal.close()}
        let stream=terminal.descriptor.streamID,client=UUID().uuidString
        var sequence=0
        for (index,size) in [(20,80),(24,80),(25,80),(40,80),(60,80),(80,80),(120,80),(24,5),(24,80)].enumerated() {
            if index>0 {
                try terminal.resize(columns:size.0,rows:size.1,streamID:stream,client:client)
                sequence+=1
                try terminal.input(Data("redraw\n".utf8),streamID:stream,client:client,sequence:sequence)
            }
            var ready=false
            for _ in 0..<300 {
                let screen=terminal.screen()
                if size.1==5 ? screen.contains("open thread"):screen.contains("synthetic-frame-\(index)") && screen.contains("open thread") {ready=true;break}
                try await Task.sleep(for:.milliseconds(10))
            }
            guard ready else{throw AppError.message("Synthetic PTY repaint timed out at \(size)")}
            let snapshot=try terminal.read(after:nil)
            let ansi=String(decoding:Data(base64Encoded:snapshot.data)!,as:UTF8.self)
            let cells=try OriginalTerminalScreen.render(ansi:ansi,columns:size.0,rows:size.1,tty:terminal.descriptor.tty)
            let prompt=PromptDetector.detect(cells.contents,agent:.codex)
            guard size.1==5 ? prompt==nil:prompt?.requestIdentity==identity else{throw AppError.message("Synthetic PTY permission mismatch at \(size)")}
        }
        print("PASS owned synthetic PTY: 7 widths, Korean/emoji, subagent/reason/scope, clipped height and redraw recovery; no user Terminal input")
    }
}
