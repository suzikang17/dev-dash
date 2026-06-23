import Foundation

/// Thin wrapper around `Process` that fixes the pipe-buffer deadlock and
/// gives async/await + streaming APIs.
enum ShellRunner {

    // MARK: - One-shot

    /// Run a process to completion and return all of stdout.
    /// Drains stdout and stderr concurrently via `readabilityHandler` to avoid
    /// the 64KB pipe-buffer deadlock that bites `Process` users.
    static func run(_ binary: String, args: [String], cwd: String? = nil, timeout: Double = 30) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            if let cwd = cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Need to drain BOTH pipes concurrently while the child runs,
            // otherwise either can deadlock the child.
            let lock = NSLock()
            var collected = Data()
            var resumed = false

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock(); collected.append(chunk); lock.unlock()
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }

            process.terminationHandler = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let final = collected
                let alreadyResumed = resumed
                resumed = true
                lock.unlock()
                if alreadyResumed { return }
                cont.resume(returning: String(data: final, encoding: .utf8))
            }

            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                lock.lock()
                let alreadyResumed = resumed
                resumed = true
                lock.unlock()
                if !alreadyResumed { cont.resume(returning: nil) }
            }
        }
    }

    /// Outcome of a one-shot command where success/failure matters.
    struct CommandResult {
        let output: String   // combined stdout + stderr, for display
        let exitCode: Int32
        var ok: Bool { exitCode == 0 }
    }

    /// Like `run`, but captures combined stdout+stderr and the process exit code.
    /// Use for mutating commands (e.g. `gh pr merge`) where the caller must know
    /// whether it actually succeeded — many tools report status on stderr.
    static func runResult(_ binary: String, args: [String], cwd: String? = nil, timeout: Double = 60) async -> CommandResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            if let cwd = cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let lock = NSLock()
            var collected = Data()
            var resumed = false

            let drain: (FileHandle) -> Void = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                lock.lock(); collected.append(chunk); lock.unlock()
            }
            outPipe.fileHandleForReading.readabilityHandler = drain
            errPipe.fileHandleForReading.readabilityHandler = drain

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Final synchronous drain: the async readability handlers may not
                // have appended the last chunk yet, and for short commands that
                // chunk is often the entire message (e.g. gh's merge result/error).
                let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                collected.append(tailOut)
                collected.append(tailErr)
                let final = collected
                let already = resumed
                resumed = true
                lock.unlock()
                if already { return }
                let text = String(data: final, encoding: .utf8) ?? ""
                cont.resume(returning: CommandResult(output: text, exitCode: proc.terminationStatus))
            }

            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                lock.lock(); let already = resumed; resumed = true; lock.unlock()
                if !already {
                    cont.resume(returning: CommandResult(output: error.localizedDescription, exitCode: -1))
                }
            }
        }
    }

    // MARK: - Long-running with streaming output

    /// Start a long-running process. Returns a handle that exposes a line-by-line
    /// `AsyncStream` and a `stop()` method. Caller owns the handle.
    static func start(_ binary: String, args: [String], cwd: String? = nil) throws -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd = cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let running = RunningProcess(process: process)
        try running.start()
        return running
    }
}

/// Handle for a running process. Yields output lines via `lines`, supports `stop`.
final class RunningProcess: @unchecked Sendable {
    let process: Process
    let lines: AsyncStream<String>

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    private let continuation: AsyncStream<String>.Continuation
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var didFinish = false
    private let finishLock = NSLock()

    fileprivate init(process: Process) {
        self.process = process
        process.standardOutput = stdout
        process.standardError = stderr

        var localCont: AsyncStream<String>.Continuation!
        self.lines = AsyncStream<String> { cont in localCont = cont }
        self.continuation = localCont
    }

    fileprivate func start() throws {
        let onChunk: (FileHandle) -> Void = { [weak self] handle in
            guard let self = self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.bufferLock.lock()
            self.buffer.append(chunk)
            while let nlPos = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[..<nlPos]
                self.buffer.removeSubrange(...nlPos)
                if let line = String(data: lineData, encoding: .utf8) {
                    self.continuation.yield(line)
                }
            }
            self.bufferLock.unlock()
        }
        stdout.fileHandleForReading.readabilityHandler = onChunk
        stderr.fileHandleForReading.readabilityHandler = onChunk

        process.terminationHandler = { [weak self] _ in self?.finish() }

        try process.run()
    }

    private func finish() {
        finishLock.lock()
        let already = didFinish
        didFinish = true
        finishLock.unlock()
        if already { return }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        bufferLock.lock()
        let leftover = buffer
        buffer.removeAll()
        bufferLock.unlock()
        if !leftover.isEmpty, let str = String(data: leftover, encoding: .utf8) {
            continuation.yield(str)
        }
        continuation.finish()
    }

    func stop() {
        if process.isRunning {
            kill(-process.processIdentifier, SIGTERM)
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.process.isRunning else { return }
            kill(self.process.processIdentifier, SIGKILL)
        }
    }
}
