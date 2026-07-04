import Foundation

/// Watches one or more docs directories for external writes (Claude Code, editors,
/// `lore add`, etc.) and fires a single debounced callback. The view layer refreshes
/// NON-focused days only, so a local in-progress edit is never clobbered.
final class NotesFileWatcher {
    private var fds: [Int32] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private let dirs: [String]
    private let onChangedDirs: ([String]) -> Void
    private var debounce: DispatchWorkItem?          // main-queue only
    private let lock = NSLock()
    private var pendingDirs: Set<String> = []        // guarded by `lock`

    /// Primary initializer: the callback receives the set of watched dirs that
    /// changed since the last (debounced) flush, so consumers can reload only
    /// the affected projects instead of everything. Fired on the main queue.
    init(dirs: [String], onChangedDirs: @escaping ([String]) -> Void) {
        self.dirs = dirs
        self.onChangedDirs = onChangedDirs
        arm()
    }

    /// Back-compat: dir-agnostic callback.
    convenience init(dirs: [String], onChange: @escaping () -> Void) {
        self.init(dirs: dirs, onChangedDirs: { _ in onChange() })
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
            src.setEventHandler { [weak self] in self?.fire(dir) }
            src.setCancelHandler { close(fd) }
            fds.append(fd)
            sources.append(src)
            src.resume()
        }
    }

    private func fire(_ dir: String) {
        lock.lock(); pendingDirs.insert(dir); lock.unlock()
        // Hop to main before touching `debounce` — event handlers run on the
        // global queue and used to race the debounce work item.
        DispatchQueue.main.async { [weak self] in self?.scheduleFlush() }
    }

    private func scheduleFlush() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func flush() {
        lock.lock(); let changed = Array(pendingDirs); pendingDirs.removeAll(); lock.unlock()
        guard !changed.isEmpty else { return }
        onChangedDirs(changed)
    }

    func stop() {
        for src in sources { src.cancel() }
        sources = []
        fds = []
    }

    deinit { stop() }
}
