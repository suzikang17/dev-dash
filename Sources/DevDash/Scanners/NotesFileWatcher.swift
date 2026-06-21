import Foundation

/// Watches docs/notes/ for external writes (Claude Code, editors) and fires a
/// debounced callback. The view layer refreshes NON-focused days only, so a
/// local in-progress edit is never clobbered.
final class NotesFileWatcher {
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let dir: String
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(dir: String, onChange: @escaping () -> Void) {
        self.dir = dir
        self.onChange = onChange
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        arm()
    }

    private func arm() {
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func fire() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
