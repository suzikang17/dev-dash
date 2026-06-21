import Foundation

/// Headless living-doc regen for verification:
///   `DevDash --regen <projectPath>`
/// renders `docs/devdash/index.html` and exits WITHOUT launching the GUI — so
/// the lore/graph output can be checked deterministically (no window, no
/// dependency on which tab the app happens to restore to). The lore sections
/// read straight from `docs/`, so a minimal meta is sufficient; roadmap/snapshot
/// (which need real meta/template) are not the target of this path.
enum DocRegenCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // `--graph <projectPath>`: dump the lore knowledge graph (target ← sources)
        // so backlinks (incl. reference/parent links not shown in index.html) can
        // be verified deterministically.
        if let gi = args.firstIndex(of: "--graph"), gi + 1 < args.count {
            let path = args[gi + 1]
            let graph = LoreLinkIndex.build(projectPath: path, dirs: LoreLinkIndex.allDirs)
            var out = "graph: \(graph.backlinks.count) doc(s) with backlinks\n"
            for (target, bls) in graph.backlinks.sorted(by: { $0.key < $1.key }) {
                out += "\(target)  ← " + bls.map { "\($0.fromPath)" }.joined(separator: ", ") + "\n"
            }
            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }
        guard let idx = args.firstIndex(of: "--regen"), idx + 1 < args.count else { return }
        let path = args[idx + 1]
        let name = (path as NSString).lastPathComponent
        let result = ProductDocGenerator.generate(
            projectName: name, projectPath: path,
            meta: .empty, template: nil, tasks: TaskStore.read(path), status: nil)
        let msg = result == nil ? "regen FAILED\n" : "regen ok -> \(result!)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(result == nil ? 1 : 0)
    }
}
