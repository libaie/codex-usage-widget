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

    func testReviewedContractFixtures() throws {
        let document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: contractRoot.appendingPathComponent("expected-state.json"))) as! [String: Any]
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document["sourceKind"] as? String, "local-session-observation")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for fixture in document["cases"] as! [[String: Any]] {
            let identifier = fixture["id"] as! String
            let input = contractRoot.appendingPathComponent(fixture["input"] as! String)
            let now = formatter.date(from: fixture["nowUtc"] as! String)!
            let actual = try UsageContract.evaluate(fileURL: input, now: now).jsonObject()
            let metrics = actual["metrics"] as! [String: Any]
            for (key, expected) in fixture["expected"] as! [String: Any] {
                let got = actual[key] ?? metrics[key]
                if expected is NSNull {
                    XCTAssertTrue(got is NSNull, "[contract/\(identifier)] expected \(key)=null, got \(String(describing: got))")
                } else if let number = expected as? NSNumber {
                    XCTAssertEqual(got as? NSNumber, number, "[contract/\(identifier)] \(key)")
                } else {
                    XCTAssertEqual(got as? String, expected as? String, "[contract/\(identifier)] \(key)")
                }
            }
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
        let demo = try Data(contentsOf: contractRoot.appendingPathComponent("inputs/demo.jsonl"))
        try demo.write(to: saved.appendingPathComponent("sessions/demo.jsonl"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = try SessionScanner.scan(dataDirectory: saved, now: formatter.date(from: "2026-08-11T00:00:01.000Z")!)
        XCTAssertEqual(state.remainingPercent, "55.0")
        XCTAssertEqual(state.metrics.candidateFileCount, 1)
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
}
