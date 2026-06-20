import SwiftUI
import WebKit

/// Renders a markdown string in a WKWebView with dark-mode styling.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.setValue(false, forKey: "drawsBackground")
        load(into: wv, coordinator: context.coordinator)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView, coordinator: context.coordinator)
    }

    private func load(into wv: WKWebView, coordinator: Coordinator) {
        let html = markdownToHTML(markdown)
        guard html != coordinator.lastHTML else { return }
        coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator { var lastHTML = "" }
}

// MARK: - Markdown → HTML

private func markdownToHTML(_ md: String) -> String {
    let body = convertBody(md)
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    *{box-sizing:border-box}
    :root{color-scheme:light dark}
    body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;font-size:13px;line-height:1.65;color:-apple-system-text;background:transparent;margin:0;padding:12px 16px}
    h1,h2,h3,h4{line-height:1.3}
    h1{font-size:1.45em;font-weight:700;margin:0.9em 0 0.35em;border-bottom:1px solid color-mix(in srgb,currentColor 14%,transparent);padding-bottom:.2em}
    h2{font-size:1.2em;font-weight:600;margin:0.85em 0 0.3em}
    h3{font-size:1.05em;font-weight:600;margin:0.75em 0 0.25em}
    h4{font-size:.95em;font-weight:600;margin:0.65em 0 0.2em}
    p{margin:.45em 0}
    ul,ol{margin:.35em 0;padding-left:1.5em}
    li{margin:.15em 0}
    li>p{margin:.1em 0}
    blockquote{margin:.5em 0;padding:.3em .8em;color:color-mix(in srgb,currentColor 70%,transparent);background:color-mix(in srgb,currentColor 6%,transparent);border-radius:6px}
    code{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:.88em;background:color-mix(in srgb,currentColor 10%,transparent);padding:1px 5px;border-radius:3px}
    pre{background:color-mix(in srgb,currentColor 8%,transparent);border-radius:6px;padding:10px 14px;overflow-x:auto;margin:.6em 0}
    pre code{background:none;padding:0;font-size:.9em}
    hr{border:none;border-top:1px solid color-mix(in srgb,currentColor 14%,transparent);margin:.8em 0}
    a{color:-apple-system-blue;text-decoration:none}
    a:hover{text-decoration:underline}
    strong{font-weight:600}
    table{border-collapse:collapse;width:100%;margin:.5em 0;font-size:.9em}
    th,td{text-align:left;padding:5px 10px;border-bottom:1px solid color-mix(in srgb,currentColor 12%,transparent)}
    th{font-weight:600;background:color-mix(in srgb,currentColor 5%,transparent)}
    </style></head><body>\(body)</body></html>
    """
}

private func convertBody(_ md: String) -> String {
    var out = ""
    let lines = md.components(separatedBy: "\n")
    var i = 0
    var listStack: [(ordered: Bool, indent: Int)] = []  // (type, indent level)

    func closeLists(toIndent target: Int = -1) {
        while let top = listStack.last, top.indent > target {
            out += top.ordered ? "</ol>" : "</ul>"
            listStack.removeLast()
        }
    }

    while i < lines.count {
        let raw = lines[i]

        // --- Fenced code block ---
        if raw.hasPrefix("```") || raw.hasPrefix("~~~") {
            closeLists()
            let fence = String(raw.prefix(3))
            let lang = raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix(fence) {
                codeLines.append(lines[i])
                i += 1
            }
            let escaped = codeLines.joined(separator: "\n").escaped
            let cls = lang.isEmpty ? "" : " class=\"language-\(lang)\""
            out += "<pre><code\(cls)>\(escaped)</code></pre>"
            i += 1
            continue
        }

        // --- Blank line ---
        if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            closeLists()
            out += "\n"
            i += 1
            continue
        }

        // --- Headers ---
        if raw.hasPrefix("#### ") { closeLists(); out += "<h4>\(inline(raw.dropFirst(5)))</h4>"; i += 1; continue }
        if raw.hasPrefix("### ")  { closeLists(); out += "<h3>\(inline(raw.dropFirst(4)))</h3>"; i += 1; continue }
        if raw.hasPrefix("## ")   { closeLists(); out += "<h2>\(inline(raw.dropFirst(3)))</h2>"; i += 1; continue }
        if raw.hasPrefix("# ")    { closeLists(); out += "<h1>\(inline(raw.dropFirst(2)))</h1>"; i += 1; continue }

        // --- Blockquote ---
        if raw.hasPrefix("> ") {
            closeLists()
            var bqLines: [String] = []
            while i < lines.count && lines[i].hasPrefix("> ") {
                bqLines.append(String(lines[i].dropFirst(2)))
                i += 1
            }
            out += "<blockquote>\(convertBody(bqLines.joined(separator: "\n")))</blockquote>"
            continue
        }

        // --- Horizontal rule ---
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            closeLists(); out += "<hr>"; i += 1; continue
        }

        // --- List items ---
        let indent = raw.prefix(while: { $0 == " " }).count
        let stripped = raw.trimmingCharacters(in: .whitespaces)

        var listMatch: (ordered: Bool, content: String)?
        if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
            listMatch = (false, String(stripped.dropFirst(2)))
        } else if let m = orderedListPrefix(stripped) {
            listMatch = (true, m)
        }

        if let (ordered, content) = listMatch {
            if let top = listStack.last {
                if indent > top.indent {
                    out += ordered ? "<ol>" : "<ul>"
                    listStack.append((ordered, indent))
                } else if indent < top.indent {
                    closeLists(toIndent: indent)
                } else if ordered != top.ordered {
                    closeLists(toIndent: indent - 1)
                    out += ordered ? "<ol>" : "<ul>"
                    listStack.append((ordered, indent))
                }
            } else {
                out += ordered ? "<ol>" : "<ul>"
                listStack.append((ordered, indent))
            }
            // Collect wrapped continuation lines for this item
            var parts = [content]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextT = next.trimmingCharacters(in: .whitespaces)
                if nextT.isEmpty { break }
                if nextT.hasPrefix("#") || nextT.hasPrefix(">") { break }
                if next.hasPrefix("```") || next.hasPrefix("~~~") { break }
                if nextT == "---" || nextT == "***" || nextT == "___" { break }
                if nextT.hasPrefix("- ") || nextT.hasPrefix("* ") || nextT.hasPrefix("+ ") { break }
                if orderedListPrefix(nextT) != nil { break }
                parts.append(nextT)
                i += 1
            }
            out += "<li>\(parts.map { inline($0) }.joined(separator: " "))</li>"
            continue
        }

        // --- Paragraph ---
        closeLists()
        var paraLines: [String] = []
        while i < lines.count {
            let l = lines[i]
            let lt = l.trimmingCharacters(in: .whitespaces)
            if lt.isEmpty || lt.hasPrefix("#") || lt.hasPrefix(">")
                || lt == "---" || lt == "***" || lt == "___"
                || lt.hasPrefix("- ") || lt.hasPrefix("* ") || lt.hasPrefix("+ ")
                || orderedListPrefix(lt) != nil
                || l.hasPrefix("```") || l.hasPrefix("~~~") { break }
            paraLines.append(l)
            i += 1
        }
        out += "<p>\(paraLines.map { inline(Substring($0)) }.joined(separator: "<br>"))</p>"
    }

    closeLists()
    return out
}

/// Reject script-y URL schemes in links and escape any remaining quote. The input
/// has already had `& < >` escaped by `inline`, so this only gates scheme + quote.
private func mdSafeHref(_ escapedURL: String) -> String {
    let lowered = escapedURL.trimmingCharacters(in: .whitespaces).lowercased()
    if lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") || lowered.hasPrefix("vbscript:") {
        return ""
    }
    return escapedURL.replacingOccurrences(of: "\"", with: "&quot;")
}

private func orderedListPrefix(_ s: String) -> String? {
    guard let dot = s.firstIndex(of: ".") else { return nil }
    let num = String(s[s.startIndex..<dot])
    guard num.allSatisfy(\.isNumber), !num.isEmpty else { return nil }
    let after = s.index(after: dot)
    guard after < s.endIndex, s[after] == " " else { return nil }
    return String(s[s.index(after: after)...])
}

private func inline(_ s: Substring) -> String { inline(String(s)) }

private func inline(_ s: String) -> String {
    var r = s.escaped
    // code spans first (protect from further processing)
    var spans: [String] = []
    r = r.replacingMatches(of: #"`(.+?)`"#) { m in
        let idx = spans.count
        spans.append("<code>\(m.groups[0])</code>")
        return "§SPAN\(idx)§"
    }
    // bold+italic
    r = r.replacingMatches(of: #"\*\*\*(.+?)\*\*\*"#) { "<strong><em>\($0.groups[0])</em></strong>" }
    r = r.replacingMatches(of: #"\*\*(.+?)\*\*"#)     { "<strong>\($0.groups[0])</strong>" }
    r = r.replacingMatches(of: #"__(.+?)__"#)          { "<strong>\($0.groups[0])</strong>" }
    r = r.replacingMatches(of: #"\*(.+?)\*"#)          { "<em>\($0.groups[0])</em>" }
    r = r.replacingMatches(of: #"_(.+?)_"#)            { "<em>\($0.groups[0])</em>" }
    // strikethrough
    r = r.replacingMatches(of: #"~~(.+?)~~"#) { "<del>\($0.groups[0])</del>" }
    // links — href is already &<>-escaped; gate the scheme + escape quotes.
    r = r.replacingMatches(of: #"\[([^\]]+)\]\(([^)]+)\)"#) { m in
        let href = mdSafeHref(m.groups[1])
        return href.isEmpty ? m.groups[0] : "<a href=\"\(href)\">\(m.groups[0])</a>"
    }
    // restore code spans
    for (idx, span) in spans.enumerated() {
        r = r.replacingOccurrences(of: "§SPAN\(idx)§", with: span)
    }
    return r
}

// MARK: - Regex helpers

private struct MatchResult {
    let full: String
    let groups: [String]
}

private extension String {
    var escaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func replacingMatches(of pattern: String, _ transform: (MatchResult) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let matches = regex.matches(in: self, range: NSRange(startIndex..., in: self))
        guard !matches.isEmpty else { return self }
        var result = ""
        var lastEnd = startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: self) else { continue }
            result += self[lastEnd..<fullRange.lowerBound]
            var groups: [String] = []
            for g in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: g), in: self) { groups.append(String(self[r])) }
                else { groups.append("") }
            }
            result += transform(MatchResult(full: String(self[fullRange]), groups: groups))
            lastEnd = fullRange.upperBound
        }
        result += self[lastEnd...]
        return result
    }
}
