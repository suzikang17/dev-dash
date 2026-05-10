import Foundation

enum GitScanner {
    struct Info {
        let isGit: Bool
        let lastCommit: Date?
        let branch: String?
        let remoteURL: String?
        let githubURL: URL?
    }

    static func info(for path: String) async -> Info {
        let gitDir = "\(path)/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return Info(isGit: false, lastCommit: nil, branch: nil, remoteURL: nil, githubURL: nil)
        }

        // One process per project: combine all queries via shell so we only spawn once.
        // Format: <iso>\n---\n<branch>\n---\n<remote>
        let cmd = #"git log -1 --format=%cI 2>/dev/null; printf '\n---\n'; git rev-parse --abbrev-ref HEAD 2>/dev/null; printf '\n---\n'; git remote get-url origin 2>/dev/null"#
        let raw = await runShell("/bin/sh", args: ["-c", cmd], cwd: path, timeoutSeconds: 2) ?? ""
        let parts = raw.components(separatedBy: "\n---\n")

        let lastIsoVal = parts.indices.contains(0) ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let branchVal = parts.indices.contains(1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let remoteVal = parts.indices.contains(2) ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        let formatter = ISO8601DateFormatter()
        let lastDate = lastIsoVal.isEmpty ? nil : formatter.date(from: lastIsoVal)

        var ghURL: URL? = nil
        if !remoteVal.isEmpty,
           let regex = try? NSRegularExpression(pattern: #"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$"#),
           let match = regex.firstMatch(in: remoteVal, range: NSRange(remoteVal.startIndex..., in: remoteVal)),
           let range = Range(match.range(at: 1), in: remoteVal) {
            ghURL = URL(string: "https://github.com/\(remoteVal[range])")
        }

        return Info(
            isGit: true,
            lastCommit: lastDate,
            branch: branchVal.isEmpty ? nil : branchVal,
            remoteURL: remoteVal.isEmpty ? nil : remoteVal,
            githubURL: ghURL
        )
    }
}

enum HealthCalculator {
    static func compute(lastCommit: Date?, isGit: Bool) -> HealthStatus {
        if !isGit { return .noGit }
        guard let last = lastCommit else { return .archived }
        let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
        if days <= 7 { return .active }
        if days <= 30 { return .moderate }
        if days < 90 { return .stale }
        return .archived
    }
}
