import Foundation

/// Manages the `.assets/` folder under each project's living-doc tree.
/// Copies bundled JS (Alpine + devdash-components) to disk so the WKWebView
/// can load them via file://. Also exposes the addBtn helper used by every
/// template to render an Alpine + Add button.
enum ProductDocAssets {
    static let assetsRel = ".assets"

    /// Names of resource files (Sources/DevDash/Resources/) that get copied
    /// into each project's .assets/ folder.
    private static let assetFiles = ["alpine.min.js", "devdash-components.js"]

    /// Copy bundled JS into <project>/docs/devdash/.assets/. Idempotent —
    /// overwrites if contents differ; skips if identical. Called every regen.
    static func writeAssets(to docsRoot: String) {
        let assetsDir = "\(docsRoot)/\(assetsRel)"
        try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)
        for name in assetFiles {
            guard let src = Bundle.module.url(forResource: name, withExtension: nil) else {
                NSLog("[devdash] missing bundled resource: \(name)")
                continue
            }
            let dst = "\(assetsDir)/\(name)"
            // Overwrite-if-different to keep file mtime stable when nothing changed.
            if let srcData = try? Data(contentsOf: src),
               let dstData = try? Data(contentsOf: URL(fileURLWithPath: dst)),
               srcData == dstData {
                continue
            }
            try? FileManager.default.removeItem(atPath: dst)
            try? FileManager.default.copyItem(atPath: src.path, toPath: dst)
        }
    }

    /// Render an Alpine + Add button. The button is placed *immediately after*
    /// the container element it appends into, so the click handler reaches
    /// the target via $el.previousElementSibling. Pattern:
    ///
    ///   <ul class="checklist">…</ul>
    ///   <button class="add-btn" @click="...">+ Add item</button>
    ///
    /// `html` is single-quote-escaped + newline-stripped so it can be embedded
    /// inline in the Alpine expression attribute value.
    static func addBtn(label: String, html: String) -> String {
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        <button class="add-btn" contenteditable="false" @click="$el.previousElementSibling.insertAdjacentHTML('beforeend', '\(escaped)'); window.devdashMarkDirty($el)">\(label)</button>
        """
    }
}
