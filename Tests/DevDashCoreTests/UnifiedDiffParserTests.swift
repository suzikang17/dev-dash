import XCTest
@testable import DevDashCore

final class UnifiedDiffParserTests: XCTestCase {

    func test_emptyInput_producesNoRows() {
        let d = UnifiedDiffParser.parse("")
        XCTAssertTrue(d.rows.isEmpty)
        XCTAssertFalse(d.isBinary)
    }

    func test_binaryDiff_isDetected() {
        let text = "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n"
        let d = UnifiedDiffParser.parse(text)
        XCTAssertTrue(d.isBinary)
        XCTAssertTrue(d.rows.isEmpty)
    }

    func test_addedOnly_newFile() {
        let text = """
        diff --git a/f b/f
        new file mode 100644
        index 0000000..0cfbf08
        --- /dev/null
        +++ b/f
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body[0].kind, .added)
        XCTAssertNil(body[0].leftLineNo)
        XCTAssertEqual(body[0].rightLineNo, 1)
        XCTAssertEqual(body[0].rightText, "hello")
        XCTAssertEqual(body[1].rightLineNo, 2)
        XCTAssertEqual(body[1].rightText, "world")
    }

    func test_removedOnly() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +0,0 @@
        -foo
        -bar
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body[0].kind, .removed)
        XCTAssertEqual(body[0].leftLineNo, 1)
        XCTAssertEqual(body[0].leftText, "foo")
        XCTAssertNil(body[0].rightLineNo)
        XCTAssertEqual(body[1].leftLineNo, 2)
    }

    func test_modified_pairsLinesWithWordSpans() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -the quick brown fox
        +the slow brown fox
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 1)
        let row = body[0]
        XCTAssertEqual(row.kind, .modified)
        XCTAssertEqual(row.leftText, "the quick brown fox")
        XCTAssertEqual(row.rightText, "the slow brown fox")
        // common prefix "the " (4), common suffix " brown fox" (10)
        XCTAssertEqual(row.leftSpans, [WordSpan(start: 4, length: 5)])  // "quick"
        XCTAssertEqual(row.rightSpans, [WordSpan(start: 4, length: 4)]) // "slow"
        XCTAssertEqual(row.leftLineNo, 1)
        XCTAssertEqual(row.rightLineNo, 1)
    }

    func test_contextAndChange_lineNumbersAdvance() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         context1
        -old
        +new
         context2
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.map(\.kind), [.context, .modified, .context])
        XCTAssertEqual(body[0].leftLineNo, 1); XCTAssertEqual(body[0].rightLineNo, 1)
        XCTAssertEqual(body[1].leftLineNo, 2); XCTAssertEqual(body[1].rightLineNo, 2)
        XCTAssertEqual(body[2].leftLineNo, 3); XCTAssertEqual(body[2].rightLineNo, 3)
        XCTAssertEqual(body[2].leftText, "context2")
    }

    func test_noNewlineMarker_isSkipped() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0].kind, .modified)
    }

    func test_multiHunk_resetsLineNumbers() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -a
        +A
        @@ -10,1 +10,1 @@
        -b
        +B
        """
        let d = UnifiedDiffParser.parse(text)
        let headers = d.rows.filter { $0.kind == .hunkHeader }
        XCTAssertEqual(headers.count, 2)
        let mods = d.rows.filter { $0.kind == .modified }
        XCTAssertEqual(mods.count, 2)
        XCTAssertEqual(mods[0].leftLineNo, 1)
        XCTAssertEqual(mods[1].leftLineNo, 10)
    }
}
