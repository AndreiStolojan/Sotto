import Darwin
import Foundation
import os

/// Runs one child process to completion for app integrations (shell commands, osascript, unzip).
///
/// Standard input is written while stdout and stderr drain concurrently, so a child that fills a pipe
/// cannot deadlock. Each stream keeps at most `outputLimit` bytes and keeps draining past the limit.
/// A timeout or Task cancellation sends SIGTERM to the whole process tree, then SIGKILL after a grace
/// period, so a shell cannot leave its children running.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let stdout: Data
        let stderr: Data
        /// True when the stream exceeded the byte limit or did not reach EOF before the drain
        /// deadline, so the captured bytes may be incomplete.
        let isStdoutTruncated: Bool
        let isStderrTruncated: Bool

        var succeeded: Bool { terminationReason == .exit && status == 0 }
        /// Lossy decoding, because a byte limit can split a UTF-8 sequence.
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    static let defaultOutputLimit = 1 << 20

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval,
        outputLimit: Int = defaultOutputLimit,
        terminationGracePeriod: TimeInterval = 2
    ) async throws -> Output {
        try Task.checkCancellation()

        let execution = ProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            outputLimit: max(0, outputLimit),
            terminationGracePeriod: terminationGracePeriod
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.stop(because: .cancelled)
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    enum StopReason {
        case timedOut
        case cancelled
    }

    private static let logger = Logger(subsystem: "ro.andrei.Voce", category: "ProcessRunner")
    private static let drainTimeout: TimeInterval = 1

    private let process = Process()
    private let standardInput: Data?
    private let terminationGracePeriod: TimeInterval
    private let stdoutReader: BoundedPipeReader
    private let stderrReader: BoundedPipeReader
    private let inputPipe: Pipe?
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let queue = DispatchQueue(label: "ro.andrei.Voce.process-runner", qos: .userInitiated)

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessRunner.Output, Error>?
    private var stopReason: StopReason?
    private var hasLaunched = false
    private var hasExited = false
    private var isFinished = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?,
        outputLimit: Int,
        terminationGracePeriod: TimeInterval
    ) {
        self.standardInput = standardInput
        self.terminationGracePeriod = terminationGracePeriod
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        inputPipe = standardInput == nil ? nil : Pipe()
        stdoutReader = BoundedPipeReader(handle: stdoutPipe.fileHandleForReading, limit: outputLimit)
        stderrReader = BoundedPipeReader(handle: stderrPipe.fileHandleForReading, limit: outputLimit)

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<ProcessRunner.Output, Error>) {
        let shouldLaunch = lock.withLock {
            guard stopReason == nil else { return false }
            self.continuation = continuation
            return true
        }
        guard shouldLaunch else {
            closeResources()
            continuation.resume(throwing: CancellationError())
            return
        }

        // Install before launch so a fast exit cannot be missed.
        process.terminationHandler = { [self] _ in
            // Once reaped, the root PID can be reused, so it is never signalled again.
            lock.withLock { hasExited = true }
            queue.async { self.finishAfterExit() }
        }

        do {
            try process.run()
        } catch {
            // Close the write ends the child would have owned; readers see EOF and stop themselves.
            // Read ends close when the pipes deallocate, so no handler reads a closed descriptor.
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            closeResources()
            finish(.failure(ProcessRunner.Failure.launchFailed(error.localizedDescription)))
            return
        }

        let pendingStop = lock.withLock {
            hasLaunched = true
            return stopReason
        }

        writeStandardInput()

        if let pendingStop {
            terminateTree(for: pendingStop)
        } else {
            queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                self?.stop(because: .timedOut)
            }
        }
    }

    func stop(because reason: StopReason) {
        let shouldTerminate = lock.withLock {
            guard !isFinished, stopReason == nil else { return false }
            stopReason = reason
            return hasLaunched
        }
        // Before launch, start() sees stopReason and refuses to launch or terminates right after it.
        if shouldTerminate {
            queue.async { self.terminateTree(for: reason) }
        }
    }

    private func writeStandardInput() {
        guard let inputPipe else { return }
        let handle = inputPipe.fileHandleForWriting
        let data = standardInput ?? Data()

        DispatchQueue.global(qos: .utility).async {
            defer { try? handle.close() }
            // A child that exits without reading stdin must produce EPIPE here, not kill the app.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            guard !data.isEmpty else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// Sends SIGTERM to the tree, then SIGKILL to every original target still alive after the
    /// grace period. Targets are captured once up front: a shell that exits on SIGTERM orphans its
    /// children, and they could no longer be found through the root afterwards.
    private func terminateTree(for reason: StopReason) {
        let rootPID = process.processIdentifier
        // After the root is reaped its PID may belong to an unrelated process, and its orphans are
        // no longer reachable through it, so there is nothing safe left to signal.
        guard lock.withLock({ !hasExited }) else { return }
        let descendants = ProcessTree.descendants(of: rootPID)

        ProcessTree.signal(descendants, signal: SIGTERM)
        if lock.withLock({ !hasExited }) {
            _ = kill(rootPID, SIGTERM)
        }

        queue.asyncAfter(deadline: .now() + terminationGracePeriod) { [self] in
            // Runs even if the root already exited and the run finished.
            ProcessTree.signal(descendants.filter(ProcessTree.isAlive), signal: SIGKILL)
            guard lock.withLock({ !hasExited }) else { return }
            _ = kill(rootPID, SIGKILL)

            // The termination handler normally reports the exit. Report anyway if it never arrives.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                guard !lock.withLock({ isFinished }) else { return }
                Self.logger.error("Process \(rootPID, privacy: .public) did not exit after SIGKILL")
                closeResources()
                finish(.failure(error(for: reason)))
            }
        }
    }

    private func finishAfterExit() {
        // Grandchildren can keep the pipes open after the root exits, so drainage is bounded.
        let deadline = DispatchTime.now() + Self.drainTimeout
        let stdoutDrained = stdoutReader.wait(until: deadline)
        let stderrDrained = stderrReader.wait(until: deadline)
        closeResources()

        if let reason = lock.withLock({ stopReason }) {
            finish(.failure(error(for: reason)))
            return
        }

        let stdout = stdoutReader.snapshot()
        let stderr = stderrReader.snapshot()
        finish(
            .success(
                ProcessRunner.Output(
                    status: process.terminationStatus,
                    terminationReason: process.terminationReason,
                    stdout: stdout.data,
                    stderr: stderr.data,
                    isStdoutTruncated: stdout.isTruncated || !stdoutDrained,
                    isStderrTruncated: stderr.isTruncated || !stderrDrained
                )))
    }

    private func error(for reason: StopReason) -> Error {
        switch reason {
        case .timedOut: return ProcessRunner.Failure.timedOut
        case .cancelled: return CancellationError()
        }
    }

    private func closeResources() {
        stdoutReader.stop()
        stderrReader.stop()
    }

    private func finish(_ result: Result<ProcessRunner.Output, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<ProcessRunner.Output, Error>? in
            guard !isFinished else { return nil }
            isFinished = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        // Breaks the process -> handler -> execution reference cycle.
        process.terminationHandler = nil
        continuation?.resume(with: result)
    }
}

/// Collects up to `limit` bytes from a pipe and discards the rest while still draining it.
private final class BoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var data = Data()
    private var isTruncated = false
    private var isStopped = false

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
        drained.enter()
        handle.readabilityHandler = { [weak self] handle in
            self?.read(from: handle)
        }
    }

    func wait(until deadline: DispatchTime) -> Bool {
        drained.wait(timeout: deadline) == .success
    }

    func snapshot() -> (data: Data, isTruncated: Bool) {
        lock.withLock { (data, isTruncated) }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldStop else { return }
        // Closing here could race a handler still reading; the pipe closes the descriptor on deallocation.
        handle.readabilityHandler = nil
        drained.leave()
    }

    private func read(from handle: FileHandle) {
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
            stop()  // EOF
            return
        }

        lock.withLock {
            let remaining = limit - data.count
            if chunk.count <= remaining {
                data.append(chunk)
            } else {
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                isTruncated = true
            }
        }
    }
}

/// Finds and signals the descendants of a process. PIDs come from a live `pgrep` walk, so a
/// descendant that exits and has its PID reused within the grace period is the remaining risk.
enum ProcessTree {
    /// Signals deepest descendants first, so parents cannot respawn them in between.
    static func signal(_ pids: [pid_t], signal: Int32) {
        for pid in pids.reversed() {
            _ = kill(pid, signal)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func descendants(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [rootPID]
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let parentPID = queue.removeFirst()
            guard visited.insert(parentPID).inserted else { continue }
            let childPIDs = children(of: parentPID)
            result.append(contentsOf: childPIDs)
            queue.append(contentsOf: childPIDs)
        }

        return result
    }

    private static func children(of parentPID: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(parentPID)"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
        } catch {
            return []
        }

        // pgrep prints a few short lines, far below the pipe buffer, so reading to EOF is safe.
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
