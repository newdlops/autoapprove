import Foundation
import Darwin

enum CommandPipeFailure: Error {
    case timeout, outputLimit, errorLimit, read
}

/// The child callback and the private I/O queue share only this small receipt.
final class CommandPipeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var remaining: Int
    private var failure: CommandPipeFailure?
    let changed = DispatchSemaphore(value:0)
    let exited = DispatchSemaphore(value:0)
    init(input: Bool) { remaining = input ? 3 : 2 }
    func didExit(_ value: Int32) { lock.lock(); status = value; lock.unlock(); exited.signal(); changed.signal() }
    func channelDone() { lock.lock(); remaining -= 1; lock.unlock(); changed.signal() }
    func fail(_ value: CommandPipeFailure) {
        lock.lock(); if failure == nil { failure = value }; lock.unlock(); changed.signal()
    }
    func snapshot() -> (status:Int32?, remaining:Int, failure:CommandPipeFailure?) {
        lock.lock(); defer { lock.unlock() }; return (status,remaining,failure)
    }
}

/// Events, text, carry bytes and FileHandles are confined to one invocation's queue.
final class CommandPipeIO: @unchecked Sendable {
    private let queue = DispatchQueue(label:"autoapprove.command.io")
    private let closed = DispatchGroup()
    private let output: CommandPipeReader
    private let error: CommandPipeReader
    private let input: CommandPipeWriter?
    init(stdout: FileHandle, stderr: FileHandle, stdin: FileHandle?, data: Data?,
         outputLimit: Int, errorLimit: Int, completion: CommandPipeCompletion) throws {
        output = CommandPipeReader(stdout,limit:outputLimit,error:false,completion:completion)
        error = CommandPipeReader(stderr,limit:errorLimit,error:true,completion:completion)
        input = stdin.flatMap { handle in data.map { CommandPipeWriter(handle,data:$0,completion:completion) } }
        try Self.nonblocking(stdout); try Self.nonblocking(stderr)
        if let stdin {
            try Self.nonblocking(stdin)
            guard fcntl(stdin.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else { throw AppError.message("명령 입력 파이프를 준비하지 못했습니다.") }
        }
    }
    private static func nonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor,F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor,F_SETFL,flags | O_NONBLOCK) == 0 else {
            throw AppError.message("명령 파이프를 준비하지 못했습니다.")
        }
    }
    func start() {
        queue.sync { output.start(queue,closed:closed); error.start(queue,closed:closed); input?.start(queue,closed:closed) }
    }
    func take() -> (String,String) { queue.sync { (output.take(),error.take()) } }
    func close() {
        queue.sync { output.cancel(); error.cancel(); input?.cancel() }
        // Cancel handlers only close these nonblocking pipe ends. Never let a
        // descendant's inherited descriptor extend the caller's cleanup wait.
        _ = closed.wait(timeout:.now()+0.1)
    }
}

private final class CommandPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let isError: Bool
    private let completion: CommandPipeCompletion
    private var source: DispatchSourceRead?
    private var finished = false
    private var text = ""
    private var rawBytes = 0, decodedBytes = 0, pending = 0
    private var reserved = false
    private var carry: (UInt8,UInt8,UInt8) = (0,0,0)
    init(_ handle: FileHandle,limit: Int,error: Bool,completion: CommandPipeCompletion) {
        self.handle = handle; self.limit = limit; isError = error; self.completion = completion
    }
    func start(_ queue: DispatchQueue,closed: DispatchGroup) {
        let source = DispatchSource.makeReadSource(fileDescriptor:handle.fileDescriptor,queue:queue)
        self.source = source; closed.enter()
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [handle] in try? handle.close(); closed.leave() }
        source.resume()
    }
    private func drain() {
        guard !finished else { return }
        guard completion.snapshot().failure == nil else { cancel(); return }
        withUnsafeTemporaryAllocation(of:UInt8.self,capacity:16_388) { buffer in
            // Bound each event turn so another pipe and cancellation can run.
            for _ in 0..<4 {
                if pending > 0 { buffer[0] = carry.0 }
                if pending > 1 { buffer[1] = carry.1 }
                if pending > 2 { buffer[2] = carry.2 }
                let count = Darwin.read(handle.fileDescriptor,buffer.baseAddress!.advanced(by:pending),min(16_384,limit-rawBytes+1))
                if count > 0 {
                    guard count <= limit-rawBytes else { overflow(); return }
                    rawBytes += count
                    let total = pending+count, bytes = UnsafeBufferPointer(start:buffer.baseAddress,count:total)
                    pending = Self.incompleteSuffix(bytes)
                    guard append(UnsafeBufferPointer(start:buffer.baseAddress,count:total-pending)) else { return }
                    if pending > 0 { carry.0 = buffer[total-pending] }
                    if pending > 1 { carry.1 = buffer[total-pending+1] }
                    if pending > 2 { carry.2 = buffer[total-pending+2] }
                } else if count == 0 {
                    if pending > 0 {
                        buffer[0] = carry.0; if pending > 1 { buffer[1] = carry.1 }; if pending > 2 { buffer[2] = carry.2 }
                        guard append(UnsafeBufferPointer(start:buffer.baseAddress,count:pending)) else { return }
                        pending = 0
                    }
                    finish(); return
                } else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else { completion.fail(.read); cancel(); return }
            }
        }
    }
    private func append(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !bytes.isEmpty else { return true }
        let chunk = String(decoding:bytes,as:UTF8.self), count = chunk.utf8.count
        guard count <= limit-decodedBytes else { overflow(); return false }
        // Small replies stay small. Once a stream is substantial, reserve its
        // fixed budget before growth copies another complete large string.
        if !reserved, decodedBytes+count >= 131_072 {
            text.reserveCapacity(limit+64); reserved = true
        }
        text.append(contentsOf:chunk); decodedBytes += count; return true
    }
    private func overflow() { completion.fail(isError ? .errorLimit : .outputLimit); cancel() }
    /// Defer only a valid, incomplete UTF-8 prefix. Everything else is repaired
    /// by the standard decoder now, exactly as one complete decoding would be.
    private static func incompleteSuffix(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var start = bytes.count-1
        while start > 0, bytes.count-start < 4, bytes[start] & 0xc0 == 0x80 { start -= 1 }
        let first = bytes[start], count = bytes.count-start, wanted: Int
        switch first {
        case 0xc2...0xdf: wanted = 2
        case 0xe0...0xef: wanted = 3
        case 0xf0...0xf4: wanted = 4
        default: return 0
        }
        guard count < wanted else { return 0 }
        if count > 1 {
            for index in (start+1)..<bytes.count where bytes[index] & 0xc0 != 0x80 { return 0 }
            let second = bytes[start+1]
            if first == 0xe0 && second < 0xa0 || first == 0xed && second > 0x9f ||
                first == 0xf0 && second < 0x90 || first == 0xf4 && second > 0x8f { return 0 }
        }
        return count
    }
    private func finish() {
        guard !finished else { return }; finished = true
        if let source { source.cancel(); self.source = nil } else { try? handle.close() }
        completion.channelDone()
    }
    func cancel() { text = ""; pending = 0; finish() }
    func take() -> String { let value = text; text = ""; return value }
}

private final class CommandPipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let completion: CommandPipeCompletion
    private var data: Data
    private var offset = 0
    private var source: DispatchSourceWrite?
    private var finished = false
    init(_ handle: FileHandle,data: Data,completion: CommandPipeCompletion) {
        self.handle = handle; self.data = data; self.completion = completion
    }
    func start(_ queue: DispatchQueue,closed: DispatchGroup) {
        let source = DispatchSource.makeWriteSource(fileDescriptor:handle.fileDescriptor,queue:queue)
        self.source = source; closed.enter()
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [handle] in try? handle.close(); closed.leave() }
        source.resume()
    }
    private func drain() {
        guard !finished else { return }
        guard completion.snapshot().failure == nil else { cancel(); return }
        if offset == data.count { cancel(); return }
        var ended = false
        data.withUnsafeBytes { bytes in
            for _ in 0..<4 {
                let count = Darwin.write(handle.fileDescriptor,bytes.baseAddress!.advanced(by:offset),min(16_384,data.count-offset))
                if count > 0 { offset += count; if offset == data.count { ended = true; return } }
                else if count < 0 && errno == EINTR { continue }
                else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                else { ended = true; return } // Preserve legacy ignored write errors, including EPIPE.
            }
        }
        if ended { cancel() }
    }
    func cancel() {
        guard !finished else { return }; finished = true; data = Data()
        if let source { source.cancel(); self.source = nil } else { try? handle.close() }
        completion.channelDone()
    }
}
