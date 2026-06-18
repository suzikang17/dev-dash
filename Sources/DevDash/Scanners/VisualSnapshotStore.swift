import Foundation
import CoreGraphics
import ImageIO

enum VisualSnapshotStore {

    // MARK: - Paths

    static func root(for projectPath: String) -> String {
        "\(projectPath)/.devdash/visual-snapshots"
    }

    private static func slugViewportDir(for projectPath: String, urlSlug: String, viewport: String) -> String {
        "\(root(for: projectPath))/\(urlSlug)/\(viewport)"
    }

    static func baselinePath(for projectPath: String, urlSlug: String, viewport: String) -> String {
        "\(slugViewportDir(for: projectPath, urlSlug: urlSlug, viewport: viewport))/baseline.png"
    }

    private static func runsDir(for projectPath: String, urlSlug: String, viewport: String) -> String {
        "\(slugViewportDir(for: projectPath, urlSlug: urlSlug, viewport: viewport))/runs"
    }

    // MARK: - Slug

    static func slugify(_ url: URL) -> String {
        let host = url.host ?? "localhost"
        let path = url.path.isEmpty ? "root" : url.path
        let raw = "\(host)\(path)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(raw.prefix(120))
    }

    // MARK: - Baseline

    static func baseline(for projectPath: String, urlSlug: String, viewport: String) -> CGImage? {
        let path = baselinePath(for: projectPath, urlSlug: urlSlug, viewport: viewport)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func deleteBaseline(projectPath: String, urlSlug: String, viewport: String) {
        let path = baselinePath(for: projectPath, urlSlug: urlSlug, viewport: viewport)
        try? FileManager.default.removeItem(atPath: path)
    }

    static func saveBaseline(_ image: CGImage, projectPath: String, urlSlug: String, viewport: String) {
        let dir = slugViewportDir(for: projectPath, urlSlug: urlSlug, viewport: viewport)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writePNG(image, to: baselinePath(for: projectPath, urlSlug: urlSlug, viewport: viewport))
    }

    // MARK: - Runs

    /// Saves snapshot + diff images and meta.json for a run.
    /// Returns the run directory path (set on the VisualRun before calling).
    @discardableResult
    static func saveRun(
        newImage: CGImage,
        diffImage: CGImage,
        run: VisualRun,
        projectPath: String,
        urlSlug: String,
        viewport: String
    ) -> String {
        let dir = "\(runsDir(for: projectPath, urlSlug: urlSlug, viewport: viewport))/\(run.id)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writePNG(newImage, to: "\(dir)/snapshot.png")
        writePNG(diffImage, to: "\(dir)/diff.png")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(run) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/meta.json"))
        }
        return dir
    }

    static func pruneRuns(projectPath: String, urlSlug: String, viewport: String, keepCount: Int = 20) {
        let dir = runsDir(for: projectPath, urlSlug: urlSlug, viewport: viewport)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let sorted = entries.filter { !$0.hasPrefix(".") }.sorted()
        let toDelete = sorted.dropLast(keepCount)
        for name in toDelete {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(name)")
        }
    }

    // MARK: - HTML report

    /// Generates a static HTML report and returns the file URL.
    static func exportReport(
        projectPath: String,
        urlSlug: String,
        viewport: String,
        runId: String,
        pageURL: URL
    ) -> URL? {
        let runDir = "\(runsDir(for: projectPath, urlSlug: urlSlug, viewport: viewport))/\(runId)"
        let reportsDir = "\(root(for: projectPath))/reports"
        try? FileManager.default.createDirectory(atPath: reportsDir, withIntermediateDirectories: true)

        let baselineAbs = baselinePath(for: projectPath, urlSlug: urlSlug, viewport: viewport)
        let snapshotAbs = "\(runDir)/snapshot.png"
        let diffAbs     = "\(runDir)/diff.png"

        let html = reportHTML(
            pageURL: pageURL.absoluteString,
            runId: runId,
            baselineURL: URL(fileURLWithPath: baselineAbs).absoluteString,
            snapshotURL: URL(fileURLWithPath: snapshotAbs).absoluteString,
            diffURL:     URL(fileURLWithPath: diffAbs).absoluteString
        )

        let reportPath = "\(reportsDir)/\(runId).html"
        guard (try? html.write(toFile: reportPath, atomically: true, encoding: .utf8)) != nil else { return nil }
        return URL(fileURLWithPath: reportPath)
    }

    // MARK: - Helpers

    static func writePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func reportHTML(
        pageURL: String,
        runId: String,
        baselineURL: String,
        snapshotURL: String,
        diffURL: String
    ) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Visual Review</title>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:-apple-system,sans-serif;background:#111;color:#e0e0e0;padding:24px}
        h1{font-size:15px;font-weight:500;color:#aaa;margin-bottom:4px}
        p{font-size:12px;color:#666;margin-bottom:20px}
        .grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
        .cell{background:#1c1c1e;border-radius:10px;padding:12px}
        .cell h2{font-size:11px;font-weight:500;color:#666;margin-bottom:8px;text-transform:uppercase;letter-spacing:.05em}
        .cell a{display:block}
        .cell img{width:100%;border-radius:6px;display:block;border:1px solid #333}
        </style>
        </head>
        <body>
        <h1>Visual Review</h1>
        <p>\(pageURL) &mdash; Run \(runId)</p>
        <div class="grid">
          <div class="cell">
            <h2>Baseline</h2>
            <a href="\(baselineURL)" target="_blank"><img src="\(baselineURL)" loading="lazy"></a>
          </div>
          <div class="cell">
            <h2>New snapshot</h2>
            <a href="\(snapshotURL)" target="_blank"><img src="\(snapshotURL)" loading="lazy"></a>
          </div>
          <div class="cell">
            <h2>Diff (red = changed)</h2>
            <a href="\(diffURL)" target="_blank"><img src="\(diffURL)" loading="lazy"></a>
          </div>
        </div>
        </body>
        </html>
        """
    }
}
