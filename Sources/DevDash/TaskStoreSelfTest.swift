import Foundation

/// Headless deterministic checks for TaskStore. Invoked from `DevDashApp.init()`.
///   DevDash --selftest-taskstore
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum TaskStoreSelfTest {
    static func runIfRequested() {
        // Diagnostic: --dump-tasks <projectPath> prints TaskStore.read() results.
        if let i = CommandLine.arguments.firstIndex(of: "--dump-tasks"),
           i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let tasks = TaskStore.read(path)
            print("dump-tasks \(path): \(tasks.count) task(s)")
            for t in tasks { print("  [\(t.id)] [\(t.status.rawValue)/\(t.owner.rawValue)] \(t.title)") }
            exit(0)
        }
        // Diagnostic: --dump-projects prints the scanned project paths + task counts.
        if CommandLine.arguments.contains("--dump-projects") {
            let sem = DispatchSemaphore(value: 0)
            Task {
                let projs = await ProjectScanner.scanAll()
                print("scanned \(projs.count) project(s):")
                for p in projs.sorted(by: { $0.path < $1.path }) {
                    print("  \(p.path)  (\(TaskStore.read(p.path).count) tasks)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        guard CommandLine.arguments.contains("--selftest-taskstore") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkFullFieldRoundTrip(check)
        checkAdversarialEscaping(check)
        checkNotesWithSentinelLines(check)
        checkPhasesWithCommas(check)
        checkUnknownKeyPreservation(check)
        checkNumericIdTolerance(check)
        checkSetStatusHistory(check)
        checkMigrationOneTime(check)
        checkSetPR(check)

        let msg = failures.isEmpty
            ? "taskstore-selftest: ALL PASS"
            : "taskstore-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Helpers

    private static func makeTempProject(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-taskstore-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Check a: full-field round-trip

    private static func checkFullFieldRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("a")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(
                projectPath: proj,
                title: "Round-trip task",
                category: .engineering,
                stage: "alpha",
                notes: "Some notes here",
                source: .local,
                parentId: nil,
                linkedDocPath: "/docs/design.md"
            )
        } catch {
            check(false, "a: add threw \(error)"); return
        }

        // Set phases, ghIssue, and pr via update
        var modified = t
        modified.phases = ["Phase 1", "Phase 2"]
        modified.ghIssueURL = URL(string: "https://github.com/org/repo/issues/42")
        modified.pr = "https://github.com/org/repo/pull/7"
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "a: update threw \(error)"); return
        }

        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "a: task not found after read"); return
        }

        check(read.title == "Round-trip task",        "a: title round-trip")
        check(read.notes == "Some notes here",         "a: notes round-trip")
        check(read.category == .engineering,           "a: category round-trip")
        check(read.stage == "alpha",                   "a: stage round-trip")
        check(read.source == .local,                   "a: source round-trip")
        check(read.status == .open,                    "a: status round-trip")
        check(read.parentId == nil,                    "a: parentId nil round-trip")
        check(read.linkedDocPath == "/docs/design.md", "a: linkedDocPath round-trip")
        check(read.phases == ["Phase 1", "Phase 2"],   "a: phases round-trip")
        check(read.ghIssueURL?.absoluteString == "https://github.com/org/repo/issues/42",
              "a: ghIssueURL round-trip")
        check(read.pr == "https://github.com/org/repo/pull/7", "a: pr round-trip")
    }

    // MARK: - Check b: adversarial title/notes escaping

    private static func checkAdversarialEscaping(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("b")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let weirdTitle = #"She said \"hi\" \ path"#
        let weirdNotes = #"notes with "quotes", backslash \ colon: and # hash"#

        let t: TaskItem
        do {
            t = try TaskStore.add(
                projectPath: proj,
                title: weirdTitle,
                notes: weirdNotes
            )
        } catch {
            check(false, "b: add threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "b: task not found after first read"); return
        }

        check(read1.title == weirdTitle,  "b: title with quotes+backslash preserved on first read")
        check(read1.notes == weirdNotes,  "b: notes with special chars preserved on first read")

        // Now update (change status to done) and re-read — assert no compounding corruption.
        var modified = read1
        modified.status = .done
        do {
            try TaskStore.update(projectPath: proj, modified)
        } catch {
            check(false, "b: update threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "b: task not found after update+read"); return
        }

        check(read2.title == weirdTitle, "b: title preserved after update round-trip")
        check(read2.notes == weirdNotes, "b: notes preserved after update round-trip")
    }

    // MARK: - Check c: notes containing sentinel and heading lines

    private static func checkNotesWithSentinelLines(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("c")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // Notes that contain strings that look like the sentinel and a heading.
        let notes = "Intro line\n## Status history\nSome user content\n# Some Heading\nMore content"

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Sentinel test", notes: notes)
        } catch {
            check(false, "c: add threw \(error)"); return
        }

        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "c: task not found after read"); return
        }

        check(read.notes == notes, "c: notes containing '## Status history' and '# Some Heading' fully preserved")
    }

    // MARK: - Check d: phases with commas

    private static func checkPhasesWithCommas(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("d")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Phases task")
        } catch {
            check(false, "d: add threw \(error)"); return
        }

        let commaPhase = "Design, build, ship"
        let otherPhase = "Test"
        do {
            try TaskStore.setPhases(projectPath: proj, id: t.id, phases: [commaPhase, otherPhase])
        } catch {
            check(false, "d: setPhases threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after setPhases"); return
        }

        check(read1.phases?.count == 2, "d: comma-containing phase name survives as ONE phase (count==2), got \(read1.phases?.count ?? -1)")
        check(read1.phases?.contains(commaPhase) == true, "d: comma phase name round-trips exactly")
        check(read1.phases?.contains(otherPhase) == true, "d: second phase name preserved")

        // addCompletedPhase with the comma-containing name.
        do {
            try TaskStore.addCompletedPhase(projectPath: proj, id: t.id, phase: commaPhase)
        } catch {
            check(false, "d: addCompletedPhase threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after addCompletedPhase"); return
        }

        check(read2.completedPhases.contains(commaPhase), "d: completedPhases contains comma phase after add")
        check(read2.completedPhases.count == 1,            "d: no duplicate in completedPhases (count==1), got \(read2.completedPhases.count)")

        // Call addCompletedPhase again with the same name — should be idempotent.
        do {
            try TaskStore.addCompletedPhase(projectPath: proj, id: t.id, phase: commaPhase)
        } catch {
            check(false, "d: second addCompletedPhase threw \(error)"); return
        }

        let tasks3 = TaskStore.read(proj)
        guard let read3 = tasks3.first(where: { $0.id == t.id }) else {
            check(false, "d: task not found after second addCompletedPhase"); return
        }

        check(read3.completedPhases.count == 1, "d: addCompletedPhase is idempotent (still count==1), got \(read3.completedPhases.count)")
    }

    // MARK: - Check e: unknown-key preservation

    private static func checkUnknownKeyPreservation(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("e")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Unknown keys task")
        } catch {
            check(false, "e: add threw \(error)"); return
        }

        // Inject unknown frontmatter keys directly into the file.
        let dir = TaskStore.file(for: proj)
        guard let filename = TaskStore.findFile(id: t.id, in: dir) else {
            check(false, "e: can't find task file"); return
        }
        let path = "\(dir)/\(filename)"
        guard var raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "e: can't read task file"); return
        }

        // Insert unknown keys before closing --- fence.
        raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "devdash_id", value: "\"abc-123\"")
        raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "pr", value: "\"https://x/y/1\"")
        do {
            try raw.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            check(false, "e: can't write injected keys: \(error)"); return
        }

        // Now call setStatus and setOwner — these do in-place edits.
        do {
            try TaskStore.setStatus(projectPath: proj, id: t.id, status: .inProgress)
            try TaskStore.setOwner(projectPath: proj, id: t.id, owner: .ai)
        } catch {
            check(false, "e: setStatus/setOwner threw \(error)"); return
        }

        // Read raw file back and verify unknown keys still present.
        guard let rawAfter = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "e: can't re-read file after mutations"); return
        }

        check(rawAfter.contains("devdash_id:"), "e: devdash_id key preserved after setStatus+setOwner")
        check(rawAfter.contains("abc-123"),     "e: devdash_id value preserved")
        check(rawAfter.contains("pr:"),         "e: pr key preserved after setStatus+setOwner")
        check(rawAfter.contains("https://x/y/1"), "e: pr value preserved")

        // Also call update() and verify again.
        let tasks = TaskStore.read(proj)
        if let readTask = tasks.first(where: { $0.id == t.id }) {
            var mut = readTask
            mut.status = .done
            do {
                try TaskStore.update(projectPath: proj, mut)
            } catch {
                check(false, "e: update threw \(error)"); return
            }

            guard let rawAfterUpdate = try? String(contentsOfFile: path, encoding: .utf8) else {
                check(false, "e: can't re-read file after update()"); return
            }
            check(rawAfterUpdate.contains("devdash_id:"),     "e: devdash_id preserved after update()")
            check(rawAfterUpdate.contains("pr:"),             "e: pr key preserved after update()")
        } else {
            check(false, "e: task not found for update() phase")
        }
    }

    // MARK: - Check f: numeric id tolerance and cascade delete

    private static func checkNumericIdTolerance(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("f")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let dir = TaskStore.file(for: proj)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "f: createDirectory threw \(error)"); return
        }

        // Write files with non-zero-padded names directly (as lore CLI would).
        let parentDoc = """
            ---
            lore_type: task
            title: "Parent"
            status: open
            category: other
            source: local
            created: 2026-06-01
            ---
            # Parent
            """
        let childDoc = """
            ---
            lore_type: task
            title: "Child"
            status: open
            category: other
            source: local
            created: 2026-06-01
            parent: "1"
            ---
            # Child
            """

        do {
            try parentDoc.write(toFile: "\(dir)/1-foo.md", atomically: true, encoding: .utf8)
            try childDoc.write(toFile: "\(dir)/2-bar.md",  atomically: true, encoding: .utf8)
        } catch {
            check(false, "f: writing test files threw \(error)"); return
        }

        check(TaskStore.hasChildren(projectPath: proj, id: "1"),
              "f: hasChildren(\"1\") is true when child has parent: \"1\"")

        // Cascade delete of "1" should also remove "2".
        do {
            try TaskStore.delete(projectPath: proj, id: "1")
        } catch {
            check(false, "f: delete threw \(error)"); return
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let mdFiles = files.filter { $0.hasSuffix(".md") }
        check(mdFiles.isEmpty, "f: cascade delete removed both parent and child (got \(mdFiles))")
    }

    // MARK: - Check g: setStatus history + dates

    private static func checkSetStatusHistory(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("g")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "Status history task",
                                  notes: "User content here")
        } catch {
            check(false, "g: add threw \(error)"); return
        }

        // Transition open → done.
        do {
            try TaskStore.setStatus(projectPath: proj, id: t.id, status: .done)
        } catch {
            check(false, "g: setStatus threw \(error)"); return
        }

        let dir = TaskStore.file(for: proj)
        guard let filename = TaskStore.findFile(id: t.id, in: dir),
              let rawAfter = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else {
            check(false, "g: can't read file after setStatus"); return
        }

        let fm = TaskStore.parseTaskFrontmatter(rawAfter)
        check(fm["status"] == "done",                     "g: status frontmatter == done")
        check(fm["completed"] != nil && !fm["completed"]!.isEmpty,
              "g: completed date set after ->done")
        check(rawAfter.contains(TaskStore.statusHistorySentinel),
              "g: sentinel present in file")
        check(rawAfter.contains("## Status history"),     "g: ## Status history heading present")
        check(rawAfter.contains("open → done"),           "g: history entry records open->done transition")

        // Notes should still be extractable and clean.
        let tasks = TaskStore.read(proj)
        guard let read = tasks.first(where: { $0.id == t.id }) else {
            check(false, "g: task not found after setStatus+read"); return
        }

        check(read.notes == "User content here", "g: notes clean after setStatus (sentinel not leaked)")
        check(read.status == .done,              "g: status reads back as done")
    }

    // MARK: - Check i: setPR setter

    private static func checkSetPR(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("i")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let t: TaskItem
        do {
            t = try TaskStore.add(projectPath: proj, title: "PR setter task",
                                  notes: "Some notes")
        } catch {
            check(false, "i: add threw \(error)"); return
        }

        // Set a PR URL.
        let prURL = "https://github.com/org/repo/pull/42"
        do {
            try TaskStore.setPR(projectPath: proj, id: t.id, url: prURL)
        } catch {
            check(false, "i: setPR threw \(error)"); return
        }

        let tasks1 = TaskStore.read(proj)
        guard let read1 = tasks1.first(where: { $0.id == t.id }) else {
            check(false, "i: task not found after setPR"); return
        }
        check(read1.pr == prURL, "i: pr field set correctly (got \(read1.pr ?? "nil"))")

        // Notes and other fields must survive the in-place edit.
        check(read1.notes == "Some notes", "i: notes preserved after setPR")
        check(read1.title == "PR setter task", "i: title preserved after setPR")

        // Clear the PR URL (nil).
        do {
            try TaskStore.setPR(projectPath: proj, id: t.id, url: nil)
        } catch {
            check(false, "i: setPR(nil) threw \(error)"); return
        }

        let tasks2 = TaskStore.read(proj)
        guard let read2 = tasks2.first(where: { $0.id == t.id }) else {
            check(false, "i: task not found after setPR(nil)"); return
        }
        check(read2.pr == nil, "i: pr field cleared after setPR(nil) (got \(read2.pr ?? "nil"))")

        // Verify raw file no longer has the pr: key.
        let dir = TaskStore.file(for: proj)
        if let filename = TaskStore.findFile(id: t.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8) {
            let fm = TaskStore.parseTaskFrontmatter(raw)
            check(fm["pr"] == nil, "i: pr key absent from frontmatter after clear")
        } else {
            check(false, "i: can't read file for raw verification")
        }

        // DashboardStore helpers: isGHPRCreate and parsePRURL.
        check(DashboardStore.isGHPRCreate("gh pr create --title foo"),
              "i: isGHPRCreate matches 'gh pr create --title foo'")
        check(DashboardStore.isGHPRCreate("git add . && gh pr create"),
              "i: isGHPRCreate matches after &&")
        check(!DashboardStore.isGHPRCreate("echo \"gh pr create\""),
              "i: isGHPRCreate does NOT match echo")
        check(!DashboardStore.isGHPRCreate("gh pr list"),
              "i: isGHPRCreate does NOT match 'gh pr list'")
        check(!DashboardStore.isGHPRCreate("gh pr"),
              "i: isGHPRCreate does NOT match bare 'gh pr'")

        let sampleOutput = "https://github.com/org/repo/pull/99\n"
        check(DashboardStore.parsePRURL(from: sampleOutput) == "https://github.com/org/repo/pull/99",
              "i: parsePRURL extracts PR URL from gh output")
        check(DashboardStore.parsePRURL(from: "no url here") == nil,
              "i: parsePRURL returns nil for non-URL output")

        // kanbanColumn guard: a done task is NOT in aiWorking, so the PR promotion
        // block must not touch it (isGHPRCreate gate only fires when kanbanColumn == .aiWorking).
        let projDone = makeTempProject("i-done")
        defer { try? FileManager.default.removeItem(atPath: projDone) }
        let td: TaskItem
        do {
            td = try TaskStore.add(projectPath: projDone, title: "Done task")
        } catch {
            check(false, "i: done-task add threw \(error)"); return
        }
        // Mark done and owner=.ai to confirm kanbanColumn != .aiWorking when status==.done.
        do {
            try TaskStore.setStatus(projectPath: projDone, id: td.id, status: .done)
            try TaskStore.setOwner(projectPath: projDone, id: td.id, owner: .ai)
        } catch {
            check(false, "i: done-task setup threw \(error)"); return
        }
        let doneTasks = TaskStore.read(projDone)
        if let doneTask = doneTasks.first(where: { $0.id == td.id }) {
            check(doneTask.kanbanColumn != .aiWorking,
                  "i: done task is NOT in aiWorking (kanban=\(doneTask.kanbanColumn))")
            // Simulate what the PostToolUse block does: only act when kanbanColumn == .aiWorking.
            let wouldPromote = doneTask.kanbanColumn == .aiWorking
            check(!wouldPromote, "i: done task would NOT be promoted by PR gate (aiWorking guard)")
        } else {
            check(false, "i: done task not found after setup")
        }
    }

    // MARK: - Check h: migration one-time

    private static func checkMigrationOneTime(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("h")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        let devdashDir = "\(proj)/.devdash"
        do {
            try FileManager.default.createDirectory(atPath: devdashDir, withIntermediateDirectories: true)
        } catch {
            check(false, "h: createDirectory .devdash threw \(error)"); return
        }

        // Build valid JSON matching TaskItem Codable encoding (JSONEncoder + iso8601 dates).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let task1 = TaskItem(
            id: "uuid-aaa-111",
            title: "Migrated Task One",
            notes: "First migrated task",
            stage: nil,
            category: .engineering,
            source: .local,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: nil,
            completedAt: nil,
            ghIssueURL: nil,
            parentId: nil
        )
        let task2 = TaskItem(
            id: "uuid-bbb-222",
            title: "Migrated Task Two",
            notes: nil,
            stage: nil,
            category: .design,
            source: .local,
            status: .open,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            startedAt: nil,
            completedAt: nil,
            ghIssueURL: nil,
            parentId: nil
        )

        guard let jsonData = try? encoder.encode([task1, task2]),
              let _ = try? jsonData.write(to: URL(fileURLWithPath: "\(devdashDir)/tasks.json"))
        else {
            check(false, "h: failed to write tasks.json"); return
        }

        // First read — should trigger migration.
        let tasks1 = TaskStore.read(proj)
        check(tasks1.count == 2, "h: first read after migration returns 2 tasks (got \(tasks1.count))")
        check(tasks1.contains(where: { $0.title == "Migrated Task One" }),
              "h: Migrated Task One is present")
        check(tasks1.contains(where: { $0.title == "Migrated Task Two" }),
              "h: Migrated Task Two is present")

        // tasks.json should be renamed.
        let jsonExists = FileManager.default.fileExists(atPath: "\(devdashDir)/tasks.json")
        let migratedExists = FileManager.default.fileExists(atPath: "\(devdashDir)/tasks.json.migrated")
        check(!jsonExists,    "h: tasks.json was renamed (no longer exists)")
        check(migratedExists, "h: tasks.json.migrated exists")

        // Second read — no duplicates.
        let tasks2 = TaskStore.read(proj)
        check(tasks2.count == 2, "h: second read produces no duplicates (got \(tasks2.count))")
    }
}
