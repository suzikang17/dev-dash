import Foundation

/// Headless developer/CI entry points (run before the GUI, exit immediately):
///
///   DevDash --graph <projectPath>   READ-ONLY. Dumps the lore backlink graph
///                                   (target ← sources, with via). Safe to run
///                                   anytime — builds the graph in memory only.
///
///   DevDash --regen <projectPath>   MUTATES docs/. Runs the full living-doc
///                                   generator: scaffolds missing folders/stubs
///                                   and rewrites generated HTML. NOT side-effect
///                                   free — it dirties the working tree (and uses
///                                   an empty meta, so roadmap/snapshot render
///                                   blank). Use it to regenerate, not to verify.
enum DocRegenCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments

        if args.contains("--graph") {
            guard let path = pathArg(args, after: "--graph") else { fail("--graph requires a <projectPath>") }
            requireDocs(at: path)
            let graph = LoreLinkIndex.build(projectPath: path, dirs: LoreLinkIndex.allDirs)
            var out = "graph: \(graph.backlinks.count) doc(s) with backlinks\n"
            for (target, bls) in graph.backlinks.sorted(by: { $0.key < $1.key }) {
                let srcs = bls.map { "\($0.fromPath)(\($0.via))" }.joined(separator: ", ")
                out += "\(target)  ← \(srcs)\n"
            }
            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }

        if args.contains("--regen") {
            guard let path = pathArg(args, after: "--regen") else { fail("--regen requires a <projectPath>") }
            requireDocs(at: path)
            let name = (path as NSString).lastPathComponent
            let result = ProductDocGenerator.generate(
                projectName: name, projectPath: path,
                meta: .empty, template: nil, tasks: TaskStore.read(path), status: nil)
            FileHandle.standardError.write(Data((result == nil ? "regen FAILED\n" : "regen ok -> \(result!)\n").utf8))
            exit(result == nil ? 1 : 0)
        }
    }

    /// The argument following `flag`, or nil if absent/flag is last.
    private static func pathArg(_ args: [String], after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let p = args[i + 1]
        return p.hasPrefix("-") ? nil : p
    }

    /// Guard against a missing/relative path silently producing an empty graph.
    private static func requireDocs(at path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: "\(path)/docs", isDirectory: &isDir), isDir.boolValue else {
            fail("no docs/ at '\(path)' (pass an absolute project path)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("DocRegenCLI: \(message)\n".utf8))
        exit(2)
    }
}
