import Foundation

enum ProjectScanner {
    static func scanAll() async -> [Project] {
        await withTaskGroup(of: [Project].self) { group in
            for root in DevRoots.roots {
                group.addTask { await scanRoot(root) }
            }
            var all: [Project] = []
            for await projects in group { all.append(contentsOf: projects) }
            // Dedup by path: a folder can be both a configured project and a
            // child of another configured folder.
            var seen = Set<String>()
            return all
                .filter { seen.insert($0.path).inserted }
                .sorted {
                    let a = $0.lastCommitAt ?? .distantPast
                    let b = $1.lastCommitAt ?? .distantPast
                    return a > b
                }
        }
    }

    private static let maxConcurrent = 8

    private static func scanRoot(_ root: String) async -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        // Filter to directories with a detectable stack first (cheap, sync).
        var candidates: [(path: String, stack: String, framework: String)] = entries
            .filter { !$0.hasPrefix(".") }
            .compactMap { entry in
                let full = root + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }
                guard let stack = FrameworkDetector.detectStack(at: full) else { return nil }
                let framework = FrameworkDetector.detectFromFiles(at: full)
                return (full, stack, framework)
            }

        // Also treat the configured folder ITSELF as a project when it has a
        // detectable stack — so a single repo (e.g. dev-dash with a top-level
        // Package.swift) added directly shows up, not just folders-of-repos.
        // Use the path without the trailing slash so it matches session cwds.
        let rootPath = root.hasSuffix("/") ? String(root.dropLast()) : root
        if let stack = FrameworkDetector.detectStack(at: rootPath) {
            candidates.append((rootPath, stack, FrameworkDetector.detectFromFiles(at: rootPath)))
        }

        // Now run git scans in bounded batches.
        var projects: [Project] = []
        for batch in candidates.chunked(into: maxConcurrent) {
            let batchResults = await withTaskGroup(of: Project.self) { group in
                for c in batch {
                    group.addTask {
                        let git = await GitScanner.info(for: c.path)
                        let health = HealthCalculator.compute(lastCommit: git.lastCommit, isGit: git.isGit)
                        return Project(
                            id: c.path,
                            name: URL(fileURLWithPath: c.path).lastPathComponent,
                            path: c.path,
                            stack: c.stack,
                            framework: c.framework,
                            health: health,
                            lastCommitAt: git.lastCommit,
                            branch: git.branch,
                            githubURL: git.githubURL,
                            isGit: git.isGit
                        )
                    }
                }
                var local: [Project] = []
                for await p in group { local.append(p) }
                return local
            }
            projects.append(contentsOf: batchResults)
        }
        return projects
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
