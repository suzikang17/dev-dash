import Foundation

enum FileTreeScanner {
    static let excluded: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".svelte-kit", ".turbo",
        ".build", "dist", "build", ".cache", ".vercel", ".vite",
        "DerivedData", ".DS_Store", "target", "vendor", ".pytest_cache",
        "__pycache__", ".venv", "venv", "env", ".env", "Pods",
        ".idea", ".vscode"
    ]

    static func node(at path: String, lazy: Bool = true) -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        let name = URL(fileURLWithPath: path).lastPathComponent

        if !exists {
            return FileNode(path: path, name: name, isDirectory: false, children: nil)
        }
        if !isDir.boolValue {
            return FileNode(path: path, name: name, isDirectory: false, children: nil)
        }
        if lazy {
            // Mark as directory but don't enumerate yet
            return FileNode(path: path, name: name, isDirectory: true, children: childrenOf(path))
        }
        return FileNode(path: path, name: name, isDirectory: true, children: childrenOf(path))
    }

    static func childrenOf(_ dir: String) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var dirs: [FileNode] = []
        var files: [FileNode] = []

        for name in items {
            if excluded.contains(name) { continue }
            // Skip dotfiles by default for cleaner UI (but keep things like .env.example obvious enough)
            if name.hasPrefix(".") && name != ".devdash" { continue }
            let full = "\(dir)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // For dirs, give them a non-nil empty children array as a placeholder; expand-time they'll get filled
                dirs.append(FileNode(path: full, name: name, isDirectory: true, children: []))
            } else {
                files.append(FileNode(path: full, name: name, isDirectory: false, children: nil))
            }
        }

        let bySortName: (FileNode, FileNode) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs.sorted(by: bySortName) + files.sorted(by: bySortName)
    }

    /// Eagerly walk a tree but skip excluded dirs. Caps total nodes to keep UI responsive.
    static func loadTree(root: String, maxNodes: Int = 5000) -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return FileNode(path: root, name: URL(fileURLWithPath: root).lastPathComponent, isDirectory: false, children: nil)
        }
        var counter = 0
        let kids = recursiveChildren(of: root, counter: &counter, max: maxNodes)
        return FileNode(path: root, name: URL(fileURLWithPath: root).lastPathComponent, isDirectory: true, children: kids)
    }

    private static func recursiveChildren(of dir: String, counter: inout Int, max: Int) -> [FileNode] {
        if counter >= max { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var dirs: [FileNode] = []
        var files: [FileNode] = []

        for name in items {
            if counter >= max { break }
            if excluded.contains(name) { continue }
            if name.hasPrefix(".") && name != ".devdash" { continue }
            let full = "\(dir)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            counter += 1
            if isDir.boolValue {
                let kids = recursiveChildren(of: full, counter: &counter, max: max)
                dirs.append(FileNode(path: full, name: name, isDirectory: true, children: kids))
            } else {
                files.append(FileNode(path: full, name: name, isDirectory: false, children: nil))
            }
        }

        let bySortName: (FileNode, FileNode) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs.sorted(by: bySortName) + files.sorted(by: bySortName)
    }

    // MARK: - File reading

    enum FileContent {
        case text(String)
        case binary(size: Int)
        case tooLarge(size: Int)
        case unreadable(String)
    }

    static let maxTextBytes = 1_000_000  // 1MB

    static func readFile(at path: String) -> FileContent {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .unreadable("File not found") }

        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxTextBytes {
            return .tooLarge(size: size)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .unreadable("Could not read file")
        }

        // Heuristic: if there are NUL bytes in the first 4KB, treat as binary
        let probeSize = min(data.count, 4096)
        if data.prefix(probeSize).contains(0) {
            return .binary(size: size)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .binary(size: size)
        }
        return .text(text)
    }

    /// SF Symbol name based on file extension.
    static func icon(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "curlybraces"
        case "json", "yaml", "yml", "toml": return "doc.text.below.ecg"
        case "md", "mdx", "markdown": return "doc.richtext"
        case "css", "scss", "sass", "less": return "paintpalette"
        case "html", "htm", "xml", "svg": return "chevron.left.forwardslash.chevron.right"
        case "py": return "p.circle"
        case "rb": return "diamond"
        case "go": return "g.circle"
        case "rs": return "r.circle"
        case "png", "jpg", "jpeg", "gif", "webp", "ico": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "tgz": return "shippingbox"
        case "lock", "lockb": return "lock"
        case "sh", "zsh", "bash": return "terminal"
        case "log": return "scroll"
        case "env": return "key"
        default: return "doc"
        }
    }
}
