import Darwin
import Foundation

struct TerminalProfileCommandFile {
    let url: URL

    init(command: String, directory: URL = FileManager.default.temporaryDirectory) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AppError.message("복원 명령을 보관할 개인 임시 폴더를 확인하지 못했습니다.")
        }
        url = directory.appendingPathComponent("aa-restore-" + UUID().uuidString)
        let quoted = HookInstaller.quote(url.path)
        guard quoted.utf8.count + 8 < 512, !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError.message("복원 명령의 임시 경로를 확인하지 못했습니다.")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: Data(("/bin/rm -- " + quoted + " && " + command + "\n").utf8))
            try file.close()
        } catch {
            withdraw()
            throw error
        }
    }

    @discardableResult func withdraw() -> Bool {
        unlink(url.path) == 0
    }

    func waitForShell(timeout: TimeInterval = 5) throws {
        try TerminalProfileReadiness.wait(timeout: timeout, message: "새 셸이 복원 명령을 읽지 않았습니다. 탭 상태를 확인한 뒤 다시 복원해주세요.") {
            var info = stat()
            if lstat(url.path, &info) == 0 { return nil as Bool? }
            if errno == ENOENT { return true }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
