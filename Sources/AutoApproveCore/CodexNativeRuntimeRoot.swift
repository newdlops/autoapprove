import Foundation
import Darwin

/// Short, user-owned IPC namespace. Existing/read-only inspection never creates it.
enum CodexNativeRuntimeRoot {
    static var path: String { "/private/tmp/aa-codex-" + String(getuid()) }
    static func existing(at path: String = CodexNativeRuntimeRoot.path) -> String? { try? validate(path) }
    @discardableResult static func prepare(at path: String = CodexNativeRuntimeRoot.path) throws -> String {
        guard validPath(path) else { throw failure }
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw failure }
        return try validate(path)
    }
    private static var failure: AppError {
        .message("Codex 제어 등록 폴더의 소유자·경로·권한을 확인하지 못했습니다. 기존 폴더를 변경하지 않았습니다.")
    }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 40 &&
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validate(_ path: String) throws -> String {
        guard validPath(path) else { throw failure }
        var before = stat(), pinned = stat(), after = stat()
        guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid(), before.st_mode & 0o077 == 0,
              let pointer = realpath(path, nil) else { throw failure }
        defer { free(pointer) }
        guard String(cString: pointer) == path else { throw failure }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        defer { close(fd) }
        guard fstat(fd, &pinned) == 0, lstat(path, &after) == 0,
              pinned.st_dev == before.st_dev, pinned.st_ino == before.st_ino,
              after.st_dev == pinned.st_dev, after.st_ino == pinned.st_ino,
              after.st_mode & S_IFMT == S_IFDIR, after.st_uid == getuid(), after.st_mode & 0o077 == 0
        else { throw failure }
        return path
    }
}
