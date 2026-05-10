import AppKit
import Foundation

/// Regex-based syntax highlighter. Not perfect, but covers ~95% of typical code coloring needs.
enum SyntaxHighlighter {
    enum Language: String, Equatable {
        case swift, javascript, typescript, json, html, css, markdown, python, ruby, go, rust, bash, plain

        static func detect(from extension: String) -> Language {
            switch `extension`.lowercased() {
            case "swift": return .swift
            case "js", "mjs", "cjs", "jsx": return .javascript
            case "ts", "tsx": return .typescript
            case "json", "jsonc": return .json
            case "html", "htm", "svg", "xml": return .html
            case "css", "scss", "sass", "less": return .css
            case "md", "mdx", "markdown": return .markdown
            case "py": return .python
            case "rb": return .ruby
            case "go": return .go
            case "rs": return .rust
            case "sh", "zsh", "bash": return .bash
            default: return .plain
            }
        }
    }

    enum TokenKind {
        case keyword, string, number, comment, function, type

        var color: NSColor {
            switch self {
            case .keyword:  return NSColor(named: "Keyword")  ?? .systemPurple
            case .string:   return NSColor(named: "String")   ?? .systemRed
            case .number:   return NSColor(named: "Number")   ?? .systemOrange
            case .comment:  return NSColor.secondaryLabelColor
            case .function: return NSColor(named: "Function") ?? .systemTeal
            case .type:     return NSColor(named: "Type")     ?? .systemIndigo
            }
        }
    }

    struct Token {
        let kind: TokenKind
        let range: NSRange
    }

    static func tokenize(_ source: String, language: Language) -> [Token] {
        guard language != .plain else { return [] }
        let nsSource = source as NSString
        let full = NSRange(location: 0, length: nsSource.length)

        var tokens: [Token] = []

        // Order matters: comments and strings first so keywords inside don't double-match.
        // Use occupied-ranges set to skip overlap.
        var occupied: [NSRange] = []

        func add(_ kind: TokenKind, pattern: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: source, range: full) { match, _, _ in
                guard let r = match?.range else { return }
                if occupied.contains(where: { NSIntersectionRange($0, r).length > 0 }) { return }
                occupied.append(r)
                tokens.append(Token(kind: kind, range: r))
            }
        }

        // Comments first (have priority)
        for pattern in commentPatterns(language) {
            add(.comment, pattern: pattern, options: [.dotMatchesLineSeparators])
        }
        // Strings
        for pattern in stringPatterns(language) {
            add(.string, pattern: pattern, options: [.dotMatchesLineSeparators])
        }
        // Numbers
        add(.number, pattern: #"\b\d+(\.\d+)?([eE][-+]?\d+)?\b"#)
        // Keywords
        if let kw = keywords(language) {
            add(.keyword, pattern: "\\b(\(kw.joined(separator: "|")))\\b")
        }
        // Function calls (identifier immediately followed by `(`)
        add(.function, pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)(?=\()"#)
        // Type-like names (CapitalCase identifiers)
        add(.type, pattern: #"\b([A-Z][A-Za-z0-9_]*)\b"#)

        return tokens
    }

    private static func commentPatterns(_ lang: Language) -> [String] {
        switch lang {
        case .python, .ruby, .bash:
            return [#"#[^\n]*"#]
        case .html:
            return [#"<!--[\s\S]*?-->"#]
        case .css:
            return [#"/\*[\s\S]*?\*/"#]
        case .markdown:
            return []
        default:
            return [#"//[^\n]*"#, #"/\*[\s\S]*?\*/"#]
        }
    }

    private static func stringPatterns(_ lang: Language) -> [String] {
        // Order: triple/backticks first
        switch lang {
        case .python:
            return [#""""[\s\S]*?""""#, #"'''[\s\S]*?'''"#, #""(?:\\.|[^"\\\n])*""#, #"'(?:\\.|[^'\\\n])*'"#]
        case .javascript, .typescript:
            return [#"`(?:\\.|[^`\\])*`"#, #""(?:\\.|[^"\\\n])*""#, #"'(?:\\.|[^'\\\n])*'"#]
        case .markdown:
            return [#"`[^`]+`"#, #"```[\s\S]*?```"#]
        default:
            return [#""(?:\\.|[^"\\\n])*""#, #"'(?:\\.|[^'\\\n])*'"#]
        }
    }

    private static func keywords(_ lang: Language) -> [String]? {
        switch lang {
        case .swift:
            return ["func","var","let","class","struct","enum","extension","protocol","if","else","guard","switch","case","default","for","while","do","return","import","throw","throws","try","catch","async","await","actor","init","deinit","self","Self","public","private","internal","fileprivate","open","static","final","override","mutating","nonmutating","where","is","as","in","nil","true","false","break","continue","fallthrough","defer","typealias","associatedtype","inout"]
        case .javascript, .typescript:
            return ["function","const","let","var","class","extends","interface","type","enum","if","else","switch","case","default","for","while","do","return","import","export","from","as","new","this","super","async","await","try","catch","finally","throw","null","undefined","true","false","void","typeof","instanceof","in","of","break","continue","yield","static","public","private","protected","readonly","abstract","implements"]
        case .python:
            return ["def","class","if","elif","else","for","while","return","import","from","as","try","except","finally","raise","with","async","await","lambda","yield","pass","break","continue","global","nonlocal","in","is","and","or","not","None","True","False","self"]
        case .ruby:
            return ["def","class","module","if","elsif","else","unless","case","when","for","while","do","end","return","require","require_relative","yield","begin","rescue","ensure","raise","break","next","retry","redo","self","nil","true","false","and","or","not","in","then"]
        case .go:
            return ["func","var","const","type","struct","interface","if","else","for","range","switch","case","default","return","import","package","go","defer","chan","select","map","break","continue","fallthrough","nil","true","false"]
        case .rust:
            return ["fn","let","mut","const","static","struct","enum","trait","impl","if","else","match","for","while","loop","return","use","mod","pub","async","await","move","ref","self","Self","where","as","in","true","false","crate","extern","unsafe","break","continue"]
        case .bash:
            return ["if","then","else","elif","fi","for","while","do","done","case","esac","function","return","in","local","export","echo","read","exit","break","continue","true","false","source"]
        case .json:
            return ["true","false","null"]
        case .css:
            return ["important"]
        case .html, .markdown, .plain:
            return nil
        }
    }
}
