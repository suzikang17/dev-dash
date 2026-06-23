import Foundation

public enum UnifiedDiffParser {

    public static func parse(_ diffText: String) -> FileDiff {
        if diffText.range(of: "\nBinary files ") != nil || diffText.hasPrefix("Binary files ") {
            return FileDiff(rows: [], isBinary: true)
        }

        var rows: [DiffRow] = []
        var inHunk = false
        var leftNo = 0
        var rightNo = 0
        var pendingRemoved: [(Int, String)] = []
        var pendingAdded: [(Int, String)] = []

        func flush() {
            let n = max(pendingRemoved.count, pendingAdded.count)
            for i in 0..<n {
                if i < pendingRemoved.count && i < pendingAdded.count {
                    let (lno, ltext) = pendingRemoved[i]
                    let (rno, rtext) = pendingAdded[i]
                    let (ls, rs) = wordSpans(ltext, rtext)
                    rows.append(DiffRow(kind: .modified,
                                        leftLineNo: lno, leftText: ltext,
                                        rightLineNo: rno, rightText: rtext,
                                        leftSpans: ls, rightSpans: rs))
                } else if i < pendingRemoved.count {
                    let (lno, ltext) = pendingRemoved[i]
                    rows.append(DiffRow(kind: .removed, leftLineNo: lno, leftText: ltext))
                } else {
                    let (rno, rtext) = pendingAdded[i]
                    rows.append(DiffRow(kind: .added, rightLineNo: rno, rightText: rtext))
                }
            }
            pendingRemoved.removeAll(keepingCapacity: true)
            pendingAdded.removeAll(keepingCapacity: true)
        }

        for line in diffText.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                flush()
                let (l, r) = parseHunkHeader(line)
                leftNo = l
                rightNo = r
                inHunk = true
                rows.append(DiffRow(kind: .hunkHeader, headerText: line))
                continue
            }
            if line.hasPrefix("diff --git") {
                flush()
                inHunk = false
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("\\") { continue }    // \ No newline at end of file
            guard let first = line.first else { continue } // skip empty split artifacts
            let text = String(line.dropFirst())
            switch first {
            case " ":
                flush()
                rows.append(DiffRow(kind: .context,
                                    leftLineNo: leftNo, leftText: text,
                                    rightLineNo: rightNo, rightText: text))
                leftNo += 1
                rightNo += 1
            case "-":
                pendingRemoved.append((leftNo, text))
                leftNo += 1
            case "+":
                pendingAdded.append((rightNo, text))
                rightNo += 1
            default:
                continue
            }
        }
        flush()
        return FileDiff(rows: rows)
    }

    static func parseHunkHeader(_ line: String) -> (Int, Int) {
        var left = 0
        var right = 0
        for tok in line.split(separator: " ") {
            if tok.hasPrefix("-") {
                let num = tok.dropFirst().split(separator: ",").first ?? ""
                left = Int(num) ?? 0
            } else if tok.hasPrefix("+") {
                let num = tok.dropFirst().split(separator: ",").first ?? ""
                right = Int(num) ?? 0
            }
        }
        return (left, right)
    }

    /// Character-level common prefix/suffix → a single changed span per side (empty if none).
    static func wordSpans(_ left: String, _ right: String) -> ([WordSpan], [WordSpan]) {
        let l = Array(left)
        let r = Array(right)
        var p = 0
        while p < l.count && p < r.count && l[p] == r[p] { p += 1 }
        var s = 0
        while s < (l.count - p) && s < (r.count - p) && l[l.count - 1 - s] == r[r.count - 1 - s] { s += 1 }
        let lLen = l.count - p - s
        let rLen = r.count - p - s
        let ls = lLen > 0 ? [WordSpan(start: p, length: lLen)] : []
        let rs = rLen > 0 ? [WordSpan(start: p, length: rLen)] : []
        return (ls, rs)
    }
}
