import Foundation

/// Tails a growing log file. Yields existing content first, then yields new bytes
/// as they're appended (using DispatchSource for low-overhead inotify-style events).
final class LogFileTailer: @unchecked Sendable {
    let path: String
    let lines: AsyncStream<String>

    private let continuation: AsyncStream<String>.Continuation
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    private let bufferLock = NSLock()
    private let queue: DispatchQueue

    init(path: String, fromBeginning: Bool = true) {
        self.path = path
        self.queue = DispatchQueue(label: "devdash.log-tail.\(URL(fileURLWithPath: path).lastPathComponent)")

        var localCont: AsyncStream<String>.Continuation!
        self.lines = AsyncStream<String> { cont in localCont = cont }
        self.continuation = localCont

        start(fromBeginning: fromBeginning)
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd != -1 { close(fd); fd = -1 }
        continuation.finish()
    }

    private func start(fromBeginning: Bool) {
        // Make sure the file exists so open(2) works
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd == -1 {
            continuation.finish()
            return
        }

        if !fromBeginning {
            offset = UInt64(lseek(fd, 0, SEEK_END))
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self = self, let s = self.source else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) {
                self.stop()
                return
            }
            self.drain()
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd != -1 { close(self.fd); self.fd = -1 }
        }
        self.source = src
        src.resume()

        // Initial read of existing content
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        guard fd != -1 else { return }
        let bufSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = read(fd, &buffer, bufSize)
            if n <= 0 { break }
            offset += UInt64(n)
            let chunk = Data(buffer.prefix(n))

            bufferLock.lock()
            partial.append(chunk)
            while let nlPos = partial.firstIndex(of: 0x0A) {
                let lineData = partial[..<nlPos]
                partial.removeSubrange(...nlPos)
                if let line = String(data: lineData, encoding: .utf8) {
                    continuation.yield(line)
                }
            }
            bufferLock.unlock()
        }
    }
}
