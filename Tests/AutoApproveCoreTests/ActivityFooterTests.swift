import Foundation
import AutoApproveCore

private func foreignActivityFooter(_ text: String) -> String {
    let units = Array(text.utf16)
    return units.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) as String }
}

extension ApprovalTests {
    func testClaudeFeedbackCardShortcutsSurviveCellWrapping() throws {
        let shortcuts="1 to review · 2 to send · 0 to dismiss"
        let footer="⏵⏵ auto mode on · 1 shell · 1 feedback draft"
        func frame(_ before:[String]) -> String {
            (before+["────────","❯","────────","fixture | main | Opus 5.5",footer]).joined(separator:"\r\n")
        }
        for columns in 24...80 {for rows in [24,40] {
            let raw=try OriginalTerminalScreen.render(ansi:frame(["Feedback draft",shortcuts]),columns:columns,rows:rows,tty:"/dev/feedback-card-fixture").contents
            let ready=try OriginalTerminalScreen.render(ansi:frame(["Completed synthetic task"]),columns:columns,rows:rows,tty:"/dev/feedback-card-fixture").contents
            for foreign in [false,true] {
                let card=foreign ? foreignActivityFooter(raw) : raw
                try expectEqual(ActivityDetector.detect(card,agent:.claude).phase,.unknown,"Foreground card at \(columns)x\(rows)")
                try expectEqual(ActivityDetector.detect(card.replacingOccurrences(of:"❯",with:"❯ Draft 한글"),agent:.claude).phase,.input,"Typing deactivates feedback shortcuts")
                try expectEqual(ActivityDetector.detect(foreign ? foreignActivityFooter(ready) : ready,agent:.claude).phase,.idle)
            }
        }}
        let oldCard=frame(["Feedback draft",shortcuts]+Array(repeating:"Old output",count:12))
        try expectEqual(ActivityDetector.detect(oldCard,agent:.claude).phase,.unknown,"A card still in the visible tail remains unverified")
        let outsideTail=frame(["Feedback draft",shortcuts]+Array(repeating:"Old output",count:24))
        try expectEqual(ActivityDetector.detect(outsideTail,agent:.claude).phase,.idle,"Old shortcuts outside the visible tail do not block readiness")
        let longHistory=frame([String(repeating:"Old output ",count:100_000),"Feedback draft",shortcuts])
        try expectEqual(ActivityDetector.detect(longHistory,agent:.claude).phase,.unknown,"Bounded adjacent rows retain the foreground card")
    }

    func testClaudeCompactActivityFooterPreservesMonitoringAndBoundaries() throws {
        let metadata="fixture | main | Opus 5.5 | ctx 35% | 5h 51% 7d 29%"
        let compact="⏵⏵ auto mode on · 1 shell · 1 feedback draft"
        func frame(_ footer:String,_ composer:String="❯",_ before:String="Completed synthetic task") -> String {
            [before,"────────",composer,"────────",metadata,footer].joined(separator:"\n")
        }
        for (footer,monitoring) in [(compact,true),("⏵⏵ auto mode on · 2 shells",true),
                                    ("⏵⏵ auto mode on · 10 feedback drafts",false)] {
            for columns in [24,40,52,80,184] { for rows in [24,40] {
                let screen=try OriginalTerminalScreen.render(ansi:frame(footer).replacingOccurrences(of:"\n",with:"\r\n"),columns:columns,rows:rows,tty:"/dev/compact-footer-fixture").contents
                for foreign in [false,true] {
                    let value=foreign ? foreignActivityFooter(screen) : screen
                    let ready=ActivityDetector.detect(value,agent:.claude)
                    try expectEqual(ready.phase,.idle,"Compact footer at \(columns)x\(rows): "+footer)
                    try expectEqual(ready.monitoring,monitoring)
                    try expectNil(PromptDetector.detect(value,agent:.claude))
                    try expectEqual(ActivityDetector.detect(value.replacingOccurrences(of:"❯",with:"❯ Draft 한글"),agent:.claude).phase,.input)
                    try expectEqual(ActivityDetector.detect(value.replacingOccurrences(of:"❯",with:"❯ 1. Choice"),agent:.claude).phase,.unknown)
                    try expectEqual(ActivityDetector.detect(value+"\nWorking (esc to interrupt)",agent:.claude).phase,.working)
                    try expect(ActivityDetector.detect(value+"\nUnrecognized request",agent:.claude).phase != .idle)
                }
            }}
        }
        for invalid in ["⏵⏵ auto mode on","⏵⏵ auto mode on · 0 shells","⏵⏵ auto mode on · 1000 shells",
                        "⏵⏵ auto mode on · 1 shell · new request","⏵⏵ auto mode on · 1 feedback draft · send now",
                        "⏵⏵ auto mode on · 1 shell\nUnrecognized request\n1 feedback draft",
                        "Unknown prefix · 1 shell · 1 feedback draft"] {
            try expect(ActivityDetector.detect(frame(invalid),agent:.claude).phase != .idle,invalid)
        }
        for value in [frame(compact,"❯", "Feedback draft\n1 to review · 2 to send · 0 to dismiss"),
                      frame(compact)+"\n1 to review · 2 to send · 0 to dismiss",
                      "```\n"+frame(compact),frame(compact,"❯ 1. Yes, allow once")] {
            try expect(ActivityDetector.detect(value,agent:.claude).phase != .idle)
        }
        try expect(ActivityDetector.detect(frame(compact).replacingOccurrences(of:"❯",with:"›"),agent:.codex).phase != .idle)
        try expectFalse(ActivityDetector.detect(frame(compact),agent:.shell).monitoring)
        var tracker=ActivityTracker();let now=Date(timeIntervalSince1970:1000)
        try expectEqual(tracker.observe(frame(compact),agent:.claude,generation:"one",at:now).phase,.unknown)
        try expectEqual(tracker.observe(frame(compact),agent:.claude,generation:"one",at:now.addingTimeInterval(2)).phase,.idle)
        try expectEqual(tracker.observe(frame(compact),agent:.claude,generation:"two",at:now.addingTimeInterval(3)).phase,.unknown)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-compact-footer-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory))
        var session=AgentSession(id:"process:42:start",agent:.claude,pid:42,started:"start",tty:"/dev/test",cwd:"/tmp/compact",terminal:.terminal)
        session.channel = .terminalScreen;engine.updateDiscovery([session],records:[])
        engine.receiveScreen(sessionID:session.id,raw:frame(compact),generation:"one",at:now)
        engine.receiveScreen(sessionID:session.id,raw:frame(compact),generation:"one",at:now.addingTimeInterval(2))
        try expectEqual(engine.snapshot.sessions[0].phase,.idle);try expect(engine.snapshot.sessions[0].isMonitoring)
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty,"A visible background shell is not a completed turn")
    }

    func testClaudeWrappedStatusFooterRequiresCompleteVisibleMetadata() throws {
        let statuses = [
            "fixture-project | feature/status* | Opus 5.5",
            "fixture-project | feature/status* | Opus 5.5 | ctx 0%",
            "fixture-project | feature/status* | Opus 5.5 | ctx 29% | 5h 14% 7d 23%",
            "fixture-project-x | feature/status* | Sonnet 10.12.123 | ctx 100% | 5h 100% 7d 100%",
            "한글🙂 e\u{301} | feat/한글* | Sonnet 5.1 | ctx 100% | 7d 0%"
        ]
        let hint = "⏵⏵ auto mode on (shift+tab to cycle)"
        for columns in [40,44,48,52,60,80,120] { for rows in [24,40] { for status in statuses {
            func frame(_ composer:String="❯",_ metadata:String?=nil,_ suffix:String="") throws -> String {
                let rule=String(repeating:"─",count:columns)
                let text=["Finished synthetic task",rule,composer,rule,metadata ?? status,hint+suffix].joined(separator:"\r\n")
                return try OriginalTerminalScreen.render(ansi:text,columns:columns,rows:rows,tty:"/dev/footer-fixture").contents
            }
            let screen=try frame()
            try expectEqual(ActivityDetector.detect(screen,agent:.claude).phase,.idle,"Wrapped metadata at \(columns)x\(rows)")
            try expectEqual(ActivityDetector.detect(try frame("❯ Draft 한글"),agent:.claude).phase,.input)
            try expectEqual(ActivityDetector.detect(try frame("❯ 1. Choice"),agent:.claude).phase,.unknown)
            try expectEqual(ActivityDetector.detect(try frame("❯",nil,"\r\nNew unrecognized request"),agent:.claude).phase,.unknown)
            try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:hint,with:""),agent:.claude).phase,.unknown)
            try expectEqual(ActivityDetector.detect(try frame("❯","fixture | main | Opus 5.5 | ctx 101%"),agent:.claude).phase,.unknown)
        }}}
        for screen in ["❯\nfixture | main |\n? for shortcuts\nOpus 5.5",
                       "❯\nNew unrelated question\nfixture | main | Opus 5.5\n? for shortcuts",
                       "❯\nfixture | feature/\nShould I continue?\nstatus | Opus 5.5\n? for shortcuts",
                       "❯\nfixture | feature/\nstatus | Opus 5.5\n? for shortcuts",
                       "❯\nfixture | main |\n```\nOpus 5.5\n? for shortcuts",
                       "❯\nfixture | main |\nOpus 5.5\nUnknown continuation\n? for shortcuts",
                       "❯\n"+Array(repeating:"fixture",count:7).joined(separator:"\n")+"\n? for shortcuts"] {
            try expectEqual(ActivityDetector.detect(screen,agent:.claude).phase,.unknown,"Unrecognized footer boundary: "+screen)
        }
    }

    func testClaudeCompactAndCombinedUsageStatusFooters() throws {
        // Redacted shapes observed in live idle composers. Losing optional usage
        // fields, or adding the five-hour quota, must not strand a ready session.
        let statuses = [
            "fixture-project | feature/status* | Opus 5.5",
            "fixture-project | feature/status* | Opus 5.5 | ctx 0%",
            "fixture-project | feature/status* | Opus 5.5 | ctx 100%",
            "fixture-project | feature/status* | Opus 5.5 | ctx 29% | 5h 14% 7d 23%",
            "fixture-project | feature/status* | Sonnet 5.1 | ctx 100% | 5h 0% 7d 100%"
        ]
        let hint = "⏵⏵ auto mode on (shift+tab to cycle)"
        for status in statuses {
            for newline in ["\n", "\r\n", "\u{2028}"] {
                let screen = ["Finished synthetic task", "────────", "❯", "────────", status, hint].joined(separator:newline)
                try expectEqual(ActivityDetector.detect(screen,agent:.claude).phase,.idle,status)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"❯",with:"❯ Draft 한글"),agent:.claude).phase,.input)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"❯",with:"❯ 1. Choice"),agent:.claude).phase,.unknown)
                try expectEqual(ActivityDetector.detect(screen+newline+"New unrecognized question",agent:.claude).phase,.unknown)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:newline+hint,with:""),agent:.claude).phase,.unknown)
            }
        }
        for status in ["fixture | main | Opus 5.5 | ctx 29% | 5h 101% 7d 23%",
                       "fixture | main | Opus 5.5 | ctx 29% | 5h 14% 7d 101%",
                       "fixture | main | Opus 5.5 | ctx 101%",
                       "fixture | main | Opus 5.5 | 5h 14% 7d 23%",
                       "fixture | main | Opus 5.5 | unknown",
                       "fixture | main | Opus 5.5 | ctx 29% | 5h 14% 7d 23% | unknown"] {
            try expectEqual(ActivityDetector.detect("❯\n"+status+"\n"+hint,agent:.claude).phase,.unknown)
        }
    }

    func testClaudeCustomStatusFooterRequiresComposerHint() throws {
        for model in ["Opus 5.5","Sonnet 5.1","Haiku 4.5"] { for percent in [0,42,100] {
            let status="fixture-project | feature/status | \(model) | ctx \(percent)% | 7d 94%"
            let rows=["Finished synthetic task","────────","❯","────────",status,"⏵⏵ auto mode on (shift+tab to cycle)"]
            for newline in ["\n","\r\n","\u{2028}"] { for foreign in [false,true] {
                let value=rows.joined(separator:newline),screen=foreign ? foreignActivityFooter(value) : value
                try expectEqual(ActivityDetector.detect(screen,agent:.claude).phase,.idle)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"❯",with:"❯ 직접 쓰는 중 😀"),agent:.claude).phase,.input)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"❯",with:"›"),agent:.codex).phase,.unknown)
            }}
            try expectEqual(ActivityDetector.detect("❯\n"+status,agent:.claude).phase,.unknown,"Custom metadata alone never proves readiness")
        }}
        let hint="\n⏵⏵ auto mode on (shift+tab to cycle)"
        for invalid in ["fixture | main | Opus 5.5 | ctx 101% | 7d 94%","fixture | main | Opus 5.5 | ctx 42% | 7d 101%",
                        "fixture | main | Unknown 5.5 | ctx 42% | 7d 94%","fixture | main | Opus 5.5 | ctx 42% | 7d 94% | unexpected",
                        "Status custom arbitrary text"] {
            try expectEqual(ActivityDetector.detect("❯\n"+invalid+hint,agent:.claude).phase,.unknown)
        }
    }

    func testCodexWarningFooterPreservesDraftsAndRejectsMenus() throws {
        for warning in ["⚠ 1 warning · f2 to view","⚠ 2 warnings · f2 to view"] {
            let footer="\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n"+warning
            for foreign in [false,true] {
                let value="Done\n›"+footer,screen=foreign ? foreignActivityFooter(value) : value
                try expectEqual(ActivityDetector.detect(screen,agent:.codex).phase,.idle)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"›",with:"› Draft 한글"),agent:.codex).phase,.input)
                try expectEqual(ActivityDetector.detect(screen.replacingOccurrences(of:"›",with:"› 1. Choice"),agent:.codex).phase,.unknown)
                try expectEqual(ActivityDetector.detect(screen+"\nUnrecognized footer",agent:.codex).phase,.unknown)
            }
            try expectEqual(ActivityDetector.detect("›\n"+warning,agent:.codex).phase,.unknown)
        }
        for invalid in ["⚠ 0 warnings · f2 to view","⚠ 2 warnings · press Enter to approve","⚠ 2 warnings · f2 to view arbitrary"] {
            try expectEqual(ActivityDetector.detect("›\n? for shortcuts\n"+invalid,agent:.codex).phase,.unknown)
        }
    }

    func testCodexServerWaitDialogRemainsWorkingWithoutInput() throws {
        let note="No action is required. Codex will keep waiting, and this menu will close when the response is ready."
        for glyph in ["›","»"] { for newline in ["\n","\r\n","\u{2028}"] {
            let rows=["Giving this request a little extra thought",glyph+" 1. Dismiss and keep waiting","2. Learn more",note]
            for foreign in [false,true] {
                let value=rows.joined(separator:newline),screen=foreign ? foreignActivityFooter(value) : value
                try expectEqual(ActivityDetector.detect(screen,agent:.codex).phase,.working)
                try expectEqual(ActivityDetector.detect(screen,agent:.claude).phase,.unknown)
                try expectNil(PromptDetector.detect(screen,agent:.codex))
            }
            let wrapped=rows.dropLast().joined(separator:newline)+newline+note.replacingOccurrences(of:", and",with:","+newline+"and")
            try expectEqual(ActivityDetector.detect(wrapped,agent:.codex).phase,.working)
        }}
        for invalid in ["Giving this request a little extra thought\n› 1. Choice\n2. Learn more\n"+note,
                        "› 1. Dismiss and keep waiting\n2. Learn more\n"+note,
                        "Giving this request a little extra thought\n› 1. Dismiss and keep waiting\n2. Learn more\n"+note+"\nNew question",
                        "```\nGiving this request a little extra thought\n› 1. Dismiss and keep waiting\n2. Learn more\n"+note] {
            try expectEqual(ActivityDetector.detect(invalid,agent:.codex).phase,.unknown)
        }
    }

    func testActivityFooterHintPositionsAndLateErrors() throws {
        for agent in [AgentKind.codex,.claude] {
            let glyph = agent == .codex ? "›" : "❯"
            let hints = agent == .codex ? ["? for shortcuts","shift+tab to cycle","98% context left","gpt-6 · ~/fixture"]
                : ["? for shortcuts","⏵⏵ accept edits on (shift+tab to cycle)"]
            for hint in hints { for position in 0..<5 {
                var footer = [String](repeating:"─━╌-",count:5)
                footer[position] = hint
                for history in [0,24] { for foreign in [false,true] {
                    let prefix = String(repeating:"Old output 한글 e\u{301} 👨‍👩‍👧‍👦\n",count:history)
                    let screen = prefix+glyph+"\n"+footer.joined(separator:"\n")
                    let text = foreign ? foreignActivityFooter(screen) : screen
                    if foreign { try expectFalse(text.isContiguousUTF8) }
                    let ready = ActivityDetector.detect(text,agent:agent)
                    try expectEqual(ready.phase,.idle,"A hint can occur at any footer index")
                    try expectFalse(ready.monitoring)
                    for badIndex in 0..<5 where badIndex != position {
                        var invalid = footer; invalid[badIndex] = "Unrecognized footer 한글"
                        let value = prefix+glyph+"\n"+invalid.joined(separator:"\n")
                        try expectEqual(ActivityDetector.detect(foreign ? foreignActivityFooter(value) : value,agent:agent).phase,.unknown,
                            "An earlier recognized hint cannot hide a later invalid row")
                    }
                }}
                var background = footer
                background[(position+1)%5] = "• 2 background tasks"
                let monitored = ActivityDetector.detect(glyph+"\n"+background.joined(separator:"\n"),agent:agent)
                try expectEqual(monitored.phase,.idle); try expect(monitored.monitoring)
            }}
            for footer in [[],["─━╌-"],["Unknown","Another unknown"],
                ["? for shortcuts"]+Array(repeating:"─",count:6)] {
                try expectEqual(ActivityDetector.detect(glyph+"\n"+footer.joined(separator:"\n"),agent:agent).phase,.unknown)
            }
        }
    }

    func testActivityFooterGoalsDraftsAndGenerationChecks() throws {
        for newline in ["\n","\r\n","\u{0085}","\u{2028}"] {
            for goal in ["Goal stalled (/goal resume)","Goal blocked (/goal resume)"] {
                for footer in [["? for shortcuts",goal],[goal,"? for shortcuts"],
                    ["Unknown footer",goal,"? for shortcuts"]] {
                    let screen = ["Done 한글","›"]+footer
                    for foreign in [false,true] {
                        let value = screen.joined(separator:newline),text = foreign ? foreignActivityFooter(value) : value
                        try expectEqual(ActivityDetector.detect(text,agent:.codex).phase,.idle)
                        let draft = text.replacingOccurrences(of:"›",with:"› Fix 한글 e\u{301} 👨‍👩‍👧‍👦")
                        try expectEqual(ActivityDetector.detect(draft,agent:.codex).phase,.input)
                        try expectEqual(ActivityDetector.detect(text.replacingOccurrences(of:"›",with:"❯"),agent:.claude).phase,.unknown)
                        try expectEqual(ActivityDetector.detect(["›",goal].joined(separator:newline),agent:.codex).phase,.unknown,
                            "A goal status alone does not establish a ready composer")
                    }
                }
            }
        }
        for screen in ["› 1. Choice\n? for shortcuts","```\n›\n? for shortcuts",
            "›\n? for shortcuts\nGoal paused (/goal resume)"] {
            try expectEqual(ActivityDetector.detect(screen,agent:.codex).phase,.unknown)
        }
        let screen = "Done\n›\n? for shortcuts",date = Date(timeIntervalSince1970:10_000)
        var tracker = ActivityTracker()
        try expectEqual(tracker.observe(screen,agent:.codex,generation:"one",at:date).phase,.unknown)
        try expectEqual(tracker.observe(screen,agent:.codex,generation:"one",at:date.addingTimeInterval(2)).phase,.idle)
        try expectEqual(tracker.observe(screen,agent:.codex,generation:"two",at:date.addingTimeInterval(3)).phase,.unknown)
    }
}
