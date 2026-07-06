import Foundation

/// Installs/uninstalls dev-dash hook entries in a Claude Code project's
/// `.claude/settings.json`, and writes the helper bridge script to `~/.devdash/bin/`.
enum HookInstaller {

    enum InstallError: Error, LocalizedError {
        case settingsCorrupted(String)

        var errorDescription: String? {
            switch self {
            case .settingsCorrupted(let path):
                return "settings.json at \(path) exists but could not be parsed — aborting to avoid data loss. Fix or remove the file and retry."
            }
        }
    }

    struct HookEventSpec: Identifiable {
        let event: String       // hook_event_name registered in settings.json
        let firesWhen: String   // when Claude fires it
        let reaction: String    // what dev-dash does in response
        let gatedBy: String?    // name of the setting that gates the behavior, or nil if always-on
        var id: String { event }
    }

    static let hookSpecs: [HookEventSpec] = [
        .init(event: "SessionStart",
              firesWhen: "A Claude session begins (start, resume, clear, or compact).",
              reaction: "Shows the start banner, opens a live session card, and injects your open tasks + latest devlog into the session.",
              gatedBy: "Inject project context into sessions"),
        .init(event: "UserPromptSubmit",
              firesWhen: "You submit a prompt, before Claude processes it.",
              reaction: "Injects your current tasks + latest devlog as context, and links a single in-progress task to the session.",
              gatedBy: "Inject project context into sessions"),
        .init(event: "PreToolUse",
              firesWhen: "Before Claude runs each tool (Read, Edit, Bash, …).",
              reaction: "Records the tool activity (file reads/writes/edits, commands) onto the live session card and the events feed.",
              gatedBy: nil),
        .init(event: "PostToolUse",
              firesWhen: "After each tool call completes.",
              reaction: "Clears the current-tool indicator; if it was a git/gh command, refreshes git status and PRs.",
              gatedBy: nil),
        .init(event: "Stop",
              firesWhen: "Claude finishes a turn and is waiting for you (fires every turn, not session end).",
              reaction: "Marks the session idle — still active, just waiting.",
              gatedBy: nil),
        .init(event: "Notification",
              firesWhen: "Claude is waiting on you — a permission request or idle prompt.",
              reaction: "Posts a “Claude needs input” notification pointing at the session's project.",
              gatedBy: "Notify on Claude task activity"),
        .init(event: "SessionEnd",
              firesWhen: "The session truly ends.",
              reaction: "Marks the session ended; if enabled, writes a devlog summarizing meaningful sessions; advances the linked task to AI-touched (handed back to you).",
              gatedBy: "Auto-write a devlog when a session ends"),
    ]

    /// Absolute path to the installed helper script. (#8 — no $HOME variable expansion)
    private static let helperPath = "\(NSHomeDirectory())/.devdash/bin/devdash-hook"

    // MARK: - Helper script

    /// Writes the bridge script that forwards hook payloads to the running app.
    /// Idempotent; always overwrites with the canonical content.
    static func installHelperScript() {
        let binDir = "\(NSHomeDirectory())/.devdash/bin"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)

        // Pure-shell JSON extraction — no python3 dependency (#7)
        let script = #"""
        #!/bin/bash
        # dev-dash hook bridge: forwards a Claude Code hook event to the running app.
        ep="$HOME/.devdash/event-endpoint.json"
        [ -f "$ep" ] || exit 0
        port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$ep")
        token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ep")
        [ -z "$port" ] && exit 0
        payload=$(cat)
        curl -s -m 5 -X POST \
          -H "Content-Type: application/json" \
          -H "X-DevDash-Token: $token" \
          --data-binary "$payload" \
          "http://127.0.0.1:$port/hook" 2>/dev/null
        exit 0
        """#

        let url = URL(fileURLWithPath: helperPath)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
    }

    // MARK: - Project hook installation

    /// Reconciles dev-dash hook entries in `<projectPath>/.claude/settings.json` to
    /// exactly the given `events` set. Events in the set get a devdash entry added
    /// (idempotent); events NOT in the set have any devdash entry removed.
    /// Calls `installHelperScript()` first. Preserves all non-devdash keys/hooks.
    /// Throws `InstallError.settingsCorrupted` if the file exists but can't be parsed,
    /// to prevent overwriting settings we don't understand. (#1)
    static func installProjectHooks(projectPath: String, events: Set<String>) throws {
        installHelperScript()

        let settingsPath = "\(projectPath)/.claude/settings.json"
        let fm = FileManager.default

        try fm.createDirectory(atPath: "\(projectPath)/.claude",
                               withIntermediateDirectories: true)

        // Distinguish "absent" from "present but corrupt" (#1)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            guard
                let data = fm.contents(atPath: settingsPath),
                let obj = try? JSONSerialization.jsonObject(with: data),
                let dict = obj as? [String: Any]
            else {
                throw InstallError.settingsCorrupted(settingsPath)
            }
            root = dict

            // Backup before mutating (#1)
            let bakPath = settingsPath + ".bak"
            try? fm.removeItem(atPath: bakPath)
            try? fm.copyItem(atPath: settingsPath, toPath: bakPath)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Absolute path in command — no $HOME shell expansion assumption (#8)
        let commandPath = helperPath

        for spec in hookSpecs {
            let event = spec.event
            if events.contains(event) {
                // Ensure a devdash entry exists (idempotent add)
                var entries = hooks[event] as? [[String: Any]] ?? []
                let alreadyInstalled = entries.contains { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String)?.hasSuffix("devdash-hook") == true }
                }
                if !alreadyInstalled {
                    let entry: [String: Any] = [
                        "hooks": [["type": "command", "command": commandPath]]
                    ]
                    entries.append(entry)
                    hooks[event] = entries
                }
            } else {
                // Remove any devdash entries for this event, preserving non-devdash entries
                guard var entries = hooks[event] as? [[String: Any]] else { continue }
                entries = entries.filter { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return true }
                    return !innerHooks.contains { ($0["command"] as? String)?.hasSuffix("devdash-hook") == true }
                }
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        root["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
    }

    // MARK: - Hook install check

    /// Returns true if dev-dash hooks are already installed in the project's
    /// `.claude/settings.json`. Never throws — any parse failure or missing
    /// file returns false.
    static func isInstalled(projectPath: String) -> Bool {
        let settingsPath = "\(projectPath)/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String)?.hasSuffix("devdash-hook") == true }
            }
        }
    }

    // MARK: - Project hook removal

    /// Removes only dev-dash hook entries from `.claude/settings.json`;
    /// leaves all other hooks and settings intact.
    static func uninstallProjectHooks(projectPath: String) {
        let settingsPath = "\(projectPath)/.claude/settings.json"
        let fm = FileManager.default

        guard let data = fm.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              var root = obj as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return }

        for spec in hookSpecs {
            let event = spec.event
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries = entries.filter { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return true }
                return !innerHooks.contains { ($0["command"] as? String)?.hasSuffix("devdash-hook") == true }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        root["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
    }
}
