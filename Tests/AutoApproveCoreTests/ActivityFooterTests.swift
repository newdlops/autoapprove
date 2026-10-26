import Foundation
import AutoApproveCore

private func foreignActivityFooter(_ text: String) -> String {
    let units = Array(text.utf16)
    return units.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) as String }
}

extension ApprovalTests {
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
