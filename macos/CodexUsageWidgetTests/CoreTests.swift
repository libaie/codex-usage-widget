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

    func testReviewedContractFixtures() throws {
        let document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractRoot.appendingPathComponent("expected-state.json"))) as! [String: Any]
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document["sourceKind"] as? String, "local-session-observation")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let cases = document["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 15)
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
            SessionTokenSnapshot(id: $0.id, cacheHitTokens: "1", cacheMissTokens: "1")
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
    }

    func testReminderLedgerDeduplicatesEachResetCycle() {
        var ledger = ReminderLedger.defaultValue
        let now: Int64 = 1_786_406_400_000
        let reset = now + 3_600_000
        XCTAssertFalse(ledger.register(window: "primary", resetAt: reset, remainingPercent: 21, threshold: 20, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset, remainingPercent: 20, threshold: 20, now: now))
        XCTAssertFalse(ledger.register(window: "primary", resetAt: reset, remainingPercent: 19, threshold: 20, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset, remainingPercent: 10, threshold: 10, now: now))
        XCTAssertFalse(ledger.register(window: "primary", resetAt: now, remainingPercent: 10, threshold: 10, now: now))
        XCTAssertTrue(ledger.register(window: "primary", resetAt: reset + 1, remainingPercent: 20, threshold: 20, now: now))
    }

    func testWorkerEnvelopeIsStrictAndSizeBounded() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = UsageContract.evaluate(data: try fixture("demo"), now: formatter.date(from: "2026-08-11T00:00:01.000Z")!)
        let generation = "0123456789abcdef0123456789abcdef"
        let result = UsageScanResult(state: state, sessions: [])
        let payload = try ScanWorker.encodePayload(result, generation: generation)
        XCTAssertLessThanOrEqual(payload.count, ScanWorker.maximumResultBytes)
        XCTAssertEqual(try ScanSupervisor.decodeEnvelope(payload, generation: generation).state.remainingPercent, "55.0")

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
