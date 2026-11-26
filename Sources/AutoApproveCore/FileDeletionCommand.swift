import Darwin
import Foundation

enum FileDeletionCommand {
    static let risk = SystemCommandRisk(kind: .fileDeletion, evidence: "시스템 경로 또는 디스크·볼륨 전체 삭제")
    static let review = SystemCommandRisk(kind: .settings, evidence: "삭제 대상 경로를 확인할 수 없습니다.")
    static let candidates = ["rm", "unlink", "trash", "delete", "shred", "clean", "remove", "/dev/null", "diskutil", "newfs", "mkfs", "/dev/disk", "/dev/rdisk", "wipefs", "blkdiscard", "gpt", "dd"]

    private static func strongest(_ lhs: SystemCommandRisk?, _ rhs: SystemCommandRisk?) -> SystemCommandRisk? {
        lhs == risk || rhs == risk ? risk : lhs ?? rhs
    }

    private static func systemPath(_ path: String) -> Bool {
        var p = path.lowercased()
        if p.hasPrefix("/system/volumes/data/") { p = String(p.dropFirst("/system/volumes/data".count)) }
        if p.hasPrefix("/volumes/") {
            let parts = p.split(separator: "/", maxSplits: 2)
            guard parts.count == 3 else { return true }
            p = "/" + parts[2]
        }
        if ["/", "/private", "/users", "/volumes", "/applications", "/tmp", "/private/tmp", "/private/var/tmp", "/private/var/folders", "/var/tmp", "/var/folders"].contains(p) { return true }
        if ["/private/var/tmp/", "/private/var/folders/", "/var/tmp/", "/var/folders/", "/usr/local/"].contains(where: { p.hasPrefix($0) }) { return false }
        return ["/system", "/library", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/var", "/private/var", "/cores", "/boot", "/proc", "/sys", "/lib", "/lib64"].contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    private static func physicalPath(_ path: String) -> String? {
        var prefix = path as NSString, suffix: [String] = []
        while !prefix.isEqual(to: "") {
            if let pointer = realpath(prefix.fileSystemRepresentation, nil) {
                defer { free(pointer) }
                return suffix.reversed().reduce(String(cString: pointer)) { ($0 as NSString).appendingPathComponent($1) }
            }
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            suffix.append(prefix.lastPathComponent)
            let parent = prefix.deletingLastPathComponent
            guard parent != prefix as String else { return nil }
            prefix = parent as NSString
        }
        return nil
    }

    static func pathRisk(_ target: String?, cwd: String, unlinkLeaf: Bool = false) -> SystemCommandRisk? {
        guard var target, !target.isEmpty, !target.contains("…"), !target.contains("\n") else { return review }
        for prefix in ["~", "$HOME", "${HOME}"] where target == prefix || target.hasPrefix(prefix + "/") {
            target = NSHomeDirectory() + target.dropFirst(prefix.count)
            break
        }
        let literal = target.prefix { !"$*?[]{}`~<>!\\".contains($0) }
        guard !literal.isEmpty || target.first == "*" || target.first == "?" else { return review }
        let dynamic = literal.count != target.count
        let base = dynamic ? (literal.hasSuffix("/") ? String(literal) : (String(literal) as NSString).deletingLastPathComponent) : target
        guard base.hasPrefix("/") || cwd.hasPrefix("/") else { return review }
        let absolute = base.hasPrefix("/") ? base : (base.isEmpty ? cwd : (cwd as NSString).appendingPathComponent(base))
        let leafPattern = (target as NSString).lastPathComponent
        let fixedDirectory = (target as NSString).deletingLastPathComponent.rangeOfCharacter(from: CharacterSet(charactersIn: "*?$[]{}`~<>!\\")) == nil
        let simpleGlob = dynamic && fixedDirectory && leafPattern.range(of: #"^[\p{L}\p{N} _.*?-]+$"#, options: .regularExpression) != nil
        func locationRisk(_ path: String) -> SystemCommandRisk? {
            if simpleGlob {
                let removableChildren = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", NSHomeDirectory()]
                if removableChildren.contains(path) { return nil }
            }
            if systemPath(path) { return risk }
            return path == NSHomeDirectory() ? review : nil
        }
        let lexical = URL(fileURLWithPath: absolute).standardizedFileURL.path
        if let verdict = locationRisk(lexical) { return verdict }
        var info = stat()
        let deletingLink = unlinkLeaf && !dynamic && !target.hasSuffix("/") && lstat(absolute, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        let physical: String?
        if deletingLink {
            let link = absolute as NSString
            physical = physicalPath(link.deletingLastPathComponent).map { ($0 as NSString).appendingPathComponent(link.lastPathComponent) }
        } else { physical = physicalPath(absolute) }
        guard let physical else { return review }
        if let verdict = locationRisk(physical) { return verdict }
        if !deletingLink {
            let properties = try? URL(fileURLWithPath: physical).resourceValues(forKeys: [.isVolumeKey])
            if properties?.isVolume == true { return risk }
        }
        return dynamic && !simpleGlob ? review : nil
    }

    static func patchRisk(_ patch: String, cwd: String) -> SystemCommandRisk? {
        guard patch.contains("Delete File:") || patch.contains("/dev/null") || patch.contains("deleted file mode ") else { return nil }
        var oldPath: String?, deleted = false, result: SystemCommandRisk?
        for line in patch.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git ") {
                if deleted { result = strongest(result, pathRisk(oldPath, cwd: cwd)) }
                let fields = line.split(separator: " ")
                oldPath = fields.count == 4 && fields[2].hasPrefix("a/") && fields[3].hasPrefix("b/") && fields[2].dropFirst(2) == fields[3].dropFirst(2) ? String(fields[2].dropFirst(2)) : nil
                deleted = false
            } else if line.hasPrefix("*** Delete File: ") {
                result = strongest(result, pathRisk(String(line.dropFirst(17)), cwd: cwd))
            } else if line.hasPrefix("--- ") {
                var path = String(line.dropFirst(4).prefix { $0 != "\t" })
                if path.hasPrefix("a/") { path.removeFirst(2) }
                oldPath = path.hasPrefix("\"") ? nil : path
            } else if line == "+++ /dev/null" {
                result = strongest(result, pathRisk(oldPath, cwd: cwd))
                oldPath = nil; deleted = false
            } else if line.hasPrefix("deleted file mode ") { deleted = true }
        }
        return deleted ? strongest(result, pathRisk(oldPath, cwd: cwd)) : result
    }

    private static let commands = try! NSRegularExpression(pattern: #"(?i)\b(rm|rmdir|unlink|trash|shred|find|git|python\w*|node|ruby|perl|diskutil|newfs\w*|mkfs|dd|wipefs|blkdiscard|gpt)\b"#)

    static func commandRisk(_ source: String, cwd: String, depth: Int = 0) -> SystemCommandRisk? {
        guard depth <= 5 else { return review }
        guard commands.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil else { return nil }
        var words: [String] = [], word = "", quote: Character?, escaped = false, comment = false
        var directory = cwd, result: SystemCommandRisk?
        func finishWord() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        func finishCommand(continuesOnSuccess: Bool = false) {
            finishWord()
            result = strongest(result, classify(words, cwd: directory, depth: depth))
            if let first = words.first, ["cd", "pushd", "popd"].contains(first) {
                let path = words.count == 2 && first != "popd" ? words[1] : ""
                if !continuesOnSuccess || path.rangeOfCharacter(from: CharacterSet(charactersIn: "$*?[]{}`~")) != nil { directory = "" }
                else if path.hasPrefix("/") { directory = path }
                else if !path.isEmpty, directory.hasPrefix("/"), !path.hasPrefix("-"), !path.contains("$"), !path.contains("~") {
                    directory = (directory as NSString).appendingPathComponent(path)
                } else { directory = "" }
            }
            words.removeAll(keepingCapacity: true)
        }
        var characters = source.makeIterator()
        var current = characters.next()
        while let ch = current {
            current = characters.next()
            if comment {
                if ch != "\n" { continue }
                comment = false
            }
            if escaped { if ch != "\n" { word.append(ch) }; escaped = false; continue }
            if ch == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if ch == open { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" { quote = ch }
            else if ch == "#", word.isEmpty { comment = true }
            else if ";|&\n()`".contains(ch) {
                let and = ch == "&" && current == "&"
                finishCommand(continuesOnSuccess: and)
                if and { current = characters.next() }
                else if directory != cwd { directory = "" }
            }
            else if ch.isWhitespace { finishWord() }
            else { word.append(ch) }
        }
        finishCommand()
        return result
    }

    private static func classify(_ words: [String], cwd: String, depth: Int) -> SystemCommandRisk? {
        guard depth <= 5 else { return review }
        var args = words[...], directory = cwd
        func targets(_ paths: [String], unlinkLeaf: Bool = false) -> SystemCommandRisk? {
            paths.reduce(nil as SystemCommandRisk?) { strongest($0, pathRisk($1, cwd: directory, unlinkLeaf: unlinkLeaf)) }
        }
        while let first = args.first {
            let name = (first as NSString).lastPathComponent.lowercased()
            args = args.dropFirst()
            switch name {
            case "rm", "rmdir", "unlink", "trash", "shred":
                let optionsBeforeEnd = args.prefix { $0 != "--" }
                guard !optionsBeforeEnd.contains("--help"), !optionsBeforeEnd.contains("--version") else { return nil }
                var options = true, paths: [String] = []
                for arg in args {
                    if options && arg == "--" { options = false }
                    else if !options || !arg.hasPrefix("-") { paths.append(arg) }
                }
                return paths.isEmpty ? review : targets(paths, unlinkLeaf: ["rm", "unlink"].contains(name))
            case "diskutil":
                let destructive = ["erasedisk","erasevolume","erasedata","partitiondisk","secureerase","zerodisk","randomdisk","resetfusion","deletecontainer","deletevolume","deletevolumegroup","erase","delete","destroy"]
                return args.contains(where: { destructive.contains($0.lowercased()) }) ? risk : nil
            case "dd":
                guard let out = args.first(where: { $0.hasPrefix("of=") }) else { return nil }
                let target = String(out.dropFirst(3))
                if target == "/dev/null" { return nil }
                return pathRisk(target, cwd: directory)
            case "wipefs", "blkdiscard", "gpt":
                return args.contains(where: { $0.hasPrefix("/dev/") }) && (name != "gpt" || args.contains("destroy") || args.contains("remove")) ? risk : nil
            case "git":
                while let option = args.first, option.hasPrefix("-") {
                    args = args.dropFirst()
                    if ["-C", "-c", "--git-dir", "--work-tree"].contains(option), let value = args.first {
                        if option == "-C" || option == "--work-tree" {
                            directory = value.hasPrefix("/") ? value : directory.hasPrefix("/") ? (directory as NSString).appendingPathComponent(value) : ""
                        }
                        args = args.dropFirst()
                    } else if option.hasPrefix("--work-tree=") { directory = String(option.dropFirst(12)) }
                }
                guard let command = args.first, ["rm","clean"].contains(command) else { return nil }
                args = args.dropFirst()
                guard !args.contains("--cached"), !args.contains("--dry-run"), !args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n") }) else { return nil }
                let paths = args.filter { !$0.hasPrefix("-") }
                return targets(paths.isEmpty ? ["."] : Array(paths))
            case "find":
                guard args.contains("-delete") || args.contains(where: { ["-exec", "-execdir"].contains($0) }) else { return nil }
                let roots = Array(args.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" })
                let scope = targets(roots.isEmpty ? ["."] : roots)
                if args.contains("-delete") { return scope }
                guard let exec = args.firstIndex(where: { ["-exec","-execdir"].contains($0) }) else { return nil }
                let action = Array(args.suffix(from: exec + 1).prefix { $0 != ";" && $0 != "+" })
                guard action.contains("{}") else { return classify(action, cwd: directory, depth: depth+1) }
                let substituted = action.map { $0 == "{}" ? (roots.first ?? ".") : $0 }
                let commandRisk = classify(substituted, cwd: directory, depth: depth+1)
                return ["rm","unlink","rmdir","trash"].contains((action.first as NSString?)?.lastPathComponent ?? "") ? strongest(scope, commandRisk) : commandRisk
            case "sh", "bash", "zsh", "dash":
                guard let i = args.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }), i+1 < args.endIndex else { return nil }
                return commandRisk(args[i+1], cwd: directory, depth: depth+1)
            case "xargs":
                let command = args.drop { !["rm", "rmdir", "unlink", "trash", "shred"].contains(($0 as NSString).lastPathComponent) }
                return command.isEmpty ? nil : strongest(review, classify(Array(command), cwd: directory, depth: depth + 1))
            case "sudo", "env", "command", "exec", "then", "else", "do", "if", "!":
                while let option = args.first, option.hasPrefix("-") {
                    args = args.dropFirst()
                    if ["-u","-g","-C","-n","-I","-P"].contains(option), name != "sudo" || option != "-n" {
                        if option == "-C" { directory = args.first ?? "" }
                        args = args.dropFirst()
                    }
                }
            default:
                if name == "mkfs" || name.hasPrefix("mkfs.") || name == "newfs" || name.hasPrefix("newfs_") { return risk }
                if first.contains("="), first.first != "=" { continue }
                let flag = name.hasPrefix("python") ? "-c" : ["node","ruby","perl"].contains(name) ? "-e" : nil
                guard let flag, let i = args.firstIndex(of: flag), i+1 < args.endIndex else { return nil }
                let script = args[i+1]
                let pattern = #"(?i)(?:\b(?:os|fs(?:\.promises)?|File|shutil)\.(?:remove|unlink(?:Sync)?|rm(?:Sync)?|rmdir(?:Sync)?|rmtree|delete)|\.unlink)\s*\("#
                let methods = try! NSRegularExpression(pattern: pattern)
                var result: SystemCommandRisk?
                for match in methods.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
                    guard let method = Range(match.range, in: script) else { return review }
                    let argument = script[method.upperBound...].trimmingCharacters(in: .whitespaces)
                    guard let delimiter = argument.first, delimiter == "'" || delimiter == "\"",
                          let end = argument.dropFirst().firstIndex(of: delimiter),
                          let next = argument[end...].dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).first,
                          next == ")" || next == "," else { result = strongest(result, review); continue }
                    let path = String(argument[argument.index(after: argument.startIndex)..<end])
                    result = strongest(result, path.contains("\\") ? review : pathRisk(path, cwd: directory))
                }
                return result
            }
        }
        return nil
    }
}
