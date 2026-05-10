import Foundation

actor IssueCache {
    static let shared = IssueCache()
    private var entries: [String: (fetchedAt: Date, issues: [Issue])] = [:]
    private let ttl: TimeInterval = 5 * 60

    func get(_ repo: String) -> [Issue]? {
        guard let entry = entries[repo], Date().timeIntervalSince(entry.fetchedAt) < ttl else {
            return nil
        }
        return entry.issues
    }

    func set(_ repo: String, issues: [Issue]) {
        entries[repo] = (Date(), issues)
    }

    func clear() {
        entries.removeAll()
    }
}

enum IssueScanner {
    static func repo(from githubURL: URL?) -> String? {
        guard let url = githubURL else { return nil }
        let str = url.absoluteString
        guard let regex = try? NSRegularExpression(pattern: #"github\.com/([^/]+/[^/]+?)(?:\.git)?$"#),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let r = Range(match.range(at: 1), in: str) else {
            return nil
        }
        return String(str[r])
    }

    static func fetch(repo: String) async -> [Issue] {
        if let cached = await IssueCache.shared.get(repo) { return cached }

        let raw = await runShell(
            "/usr/local/bin/gh",
            args: [
                "issue", "list",
                "--repo", repo,
                "--state", "open",
                "--limit", "5",
                "--json", "number,title,url,state,updatedAt,labels"
            ],
            cwd: NSHomeDirectory(),
            timeoutSeconds: 8
        ) ?? ""

        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            await IssueCache.shared.set(repo, issues: [])
            return []
        }

        let formatter = ISO8601DateFormatter()
        let issues: [Issue] = arr.compactMap { dict in
            guard let number = dict["number"] as? Int,
                  let title = dict["title"] as? String,
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let state = dict["state"] as? String,
                  let updatedAt = dict["updatedAt"] as? String else { return nil }

            let labels = (dict["labels"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }

            return Issue(
                number: number,
                title: title,
                url: url,
                state: state,
                updatedAt: formatter.date(from: updatedAt),
                labels: labels
            )
        }

        await IssueCache.shared.set(repo, issues: issues)
        return issues
    }

    static func gather(projects: [Project]) async -> [(path: String, name: String, repo: String, issues: [Issue])] {
        let candidates = projects.compactMap { p -> (path: String, name: String, repo: String)? in
            guard let r = repo(from: p.githubURL) else { return nil }
            return (p.path, p.name, r)
        }

        return await withTaskGroup(of: (String, String, String, [Issue])?.self) { group in
            for c in candidates {
                group.addTask {
                    let issues = await fetch(repo: c.repo)
                    if issues.isEmpty { return nil }
                    return (c.path, c.name, c.repo, issues)
                }
            }
            var results: [(String, String, String, [Issue])] = []
            for await r in group { if let r = r { results.append(r) } }
            return results.map { (path: $0.0, name: $0.1, repo: $0.2, issues: $0.3) }
        }
    }
}
