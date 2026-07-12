import Foundation

/// Headless deterministic checks for the Markdown → HTML converter.
///   DevDash --selftest-markdown
/// Pure string-in/string-out, prints PASS/FAIL per check, exits.
enum MarkdownSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-markdown") else { return }
        run()
    }

    private static func run() -> Never {
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        func body(_ md: String) -> String { Markdown.bodyHTML(md) }

        // Inline formatting within a single line
        check(body("a **b** c").contains("a <strong>b</strong> c"), "bold mid-sentence")
        check(body("a *b* c").contains("a <em>b</em> c"), "italic mid-sentence")
        check(body("a `b` c").contains("a <code>b</code> c"), "inline code")
        check(body("[t](https://x.y)").contains("<a href=\"https://x.y\">t</a>"), "link")
        check(!body("[t](javascript:alert(1))").contains("<a "), "javascript: href rejected")
        check(body("<script>x</script>").contains("&lt;script&gt;"), "html escaped")

        // Paragraph line breaks preserved
        check(body("line one\nline two").contains("line one<br>line two"), "single newline -> <br>")

        // Bold spanning a hard-wrapped line inside a paragraph (wiki README case)
        let crossLine = body("said the same thing: **create more than you\nconsume.** The record shows")
        check(crossLine.contains("<strong>create more than you<br>consume.</strong>"),
              "bold across wrapped line")

        // Cross-line span must not leak formatting across a paragraph break
        let acrossPara = body("open **bold\n\nnever closed")
        check(!acrossPara.contains("<strong>"), "bold not matched across blank line")

        // Block elements still intact
        check(body("# Title").contains("<h1>Title</h1>"), "heading")
        check(body("- item **b**").contains("<li>item <strong>b</strong></li>"), "list item inline")
        check(body("```\ncode **x**\n```").contains("code **x**"), "fenced code left literal")

        let msg = failures.isEmpty
            ? "markdown-selftest: ALL PASS"
            : "markdown-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }
}
