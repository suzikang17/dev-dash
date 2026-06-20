import Foundation

/// Minimal but solid Markdown → HTML converter for the file viewer + docs tab.
/// Not a full CommonMark implementation, but handles the 95% common case:
/// headings, code (inline + fenced), bold/italic, lists, blockquotes, links,
/// horizontal rules, and paragraphs.
enum Markdown {
    static func toHTML(_ source: String) -> String {
        let inner = bodyHTML(source)
        let css = stylesheet()
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style>
        </head>
        <body>
        \(inner)
        </body>
        </html>
        """
    }

    static func bodyHTML(_ source: String) -> String {
        var out: [String] = []
        var i = 0
        let lines = source.components(separatedBy: "\n")

        var listKind: String? = nil      // "ul" | "ol"
        var listItems: [String] = []

        func flushList() {
            guard let kind = listKind, !listItems.isEmpty else { listItems = []; listKind = nil; return }
            out.append("<\(kind)>")
            for it in listItems { out.append("<li>\(processInline(it))</li>") }
            out.append("</\(kind)>")
            listItems = []
            listKind = nil
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushList()
                let lang = String(trimmed.dropFirst(3))
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    code.append(lines[i])
                    i += 1
                }
                let escaped = code.joined(separator: "\n").htmlEscaped
                let langAttr = lang.isEmpty ? "" : " class=\"language-\(escapeAttr(lang))\""
                out.append("<pre><code\(langAttr)>\(escaped)</code></pre>")
                continue
            }

            // Heading
            if let (level, rest) = headingPrefix(trimmed) {
                flushList()
                out.append("<h\(level)>\(processInline(rest))</h\(level)>")
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushList()
                out.append("<hr>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                flushList()
                let body = String(trimmed.dropFirst(2))
                out.append("<blockquote><p>\(processInline(body))</p></blockquote>")
                i += 1
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if listKind != "ul" { flushList(); listKind = "ul" }
                listItems.append(String(trimmed.dropFirst(2)))
                i += 1
                continue
            }

            // Ordered list
            if let firstDot = trimmed.firstIndex(of: "."),
               trimmed[trimmed.startIndex..<firstDot].allSatisfy({ $0.isNumber }),
               firstDot < trimmed.endIndex,
               trimmed.index(after: firstDot) < trimmed.endIndex,
               trimmed[trimmed.index(after: firstDot)] == " " {
                if listKind != "ol" { flushList(); listKind = "ol" }
                listItems.append(String(trimmed[trimmed.index(firstDot, offsetBy: 2)...]))
                i += 1
                continue
            }

            // Blank line — close list / paragraph break
            if trimmed.isEmpty {
                flushList()
                i += 1
                continue
            }

            // Paragraph: gather consecutive non-special lines
            flushList()
            var paragraph = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrim = next.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty { break }
                if nextTrim.hasPrefix("```") || headingPrefix(nextTrim) != nil
                    || nextTrim.hasPrefix("- ") || nextTrim.hasPrefix("* ") || nextTrim.hasPrefix("+ ")
                    || nextTrim.hasPrefix("> ")
                    || nextTrim == "---" || nextTrim == "***" || nextTrim == "___" {
                    break
                }
                paragraph.append(next)
                i += 1
            }
            let joined = paragraph.joined(separator: " ")
            out.append("<p>\(processInline(joined))</p>")
        }
        flushList()

        return out.joined(separator: "\n")
    }

    // MARK: - Inline

    private static func processInline(_ s: String) -> String {
        // Escape ALL literal text up front so raw HTML in the source (e.g.
        // `<script>` or `<img onerror=…>`) can't inject into the rendered page.
        // Markdown markers (* [ ] ( ) `) survive escaping, so the inline regexes
        // below still match; their captured groups are already escaped, so we must
        // NOT re-escape them.
        var t = s.htmlEscaped
        // Inline code (do first so its content isn't further parsed)
        t = replace(t, pattern: "`([^`]+)`") { groups in
            "<code>\(groups[1])</code>"
        }
        // Links [text](url) — escapeAttr handles quotes/<; also gate the scheme.
        t = replace(t, pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#) { groups in
            let href = Self.safeHref(escapeAttr(groups[2]))
            return href.isEmpty ? groups[1] : "<a href=\"\(href)\">\(groups[1])</a>"
        }
        // Bold **
        t = replace(t, pattern: #"\*\*([^*]+)\*\*"#) { groups in
            "<strong>\(groups[1])</strong>"
        }
        // Italic *
        t = replace(t, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#) { groups in
            "<em>\(groups[1])</em>"
        }
        return t
    }

    /// Reject script-y URL schemes in links (`javascript:`/`data:`/`vbscript:`).
    /// Input is already attribute-escaped; this only gates the scheme.
    private static func safeHref(_ escapedURL: String) -> String {
        let lowered = escapedURL.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") || lowered.hasPrefix("vbscript:") {
            return ""
        }
        return escapedURL
    }

    private static func headingPrefix(_ s: String) -> (Int, String)? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if s.hasPrefix(prefix) {
                return (level, String(s.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func replace(_ input: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsInput = input as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        for m in matches {
            let r = m.range
            if r.location > lastEnd {
                result += nsInput.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            }
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let gr = m.range(at: g)
                groups.append(gr.location != NSNotFound ? nsInput.substring(with: gr) : "")
            }
            result += transform(groups)
            lastEnd = r.location + r.length
        }
        if lastEnd < nsInput.length {
            result += nsInput.substring(with: NSRange(location: lastEnd, length: nsInput.length - lastEnd))
        }
        return result
    }

    private static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func stylesheet() -> String {
        """
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            margin: 0;
            padding: 28px 36px;
            max-width: 820px;
            color: -apple-system-text;
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin-top: 1.6em; margin-bottom: 0.5em; }
        h1 { font-size: 1.9em; border-bottom: 1px solid color-mix(in srgb, currentColor 18%, transparent); padding-bottom: 0.3em; }
        h2 { font-size: 1.45em; border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent); padding-bottom: 0.25em; }
        h3 { font-size: 1.15em; }
        p { margin: 0.5em 0 0.9em; }
        a { color: -apple-system-blue; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            background: color-mix(in srgb, currentColor 10%, transparent);
            padding: 0.15em 0.35em;
            border-radius: 4px;
        }
        pre {
            background: color-mix(in srgb, currentColor 8%, transparent);
            padding: 12px 14px;
            border-radius: 8px;
            overflow-x: auto;
            font-size: 12px;
            line-height: 1.5;
        }
        pre code { background: transparent; padding: 0; font-size: 12px; }
        blockquote {
            margin: 0.6em 0;
            padding: 0.4em 0.9em;
            border-left: 3px solid color-mix(in srgb, currentColor 30%, transparent);
            color: color-mix(in srgb, currentColor 75%, transparent);
        }
        ul, ol { padding-left: 1.5em; margin: 0.4em 0 0.9em; }
        li { margin: 0.15em 0; }
        hr { border: none; border-top: 1px solid color-mix(in srgb, currentColor 16%, transparent); margin: 1.6em 0; }
        """
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
