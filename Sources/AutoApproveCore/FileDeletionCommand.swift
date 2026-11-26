import Foundation

enum FileDeletionCommand {
    static let risk = SystemCommandRisk(kind: .fileDeletion, evidence: "파일 또는 디렉터리를 삭제하는 작업")
    static let candidates = ["rm", "unlink", "trash", "delete", "shred", "clean", "remove", "/dev/null"]

    static func removesFile(_ source: String, depth: Int = 0) -> Bool {
        guard depth <= 5 else { return false }
        let quick = source.range(of: #"(?i)\b(rm|rmdir|unlink|trash|shred|find|git|python\w*|node|ruby|perl)\b"#, options: .regularExpression)
        guard quick != nil else { return false }
        var words: [String] = [], word = "", quote: Character?, escaped = false, comment = false
        func finishWord() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        for ch in source {
            if comment {
                if ch != "\n" { continue }
                comment = false
            }
            if escaped { if ch != "\n" { word.append(ch) }; escaped = false; continue }
            if ch == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if ch == open { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#", word.isEmpty {
                comment = true
            } else if ";|&\n()".contains(ch) || ch == "`" {
                finishWord()
                if removesFiles(words, depth: depth) { return true }
                words.removeAll(keepingCapacity: true)
            } else if ch.isWhitespace { finishWord() }
            else { word.append(ch) }
        }
        finishWord()
        return removesFiles(words, depth: depth)
    }

    private static func removesFiles(_ words: [String], depth: Int) -> Bool {
        guard depth <= 5 else { return false }
        var args = words[...]
        while let first = args.first {
            let name = (first as NSString).lastPathComponent
            args = args.dropFirst()
            switch name {
            case "rm", "rmdir", "unlink", "trash":
                return !args.isEmpty && !args.contains("--help") && !args.contains("--version")
            case "shred":
                return args.contains { $0 == "--remove" || $0.hasPrefix("--remove=") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("u")) }
            case "git":
                var command = args
                while let option = command.first, option.hasPrefix("-") {
                    command = command.dropFirst()
                    if ["-C", "-c", "--git-dir", "--work-tree"].contains(option) { command = command.dropFirst() }
                }
                if command.first == "rm" {
                    return !command.contains("--cached") && !command.contains("--dry-run") && !command.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n") }
                }
                return command.first == "clean" && command.contains { $0.hasPrefix("-") && $0.contains("f") } &&
                    !command.contains { $0 == "--dry-run" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) }
            case "find":
                if args.contains("-delete") { return true }
                guard let index = args.firstIndex(where: { ["-exec", "-execdir"].contains($0) }) else { return false }
                return removesFiles(Array(args.suffix(from: index + 1)), depth: depth + 1)
            case "sh", "bash", "zsh", "dash":
                guard let i = args.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }), i + 1 < args.endIndex else { return false }
                return removesFile(args[i + 1], depth: depth + 1)
            case "sudo", "env", "command", "exec", "xargs", "then", "else", "do", "if", "!":
                while let option = args.first, option.hasPrefix("-") {
                    args = args.dropFirst()
                    if ["-u", "-g", "-C", "-n", "-I", "-P"].contains(option), name != "sudo" || option != "-n" { args = args.dropFirst() }
                }
            default:
                if first.contains("="), first.first != "=" { continue }
                let scriptFlag = name.hasPrefix("python") ? "-c" : ["node", "ruby", "perl"].contains(name) ? "-e" : nil
                if let scriptFlag, let i = args.firstIndex(of: scriptFlag), i + 1 < args.endIndex {
                    return args[i + 1].range(of: #"(?i)(?:\b(?:os|fs(?:\.promises)?|File|shutil)\.(?:remove|unlink(?:Sync)?|rm(?:Sync)?|rmdir(?:Sync)?|rmtree|delete)|\.unlink)\s*\("#, options: .regularExpression) != nil
                }
                return false
            }
        }
        return false
    }

    static func deletesInPatch(_ patch: String) -> Bool {
        guard patch.contains("Delete File:") || patch.contains("/dev/null") || patch.contains("deleted file mode ") else { return false }
        return patch.split(separator: "\n").contains { row in
            row.hasPrefix("*** Delete File: ") || row == "+++ /dev/null" || row.hasPrefix("deleted file mode ")
        }
    }
}
