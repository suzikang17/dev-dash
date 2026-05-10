import Foundation

enum ProjectScanner {
    static func scanAll() async -> [Project] {
        await withTaskGroup(of: [Project].self) { group in
            for root in DevRoots.roots {
                group.addTask { await scanRoot(root) }
            }
            var all: [Project] = []
            for await projects in group { all.append(contentsOf: projects) }
            return all.sorted {
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
        let candidates: [(path: String, stack: String, framework: String)] = entries
            .filter { !$0.hasPrefix(".") }
            .compactMap { entry in
                let full = root + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }
                guard let stack = FrameworkDetector.detectStack(at: full) else { return nil }
                let framework = FrameworkDetector.detectFromFiles(at: full)
                return (full, stack, framework)
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
