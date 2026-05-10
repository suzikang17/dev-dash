import Foundation

enum FrameworkDetector {
    static let frameworkColors: [String: String] = [
        "Next.js": "#000000",
        "Vite": "#646cff",
        "Nuxt": "#00dc82",
        "CRA": "#61dafb",
        "Angular": "#dd0031",
        "SvelteKit": "#ff3e00",
        "Svelte": "#ff3e00",
        "Astro": "#ff5d01",
        "Remix": "#121212",
        "Express": "#404040",
        "Fastify": "#000000",
        "Hono": "#e36002",
        "Node.js": "#417e38",
        "Python": "#3776ab",
        "Django": "#0c4b33",
        "Flask": "#000000",
        "Ruby": "#cc342d",
        "Rails": "#cc0000",
        "Bun": "#fbf0df",
        "Go": "#00add8",
        "Rust": "#dea584",
        "Swift Package": "#f05138",
        "macOS App": "#f05138",
        "iOS App": "#0a84ff",
        "Xcode": "#147efb",
        "MongoDB": "#47a248",
        "PostgreSQL": "#336791",
        "Redis": "#dc382d",
        "Ollama": "#444444",
        "Unknown": "#666666"
    ]

    static func color(for framework: String) -> String {
        frameworkColors[framework] ?? "#666666"
    }

    /// Identify what framework is actually running. Process name is authoritative —
    /// a Python process in a Node project is Python, not Next.js.
    static func detect(cwd: String, processName: String) -> String {
        let cmd = processName.lowercased()

        // Process-name-first identification
        if cmd.contains("next-server") { return "Next.js" }

        if cmd.contains("python") {
            if !cwd.isEmpty {
                if FileManager.default.fileExists(atPath: "\(cwd)/manage.py") { return "Django" }
                if FileManager.default.fileExists(atPath: "\(cwd)/app.py") { return "Flask" }
            }
            return "Python"
        }

        if cmd.contains("ruby") {
            if !cwd.isEmpty && FileManager.default.fileExists(atPath: "\(cwd)/config/application.rb") {
                return "Rails"
            }
            return "Ruby"
        }

        if cmd == "bun" || cmd.hasPrefix("bun ") { return "Bun" }
        if cmd.contains("cargo") || cmd.contains("rustc") { return "Rust" }
        if cmd.contains("go") && !cmd.contains("node") { return "Go" }

        // For node processes, look at package.json deps to pick a JS framework
        if cmd.contains("node") || cmd == "deno" {
            if !cwd.isEmpty {
                let pkgPath = "\(cwd)/package.json"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var deps: [String: Any] = [:]
                    if let d = json["dependencies"] as? [String: Any] { deps.merge(d) { _, b in b } }
                    if let d = json["devDependencies"] as? [String: Any] { deps.merge(d) { _, b in b } }
                    return frameworkFrom(deps: deps)
                }
            }
            return "Node.js"
        }

        return "Unknown"
    }

    private static func frameworkFrom(deps: [String: Any]) -> String {
        if deps["next"] != nil { return "Next.js" }
        if deps["@sveltejs/kit"] != nil { return "SvelteKit" }
        if deps["svelte"] != nil { return "Svelte" }
        if deps["vite"] != nil { return "Vite" }
        if deps["nuxt"] != nil { return "Nuxt" }
        if deps["react-scripts"] != nil { return "CRA" }
        if deps["@angular/core"] != nil { return "Angular" }
        if deps["astro"] != nil { return "Astro" }
        if deps["@remix-run/node"] != nil || deps["remix"] != nil { return "Remix" }
        if deps["express"] != nil { return "Express" }
        if deps["fastify"] != nil { return "Fastify" }
        if deps["hono"] != nil { return "Hono" }
        return "Node.js"
    }

    static func detectFromFiles(at path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/package.json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: "\(path)/package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var deps: [String: Any] = [:]
            if let d = json["dependencies"] as? [String: Any] { deps.merge(d) { _, b in b } }
            if let d = json["devDependencies"] as? [String: Any] { deps.merge(d) { _, b in b } }
            return frameworkFrom(deps: deps)
        }
        if fm.fileExists(atPath: "\(path)/manage.py") { return "Django" }
        if fm.fileExists(atPath: "\(path)/app.py") { return "Flask" }
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "Rust" }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "Go" }
        if fm.fileExists(atPath: "\(path)/Gemfile") {
            return fm.fileExists(atPath: "\(path)/config/application.rb") ? "Rails" : "Ruby"
        }
        if fm.fileExists(atPath: "\(path)/pyproject.toml") || fm.fileExists(atPath: "\(path)/requirements.txt") {
            return "Python"
        }
        // Swift / Apple platforms
        if let swiftFramework = detectSwiftFramework(at: path) { return swiftFramework }
        return "Unknown"
    }

    static func detectStack(at path: String) -> String? {
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("package.json", "node"),
            ("go.mod", "go"),
            ("pyproject.toml", "python"),
            ("requirements.txt", "python"),
            ("Cargo.toml", "rust"),
            ("Gemfile", "ruby"),
            ("Package.swift", "swift")
        ]
        for (file, stack) in checks where fm.fileExists(atPath: "\(path)/\(file)") {
            return stack
        }
        // Xcode projects/workspaces are directories with extensions; scan for them.
        if let entries = try? fm.contentsOfDirectory(atPath: path) {
            if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return "swift"
            }
        }
        return nil
    }

    /// Inspect Package.swift / xcodeproj sibling to choose between
    /// "Swift Package", "macOS App", "iOS App", or "Xcode" (mixed/unknown).
    private static func detectSwiftFramework(at path: String) -> String? {
        let fm = FileManager.default
        let pkgSwift = "\(path)/Package.swift"
        let hasPkg = fm.fileExists(atPath: pkgSwift)
        let hasXcode: Bool
        if let entries = try? fm.contentsOfDirectory(atPath: path) {
            hasXcode = entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        } else {
            hasXcode = false
        }
        guard hasPkg || hasXcode else { return nil }

        if hasPkg, let raw = try? String(contentsOfFile: pkgSwift, encoding: .utf8) {
            // Crude but adequate platform sniff. .iOS / .macOS / .tvOS / etc.
            let hasIOS = raw.contains(".iOS(") || raw.contains(".iOS,")
            let hasMac = raw.contains(".macOS(") || raw.contains(".macOS,")
            if hasIOS && !hasMac { return "iOS App" }
            if hasMac && !hasIOS { return "macOS App" }
            // Has .executable product → likely an app, otherwise a library.
            if raw.contains(".executable(") { return "macOS App" }
            return "Swift Package"
        }
        return "Xcode"
    }
}
