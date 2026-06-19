import Foundation

struct ProcessRunResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunError: LocalizedError {
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) 执行超时（\(Int(timeout)) 秒）"
        }
    }
}

enum ProcessRunner {
    nonisolated static func run(executableURL: URL,
                                arguments: [String],
                                timeout: TimeInterval,
                                qos: DispatchQoS.QoSClass = .userInitiated) async throws -> ProcessRunResult {
        let state = ProcessRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.installContinuation(continuation) else { return }
                DispatchQueue.global(qos: qos).async {
                    runSynchronously(
                        executableURL: executableURL,
                        arguments: arguments,
                        timeout: timeout,
                        state: state
                    )
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private nonisolated static func runSynchronously(executableURL: URL,
                                                     arguments: [String],
                                                     timeout: TimeInterval,
                                                     state: ProcessRunState) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard state.setProcess(process) else { return }

        do {
            try process.run()
        } catch {
            state.finish(.failure(error))
            return
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        let timeoutWorkItem = DispatchWorkItem {
            state.timeout(executable: executableURL.lastPathComponent, timeout: timeout)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        if state.isStopped, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        readGroup.wait()

        state.finish(.success(ProcessRunResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data
        )))
    }
}

nonisolated private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<ProcessRunResult, Error>?
    private var isFinished = false
    private var stoppedError: Error?

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedError != nil
    }

    func installContinuation(_ continuation: CheckedContinuation<ProcessRunResult, Error>) -> Bool {
        lock.lock()
        if let stoppedError {
            lock.unlock()
            continuation.resume(throwing: stoppedError)
            return false
        }
        if isFinished {
            lock.unlock()
            continuation.resume(throwing: RuntimeError("进程状态已结束"))
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setProcess(_ process: Process) -> Bool {
        lock.lock()
        if isFinished {
            lock.unlock()
            if process.isRunning {
                process.terminate()
            }
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func cancel() {
        stop(throwing: CancellationError())
    }

    func timeout(executable: String, timeout: TimeInterval) {
        stop(throwing: ProcessRunError.timedOut(executable: executable, timeout: timeout))
    }

    func finish(_ result: Result<ProcessRunResult, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        process = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func stop(throwing error: Error) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        stoppedError = error
        let process = process
        let continuation = continuation
        self.continuation = nil
        self.process = nil
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
        continuation?.resume(throwing: error)
    }
}

nonisolated private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}
