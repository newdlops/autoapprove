import Foundation

final class SessionMetadataReads: Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AutoApprove.session-metadata"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    func map<Input: Sendable, Output: Sendable>(_ inputs: [Input], priority: TaskPriority,
        read: @escaping @Sendable (Input) -> Output) async throws -> [Output] {
        try await withThrowingTaskGroup(of: (Int, Output).self) { tasks in
            func schedule(_ index: Int) {
                let input = inputs[index]
                tasks.addTask(priority: priority) { [queue] in
                    try Task.checkCancellation()
                    let value: Output = await withCheckedContinuation { continuation in
                        let operation = BlockOperation { continuation.resume(returning: read(input)) }
                        operation.qualityOfService = priority >= .userInitiated ? .userInitiated : .utility
                        operation.queuePriority = priority >= .userInitiated ? .high : .normal
                        queue.addOperation(operation)
                    }
                    try Task.checkCancellation()
                    return (index, value)
                }
            }
            var next = min(queue.maxConcurrentOperationCount, inputs.count)
            for index in 0..<next { schedule(index) }
            var results: [(Int, Output)] = []
            while let result = try await tasks.next() {
                results.append(result)
                if next < inputs.count { schedule(next); next += 1 }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
