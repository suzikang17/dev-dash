import Foundation

/// Wraps the `claude` CLI. Uses the user's existing CLI auth (subscription session
/// or env-vars). We never read or set API keys here.
enum ClaudeRunner {
    enum ResolveError: Error, LocalizedError {
        case notFound

        var errorDescription: String? {
            "Couldn't find `claude` CLI. Install it from https://docs.claude.com/en/docs/claude-code"
        }
    }

    /// Look up the `claude` binary in common install locations.
    static func resolveBinary() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/bin/claude"
        ]
        let fm = FileManager.default
        for path in candidates where fm.fileExists(atPath: path) { return path }
        return nil
    }

    /// Spawn a Claude task in `cwd`. Returns a `RunningProcess` that streams output lines.
    /// `allowEdits = false` restricts Claude to read-only tools; `true` enables write/edit
    /// via `--dangerously-skip-permissions`.
    static func run(prompt: String, cwd: String, allowEdits: Bool) throws -> RunningProcess {
        // Resolve via login shell so users using fnm/asdf get the right binary.
        let bin: String
        if let direct = resolveBinary() {
            bin = direct
        } else {
            // Fallback: shell out via zsh -ic to find it
            bin = "/bin/zsh"
        }

        var args: [String] = []
        var shellCmd: String? = nil

        if bin == "/bin/zsh" {
            // Compose a single shell line that locates and invokes claude
            let inner = "claude -p \(shellQuote(prompt)) --output-format stream-json"
                + (allowEdits ? " --dangerously-skip-permissions" : " --allowedTools \"Read,Glob,Grep,LS,Bash\"")
            shellCmd = "cd \(shellQuote(cwd)) && \(inner)"
            args = ["-ic", shellCmd!]
        } else {
            args = ["-p", prompt, "--output-format", "stream-json"]
            if allowEdits {
                args.append("--dangerously-skip-permissions")
            } else {
                args.append(contentsOf: ["--allowedTools", "Read,Glob,Grep,LS,Bash"])
            }
        }

        return try ShellRunner.start(bin, args: args, cwd: bin == "/bin/zsh" ? nil : cwd)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
