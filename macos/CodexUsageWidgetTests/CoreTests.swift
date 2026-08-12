import Darwin
import Foundation
import XCTest
@testable import CodexUsageWidget

final class CoreTests: XCTestCase {
    private var contractRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/contract/v1", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageWidget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: contractRoot.appendingPathComponent("inputs/\(name).jsonl"))
    }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private func scanTemporaryDirectories() -> Set<String> {
        let prefix = "CodexUsageWidget-scan-"
        return Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix(prefix) } ?? [])
    }

    private func resourceHighWaterBytes() throws -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CoreError.unavailable }
        return Int64(usage.ru_maxrss)
    }

    private func writeSession(_ data: Data, named name: String, to sessions: URL, modified: Date) throws -> URL {
        let url = sessions.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func tokenEvent(
        totalInput: Int,
        cachedInput: Int,
        lastInput: Int,
        lastCached: Int,
        limitID: String? = "codex"
    ) -> Data {
        let limit = limitID.map { "\"limit_id\":\"\($0)\"," } ?? ""
        return Data("""
        {"timestamp":"2026-08-11T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(totalInput),"cached_input_tokens":\(cachedInput),"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":\(totalInput + 10)},"last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":\(lastCached),"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":\(lastInput + 10)},"model_context_window":258400},"rate_limits":{\(limit)"primary":{"used_percent":45,"window_minutes":300,"resets_at":4102441200},"secondary":null}}}

        """.utf8)
    }

    func testReviewedContractFixtures() throws {
        let document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractRoot.appendingPathComponent("expected-state.json"))) as! [String: Any]
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document["sourceKind"] as? String, "local-session-observation")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let cases = document["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 16)
        for fixture in cases {
            let identifier = fixture["id"] as! String
            let now = formatter.date(from: fixture["nowUtc"] as! String)!
            let actual: [String: Any]
            if fixture["scenario"] as? String == "read-failure" {
                var metrics = ScanMetrics()
                metrics.readFailureCount = 1
                metrics.candidateFileCount = 1
                actual = UsageContract.evaluate(data: Data(), now: now, metrics: metrics).jsonObject()
            } else {
                let input = contractRoot.appendingPathComponent(fixture["input"] as! String)
                actual = try UsageContract.evaluate(fileURL: input, now: now).jsonObject()
            }
            let expected = fixture["expected"] as! [String: Any]
            let actualBytes = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
            let expectedBytes = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
            XCTAssertEqual(
                String(decoding: actualBytes, as: UTF8.self),
                String(decoding: expectedBytes, as: UTF8.self),
                "[contract/\(identifier)] full canonical snapshot"
            )
        }
    }

    func testInvalidStateIsBytePreservedUntilExplicitReset() throws {
        let root = try temporaryDirectory()
        let invalid = Data("{broken".utf8)
        func verify<T: Codable>(_ type: T.Type, defaultValue: T, name: String) throws {
            let url = root.appendingPathComponent(name)
            try invalid.write(to: url)
            let loaded = LocalStateStore.load(type, from: url, defaultValue: defaultValue)
            XCTAssertEqual(loaded.condition, .invalid)
            XCTAssertFalse(try LocalStateStore.save(defaultValue, to: url, previous: loaded.condition, resetInvalid: false))
            XCTAssertEqual(try Data(contentsOf: url), invalid)
            XCTAssertTrue(try LocalStateStore.save(defaultValue, to: url, previous: loaded.condition, resetInvalid: true))
            XCTAssertNotEqual(try Data(contentsOf: url), invalid)
        }
        try verify(WidgetPreferences.self, defaultValue: .defaultValue, name: "preferences.json")
        try verify(CacheLedger.self, defaultValue: .defaultValue, name: "cache-token-ledger.json")
        try verify(ReminderLedger.self, defaultValue: .defaultValue, name: "reminders.json")
    }

    func testDirectoryPrecedenceAndSymlinkContainment() throws {
        let root = try temporaryDirectory()
        let saved = root.appendingPathComponent("saved", isDirectory: true)
        let environment = root.appendingPathComponent("environment", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for candidate in [saved, environment, home.appendingPathComponent(".codex", isDirectory: true)] {
            try FileManager.default.createDirectory(at: candidate.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        XCTAssertEqual(
            DataDirectoryResolver.resolve(savedPath: saved.path, environment: ["CODEX_HOME": environment.path], homeDirectory: home)?.path,
            saved.path
        )

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let leaked = "{\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":99,\"window_minutes\":300,\"resets_at\":4102441200},\"secondary\":null}}}\n"
        try Data(leaked.utf8).write(to: outside.appendingPathComponent("outside.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: saved.appendingPathComponent("sessions/link"),
            withDestinationURL: outside
        )
        let demo = try fixture("demo")
        try demo.write(to: saved.appendingPathComponent("sessions/demo.jsonl"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = try SessionScanner.scan(dataDirectory: saved, now: formatter.date(from: "2026-08-11T00:00:01.000Z")!)
        XCTAssertEqual(result.state.remainingPercent, "55.0")
        XCTAssertEqual(result.state.metrics.candidateFileCount, 1)
        XCTAssertEqual(result.sessions.count, 1)
    }

    func testWriterLockAndResultSizeBoundary() throws {
        let root = try temporaryDirectory()
        let lockURL = root.appendingPathComponent("writer.lock")
        let first = try WriterLock(url: lockURL)
        let second = try WriterLock(url: lockURL)
        XCTAssertTrue(first.acquired)
        XCTAssertFalse(second.acquired)

        let channel = root.appendingPathComponent("CodexUsageWidget-scan-0123456789abcdef0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(
            at: channel,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let output = channel.appendingPathComponent("result.json")
        XCTAssertThrowsError(try ScanWorker.writePayload(Data(repeating: 0x20, count: 256 * 1024 + 1), to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSessionSnapshotsTasksAndLedgerRemainMonotonic() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date(timeIntervalSince1970: 1_786_406_400)
        let firstID = "11111111-1111-1111-1111-111111111111"
        let secondID = "22222222-2222-2222-2222-222222222222"
        try writeSession(try fixture("precision-and-tightest-window"), named: "rollout-\(firstID).jsonl", to: sessions, modified: now.addingTimeInterval(-120))
        try writeSession(try fixture("cache-order"), named: "rollout-\(secondID).jsonl", to: sessions, modified: now.addingTimeInterval(-60))
        let index = "{\"id\":\"\(firstID)\",\"thread_name\":\"First task\"}\n{\"id\":\"\(secondID)\",\"thread_name\":\"Second task\"}\n"
        try Data(index.utf8).write(to: root.appendingPathComponent("session_index.jsonl"))

        let result = try SessionScanner.scan(dataDirectory: root, now: now)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.state.tasks.map(\.name), ["Second task", "First task"])
        XCTAssertTrue(result.state.taskNamesAvailable)

        var ledger = CacheLedger.defaultValue
        let firstTotals = try XCTUnwrap(ledger.merge(result.sessions))
        XCTAssertEqual(firstTotals.hitTokens, 9_007_199_254_741_000)
        XCTAssertEqual(firstTotals.missTokens, 993)
        let regressed = result.sessions.map {
            SessionTokenSnapshot(id: $0.id, cacheHitTokens: "0", cacheMissTokens: "0")
        }
        let secondTotals = try XCTUnwrap(ledger.merge(regressed))
        XCTAssertEqual(secondTotals.hitTokens, firstTotals.hitTokens)
        XCTAssertEqual(secondTotals.missTokens, firstTotals.missTokens)

        let overflow = CacheLedger(
            schemaVersion: 1,
            sessions: [
                "a": CacheRecord(hitTokens: String(Int64.max), missTokens: "0"),
                "b": CacheRecord(hitTokens: "1", missTokens: "0")
            ]
        )
        XCTAssertNil(overflow.totals())
        XCTAssertFalse(CacheLedger(
            schemaVersion: 2,
            sessions: ["attempts": CacheRecord(hitTokens: "1", missTokens: "1", baselineAttempts: 10_001)]
        ).isValid)
    }

    func testForkHistoryPrefixIsSeparatedFromRawTaskAndLedgerTotals() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let id = "33333333-3333-3333-3333-333333333333"
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        data.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        data.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(data, named: "rollout-\(id).jsonl", to: sessions, modified: Date())
        try Data("{\"id\":\"\(id)\",\"thread_name\":\"Fork task\"}\n".utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))

        let result = try SessionScanner.scan(dataDirectory: root)

        XCTAssertEqual(result.sessions, [SessionTokenSnapshot(
            id: "rollout-\(id)",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: "720",
            cacheMissBaselineTokens: "180",
            cacheBaselineAttempts: 1
        )])
        XCTAssertEqual(result.state.tasks.first?.cacheHitTokens, "1200")
        XCTAssertEqual(result.state.tasks.first?.cacheMissTokens, "300")
    }

    func testOrdinarySessionKeepsItsFullLedgerSnapshot() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"44444444-4444-4444-4444-444444444444\"}}\n".utf8)
        data.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(data, named: "ordinary.jsonl", to: sessions, modified: Date())

        let result = try SessionScanner.scan(dataDirectory: root)

        XCTAssertEqual(result.sessions, [SessionTokenSnapshot(
            id: "ordinary",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: "0",
            cacheMissBaselineTokens: "0",
            cacheBaselineAttempts: 1
        )])
    }

    func testForkBaselineStreamingHeadReadsBeyondOneMiB() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        data.append(Data(repeating: 0x78, count: 1024 * 1024))
        data.append(0x0a)
        data.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        data.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(data, named: "bounded.jsonl", to: sessions, modified: Date())

        let result = try SessionScanner.scan(dataDirectory: root)

        XCTAssertEqual(result.sessions, [SessionTokenSnapshot(
            id: "bounded",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: "720",
            cacheMissBaselineTokens: "180",
            cacheBaselineAttempts: 1
        )])
    }

    func testForkBaselineReadDoesNotCrossFourMiBHeadBoundary() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        data.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80, limitID: nil))
        data.append(Data(repeating: 0x78, count: 4 * 1024 * 1024))
        data.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        data.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(data, named: "four-mib.jsonl", to: sessions, modified: Date())

        let result = try SessionScanner.scan(dataDirectory: root)

        XCTAssertEqual(result.sessions, [SessionTokenSnapshot(
            id: "four-mib",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: nil,
            cacheMissBaselineTokens: nil,
            cacheBaselineAttempts: 1
        )])
    }

    func testForkBaselinePrefersExplicitCodexAndFallsBackToLegacy() throws {
        let meta = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        var explicit = meta
        explicit.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80, limitID: nil))
        explicit.append(tokenEvent(totalInput: 1_100, cachedInput: 850, lastInput: 100, lastCached: 70))
        explicit.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 400, lastCached: 350))
        var legacy = meta
        legacy.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80, limitID: nil))
        legacy.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400, limitID: nil))
        func scan(_ data: Data, named name: String) throws -> SessionTokenSnapshot {
            let root = try temporaryDirectory()
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
            try writeSession(data, named: "\(name).jsonl", to: sessions, modified: Date())
            return try XCTUnwrap(SessionScanner.scan(dataDirectory: root).sessions.first)
        }

        XCTAssertEqual(try scan(explicit, named: "explicit"),
                       SessionTokenSnapshot(id: "explicit", cacheHitTokens: "1200", cacheMissTokens: "300", cacheHitBaselineTokens: "780", cacheMissBaselineTokens: "220", cacheBaselineAttempts: 1))
        XCTAssertEqual(try scan(legacy, named: "legacy"),
                       SessionTokenSnapshot(id: "legacy", cacheHitTokens: "1200", cacheMissTokens: "300", cacheHitBaselineTokens: "720", cacheMissBaselineTokens: "180", cacheBaselineAttempts: 1))
    }

    func testCacheLedgerMigratesV1BaselineOnceAndPreservesStaleSession() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("cache-token-ledger.json")
        try Data("""
        {"schemaVersion":1,"sessions":{"fork":{"hitTokens":"1200","missTokens":"300"},"stale":{"hitTokens":"50","missTokens":"25"}}}
        """.utf8).write(to: url)
        let loaded = LocalStateStore.load(CacheLedger.self, from: url, defaultValue: .defaultValue)
        XCTAssertEqual(loaded.condition, .valid)
        var ledger = loaded.value
        let snapshot = SessionTokenSnapshot(
            id: "fork",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: "720",
            cacheMissBaselineTokens: "180"
        )

        XCTAssertEqual(try ledger.merge([snapshot]), CacheTotals(hitTokens: 530, missTokens: 145))
        XCTAssertEqual(ledger.schemaVersion, 2)
        XCTAssertTrue(try LocalStateStore.save(ledger, to: url, previous: .valid))
        var reloaded = LocalStateStore.load(CacheLedger.self, from: url, defaultValue: .defaultValue).value
        XCTAssertEqual(try reloaded.merge([snapshot]), CacheTotals(hitTokens: 530, missTokens: 145))
        XCTAssertEqual(reloaded.sessions["fork"]?.hitBaselineTokens, "720")
        XCTAssertNil(reloaded.sessions["stale"]?.hitBaselineTokens)
    }

    func testScannerMigratesOneOldLedgerSessionBeforeUnknownLatestSessions() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date()
        let oldID = "old-ledger"
        var fork = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        fork.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        fork.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(fork, named: "\(oldID).jsonl", to: sessions, modified: now.addingTimeInterval(-3_600))
        for index in 0..<30 {
            try writeSession(
                fork,
                named: String(format: "latest-%02d.jsonl", index),
                to: sessions,
                modified: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let ledger = CacheLedger(
            schemaVersion: 1,
            sessions: [
                "aaa-stale": CacheRecord(hitTokens: "50", missTokens: "25"),
                oldID: CacheRecord(hitTokens: "1200", missTokens: "300")
            ]
        )

        let first = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)

        XCTAssertEqual(first.sessions.count, 31)
        XCTAssertEqual(first.sessions.first(where: { $0.id == oldID })?.cacheHitBaselineTokens, "720")
        XCTAssertEqual(first.sessions.filter { $0.id.hasPrefix("latest-") && $0.cacheHitBaselineTokens != nil }.count, 0)

        var migrated = ledger
        _ = try migrated.merge(first.sessions)
        XCTAssertNil(migrated.sessions["aaa-stale"]?.hitBaselineTokens)
        let second = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: migrated)
        XCTAssertNil(second.sessions.first(where: { $0.id == oldID }))
        XCTAssertEqual(second.sessions.filter { $0.id.hasPrefix("latest-") && $0.cacheHitBaselineTokens != nil }.count, 1)
    }

    func testIndeterminateBaselineDoesNotStarveNextMigratableSession() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date()
        let meta = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        var indeterminate = meta
        indeterminate.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80, limitID: nil))
        indeterminate.append(Data(repeating: 0x78, count: 4 * 1024 * 1024))
        var migratable = meta
        migratable.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        migratable.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(indeterminate, named: "a.jsonl", to: sessions, modified: now)
        try writeSession(migratable, named: "b.jsonl", to: sessions, modified: now)
        var ledger = CacheLedger(schemaVersion: 1, sessions: [
            "a": CacheRecord(hitTokens: "1200", missTokens: "300"),
            "b": CacheRecord(hitTokens: "1200", missTokens: "300")
        ])

        let first = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)
        XCTAssertNil(first.sessions.first(where: { $0.id == "a" })?.cacheHitBaselineTokens)
        XCTAssertEqual(first.sessions.first(where: { $0.id == "a" })?.cacheBaselineAttempts, 1)
        _ = try ledger.merge(first.sessions)

        let second = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)
        XCTAssertEqual(second.sessions.first(where: { $0.id == "b" })?.cacheHitBaselineTokens, "720")
        XCTAssertEqual(second.sessions.first(where: { $0.id == "b" })?.cacheBaselineAttempts, 1)
    }

    func testUnreadableHistoricalMigrationAdvancesWithoutPollutingCurrentUsage() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date()
        var fork = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        fork.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        fork.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        let unreadable = try writeSession(fork, named: "a.jsonl", to: sessions, modified: now.addingTimeInterval(-3_600))
        try writeSession(fork, named: "b.jsonl", to: sessions, modified: now.addingTimeInterval(-3_600))
        for index in 0..<30 {
            try writeSession(
                try fixture("demo"),
                named: String(format: "latest-%02d.jsonl", index),
                to: sessions,
                modified: now.addingTimeInterval(TimeInterval(index))
            )
        }
        XCTAssertEqual(chmod(unreadable.path, 0o000), 0)
        defer { chmod(unreadable.path, 0o600) }
        var ledger = CacheLedger(schemaVersion: 1, sessions: [
            "a": CacheRecord(hitTokens: "1200", missTokens: "300"),
            "b": CacheRecord(hitTokens: "1200", missTokens: "300")
        ])

        let first = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)

        XCTAssertEqual(first.state.metrics.readFailureCount, 0)
        XCTAssertEqual(first.state.classification, .complete)
        XCTAssertEqual(first.sessions.first(where: { $0.id == "a" })?.cacheHitTokens, "1200")
        XCTAssertNil(first.sessions.first(where: { $0.id == "a" })?.cacheHitBaselineTokens)
        XCTAssertEqual(first.sessions.first(where: { $0.id == "a" })?.cacheBaselineAttempts, 1)
        _ = try ledger.merge(first.sessions)

        let second = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)
        XCTAssertEqual(second.sessions.first(where: { $0.id == "b" })?.cacheHitBaselineTokens, "720")
        XCTAssertEqual(second.sessions.first(where: { $0.id == "b" })?.cacheBaselineAttempts, 1)
    }

    func testUnreadableCurrentSessionStillCountsAsReadFailure() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let unreadable = try writeSession(
            try fixture("demo"), named: "current.jsonl", to: sessions, modified: Date()
        )
        XCTAssertEqual(chmod(unreadable.path, 0o000), 0)
        defer { chmod(unreadable.path, 0o600) }

        let result = try SessionScanner.scan(dataDirectory: root)

        XCTAssertEqual(result.state.metrics.readFailureCount, 1)
        XCTAssertEqual(result.state.classification, .error)
    }

    func testSaturatedAttemptsRemainUnknownAndAreRejectedAtEveryBoundary() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        var fork = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        fork.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        fork.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(fork, named: "a.jsonl", to: sessions, modified: Date())
        try writeSession(fork, named: "b.jsonl", to: sessions, modified: Date())
        let maximum: Int64 = 10_000
        let saturated = CacheLedger(schemaVersion: 2, sessions: [
            "a": CacheRecord(hitTokens: "1200", missTokens: "300", baselineAttempts: maximum),
            "b": CacheRecord(hitTokens: "1200", missTokens: "300", baselineAttempts: maximum)
        ])

        let scanned = try SessionScanner.scan(dataDirectory: root, cacheLedger: saturated)
        XCTAssertTrue(scanned.sessions.allSatisfy {
            $0.cacheHitBaselineTokens == nil && $0.cacheBaselineAttempts == maximum
        })
        let oneAvailable = CacheLedger(schemaVersion: 2, sessions: [
            "a": CacheRecord(hitTokens: "1200", missTokens: "300", baselineAttempts: maximum),
            "b": CacheRecord(hitTokens: "1200", missTokens: "300", baselineAttempts: maximum - 1)
        ])
        let advanced = try SessionScanner.scan(dataDirectory: root, cacheLedger: oneAvailable)
        XCTAssertNil(advanced.sessions.first(where: { $0.id == "a" })?.cacheHitBaselineTokens)
        XCTAssertEqual(advanced.sessions.first(where: { $0.id == "b" })?.cacheHitBaselineTokens, "720")
        XCTAssertEqual(advanced.sessions.first(where: { $0.id == "b" })?.cacheBaselineAttempts, maximum)

        let invalid = SessionTokenSnapshot(
            id: "invalid",
            cacheHitTokens: "1",
            cacheMissTokens: "1",
            cacheBaselineAttempts: maximum + 1
        )
        var ledger = CacheLedger.defaultValue
        XCTAssertThrowsError(try ledger.merge([invalid]))
        var corrupt = CacheLedger(schemaVersion: 2, sessions: [
            "corrupt": CacheRecord(hitTokens: "1", missTokens: "1", baselineAttempts: maximum + 1)
        ])
        XCTAssertThrowsError(try corrupt.merge([]))
        let state = UsageContract.evaluate(data: try fixture("demo"), now: Date())
        let generation = "0123456789abcdef0123456789abcdef"
        XCTAssertThrowsError(try ScanWorker.encodePayload(
            UsageScanResult(state: state, sessions: [invalid]), generation: generation
        ))
        let valid = SessionTokenSnapshot(id: "valid", cacheHitTokens: "1", cacheMissTokens: "1")
        var envelope = try JSONSerialization.jsonObject(with: ScanWorker.encodePayload(
            UsageScanResult(state: state, sessions: [valid]), generation: generation
        )) as! [String: Any]
        var objects = envelope["sessions"] as! [[String: Any]]
        objects[0]["cacheBaselineAttempts"] = maximum + 1
        envelope["sessions"] = objects
        XCTAssertThrowsError(try ScanSupervisor.decodeEnvelope(
            JSONSerialization.data(withJSONObject: envelope), generation: generation
        ))
    }

    func testLegacyTokenOnlySessionUsesZeroBaseline() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        var data = tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80)
        data.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(data, named: "legacy-token-only.jsonl", to: sessions, modified: Date())

        let snapshot = try XCTUnwrap(SessionScanner.scan(dataDirectory: root).sessions.first)

        XCTAssertEqual(snapshot.cacheHitBaselineTokens, "0")
        XCTAssertEqual(snapshot.cacheMissBaselineTokens, "0")
        XCTAssertEqual(snapshot.cacheBaselineAttempts, 1)
    }

    func testOldNamedUUIDMigrationIsExcludedFromActiveTasks() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date()
        let id = "55555555-5555-5555-5555-555555555555"
        let oldName = "rollout-\(id)"
        var fork = Data("{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"11111111-1111-1111-1111-111111111111\"}}\n".utf8)
        fork.append(tokenEvent(totalInput: 1_000, cachedInput: 800, lastInput: 100, lastCached: 80))
        fork.append(tokenEvent(totalInput: 1_500, cachedInput: 1_200, lastInput: 500, lastCached: 400))
        try writeSession(fork, named: "\(oldName).jsonl", to: sessions, modified: now.addingTimeInterval(-3_600))
        for index in 0..<30 {
            try writeSession(
                tokenEvent(totalInput: 100, cachedInput: 80, lastInput: 100, lastCached: 80),
                named: String(format: "new-%02d.jsonl", index),
                to: sessions,
                modified: now.addingTimeInterval(TimeInterval(index))
            )
        }
        try Data("{\"id\":\"\(id)\",\"thread_name\":\"Old migration\"}\n".utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
        let ledger = CacheLedger(
            schemaVersion: 1,
            sessions: [oldName: CacheRecord(hitTokens: "1200", missTokens: "300")]
        )

        let result = try SessionScanner.scan(dataDirectory: root, now: now, cacheLedger: ledger)

        XCTAssertNotNil(result.sessions.first(where: { $0.id == oldName }))
        XCTAssertFalse(result.state.tasks.contains(where: { $0.id == id }))
    }

    func testReminderLedgerDeduplicatesEachResetCycle() {
        var ledger = ReminderLedger.defaultValue
        let now: Int64 = 1_786_406_400_000
        let reset = now + 3_600_000
        XCTAssertFalse(ledger.register(window: "primary", resetAt: reset, windowMinutes: 10_080, remainingPercent: 21, threshold: 20, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset, windowMinutes: 10_080, remainingPercent: 20, threshold: 20, now: now))
        XCTAssertFalse(ledger.register(window: "primary", resetAt: reset, windowMinutes: 10_080, remainingPercent: 19, threshold: 20, now: now))
        XCTAssertFalse(ledger.register(window: "primary", resetAt: reset - 3_000, windowMinutes: 10_080, remainingPercent: 19, threshold: 20, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset, windowMinutes: 10_080, remainingPercent: 10, threshold: 10, now: now))
        XCTAssertFalse(ledger.register(window: "primary", resetAt: now, windowMinutes: 10_080, remainingPercent: 10, threshold: 10, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset + 60_000, windowMinutes: 1, remainingPercent: 20, threshold: 20, now: now))
    }

    func testWorkerEnvelopeIsStrictAndSizeBounded() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = UsageContract.evaluate(data: try fixture("demo"), now: formatter.date(from: "2026-08-11T00:00:01.000Z")!)
        let generation = "0123456789abcdef0123456789abcdef"
        let session = SessionTokenSnapshot(
            id: "worker",
            cacheHitTokens: "1200",
            cacheMissTokens: "300",
            cacheHitBaselineTokens: "720",
            cacheMissBaselineTokens: "180"
        )
        let result = UsageScanResult(state: state, sessions: [session])
        let payload = try ScanWorker.encodePayload(result, generation: generation)
        XCTAssertLessThanOrEqual(payload.count, ScanWorker.maximumResultBytes)
        let decoded = try ScanSupervisor.decodeEnvelope(payload, generation: generation)
        XCTAssertEqual(decoded.state.remainingPercent, "55.0")
        XCTAssertEqual(decoded.sessions, [session])

        var envelope = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        var stateObject = envelope["state"] as! [String: Any]
        stateObject["unexpected"] = true
        envelope["state"] = stateObject
        XCTAssertThrowsError(try ScanSupervisor.decodeEnvelope(JSONSerialization.data(withJSONObject: envelope), generation: generation))
        XCTAssertThrowsError(try ScanSupervisor.decodeEnvelope(Data(repeating: 0x20, count: ScanWorker.maximumResultBytes + 1), generation: generation))

        var oversizedState = state
        oversizedState.tasks = (0..<30).reversed().map { index in
            UsageTaskSnapshot(
                id: String(format: "00000000-0000-0000-0000-%012d", index),
                name: String(repeating: "🧪", count: 500),
                observedAt: Int64(index)
            )
        }
        XCTAssertThrowsError(try ScanWorker.encodePayload(UsageScanResult(state: oversizedState, sessions: []), generation: generation))
    }

    func testScannerCapsCandidatesAndRetriesOnlyTheNewestTail() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let now = Date(timeIntervalSince1970: 1_786_406_400)
        for index in 0..<40 {
            try writeSession(try fixture("demo"), named: String(format: "session-%02d.jsonl", index), to: sessions, modified: now.addingTimeInterval(TimeInterval(index)))
        }
        let bounded = try SessionScanner.scan(dataDirectory: root, now: now.addingTimeInterval(60))
        XCTAssertEqual(bounded.sessions.count, 30)
        XCTAssertEqual(bounded.state.metrics.candidateFileCount, 30)
        let truncated = try SessionScanner.scan(dataDirectory: root, now: now.addingTimeInterval(60), maximumEntries: 2)
        XCTAssertLessThanOrEqual(truncated.sessions.count, 2)
        XCTAssertGreaterThan(truncated.state.metrics.readFailureCount, 0)

        let retryRoot = try temporaryDirectory()
        let retrySessions = retryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: retrySessions, withIntermediateDirectories: false)
        var oldEvent = try fixture("demo")
        oldEvent.append(Data(repeating: 0x78, count: 300_000))
        oldEvent.append(0x0a)
        try writeSession(oldEvent, named: "retry.jsonl", to: retrySessions, modified: now)
        let retried = try SessionScanner.scan(dataDirectory: retryRoot, now: now)
        XCTAssertEqual(retried.state.remainingPercent, "55.0")
    }

    func testWorkerModeIsSilentReadOnlyAndSupervisorRecovers() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let source = try writeSession(try fixture("demo"), named: "demo.jsonl", to: sessions, modified: Date())
        let sourceBytes = try Data(contentsOf: source)
        let generation = "abcdef0123456789abcdef0123456789"
        let channel = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageWidget-scan-\(generation)", isDirectory: true)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: channel) }
        let output = channel.appendingPathComponent("result.json")
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--scan-worker"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_WIDGET_DATA_DIRECTORY"] = root.path
        environment["CODEX_WIDGET_RESULT_PATH"] = output.path
        environment["CODEX_WIDGET_GENERATION"] = generation
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(standardOutput.fileHandleForReading.readDataToEndOfFile().count, 0)
        XCTAssertEqual(standardError.fileHandleForReading.readDataToEndOfFile().count, 0)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try ScanSupervisor.decodeEnvelope(Data(contentsOf: output), generation: generation).state.remainingPercent, "55.0")

        let blocker = root.appendingPathComponent("blocker.sh")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: blocker)
        chmod(blocker.path, 0o700)
        XCTAssertThrowsError(try ScanSupervisor.scan(executableURL: blocker, dataDirectory: root, timeout: 0.05))
        XCTAssertEqual(try ScanSupervisor.scan(executableURL: executable, dataDirectory: root).state.remainingPercent, "55.0")
    }

    func testOrphanCleanupOnlyRemovesOwnedExpiredScanDirectories() throws {
        let root = try temporaryDirectory()
        let old = root.appendingPathComponent("CodexUsageWidget-scan-11111111111111111111111111111111", isDirectory: true)
        let fresh = root.appendingPathComponent("CodexUsageWidget-scan-22222222222222222222222222222222", isDirectory: true)
        let unrelated = root.appendingPathComponent("CodexUsageWidget-scan-not-ours", isDirectory: true)
        for url in [old, fresh, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: old.path)
        ScanSupervisor.cleanupOrphans(in: root, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testWorkerPerformanceAndResourceStability() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let emptyRoot = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: emptyRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: false
        )
        func duration(for root: URL) throws -> TimeInterval {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try ScanSupervisor.scan(executableURL: executable, dataDirectory: root)
            return ProcessInfo.processInfo.systemUptime - started
        }

        let coldDurations = try (0..<20).map { _ in try duration(for: emptyRoot) }
        XCTAssertLessThan(percentile95(coldDurations), 0.300)

        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let demo = try fixture("demo")
        var maximumTail = Data(repeating: 0x20, count: 256 * 1024 - demo.count - 1)
        maximumTail.append(0x0a)
        maximumTail.append(demo)
        let now = Date()
        for index in 0..<30 {
            try writeSession(
                maximumTail,
                named: String(format: "maximum-%02d.jsonl", index),
                to: sessions,
                modified: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let temporaryBefore = scanTemporaryDirectories()
        var refreshDurations: [TimeInterval] = []
        for _ in 0..<10 { refreshDurations.append(try duration(for: root)) }
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let memoryBefore = try resourceHighWaterBytes()
        for _ in 10..<120 { refreshDurations.append(try duration(for: root)) }
        let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let memoryAfter = try resourceHighWaterBytes()

        XCTAssertLessThan(percentile95(refreshDurations), 2.0)
        XCTAssertLessThanOrEqual(descriptorsAfter - descriptorsBefore, 8)
        XCTAssertLessThanOrEqual(memoryAfter - memoryBefore, 20 * 1024 * 1024)
        XCTAssertTrue(scanTemporaryDirectories().subtracting(temporaryBefore).isEmpty)

        let generation = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let channel = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageWidget-scan-\(generation)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: channel,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: channel) }
        let timedWorker = Process()
        timedWorker.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        timedWorker.arguments = ["-l", executable.path, "--scan-worker"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_WIDGET_DATA_DIRECTORY"] = root.path
        environment["CODEX_WIDGET_RESULT_PATH"] = channel.appendingPathComponent("result.json").path
        environment["CODEX_WIDGET_GENERATION"] = generation
        timedWorker.environment = environment
        timedWorker.standardOutput = FileHandle.nullDevice
        let diagnostics = Pipe()
        timedWorker.standardError = diagnostics
        try timedWorker.run()
        timedWorker.waitUntilExit()
        let diagnosticText = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let peakLine = try XCTUnwrap(diagnosticText.split(whereSeparator: { $0.isNewline })
            .first { $0.contains("maximum resident set size") })
        let peakBytes = try XCTUnwrap(Int64(peakLine.split(whereSeparator: { $0.isWhitespace }).first ?? ""))
        XCTAssertEqual(timedWorker.terminationStatus, 0)
        XCTAssertLessThanOrEqual(peakBytes, 128 * 1024 * 1024)
    }
}
