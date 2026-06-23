import Foundation

/// Watches one or more docs directories for external writes (Claude Code, editors,
/// `lore add`, etc.) and fires a single debounced callback. The view layer refreshes
/// NON-focused days only, so a local in-progress edit is never clobbered.
final class NotesFileWatcher {
    private var fds: [Int32] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private let dirs: [String]
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(dirs: [String], onChange: @escaping () -> Void) {
        self.dirs = dirs
        self.onChange = onChange
        arm()
    }

    /// Back-compat single-directory initializer (creates the dir if missing).
    convenience init(dir: String, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.init(dirs: [dir], onChange: onChange)
    }

    private func arm() {
        for dir in dirs {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }   // dir may not exist yet; skip it
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
            src.setEventHandler { [weak self] in self?.fire() }
            src.setCancelHandler { close(fd) }
            fds.append(fd)
            sources.append(src)
            src.resume()
        }
    }

    private func fire() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func stop() {
        for src in sources { src.cancel() }
        sources = []
        fds = []
    }

    deinit { stop() }
}
