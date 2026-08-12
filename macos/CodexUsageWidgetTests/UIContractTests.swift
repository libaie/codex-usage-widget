import AppKit
import Foundation
import XCTest
@testable import CodexUsageWidget

final class UIContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixedNow: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: "2026-08-11T00:00:01.000Z")!
    }

    private func demoState() throws -> NormalizedUsageState {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures/contract/v1/inputs/demo.jsonl"))
        return UsageContract.evaluate(data: data, now: fixedNow)
    }

    func testFiveLanguagePacksAreStrictAndFormatPlaceholders() throws {
        let localization = try WidgetLocalization.load(directory: repositoryRoot.appendingPathComponent("locales"))
        XCTAssertEqual(localization.packs.count, 5)
        XCTAssertEqual(localization.requiredKeys.count, 118)
        XCTAssertEqual(localization.resolve(preferred: ["fr-FR", "zh-TW"]), "zh-TW")
        XCTAssertEqual(localization.resolve(preferred: ["fr-FR"]), "en-US")
        XCTAssertEqual(localization.pack(code: "en-US").text("cache.value", ["42", "95.4"]), "42 (95.4%)")
        XCTAssertEqual(localization.pack(code: "zh-CN").text("reminder.title", ["20"]), "剩余用量 20%")
    }

    func testThemeCatalogMatchesTheSharedEightThemes() throws {
        let catalog = try WidgetThemeCatalog.load(
            from: repositoryRoot.appendingPathComponent("fixtures/contract/v1/theme-catalog.json"))
        XCTAssertEqual(catalog.themes.map(\.id), ["glacier", "nebula", "ocean", "sakura", "aurora", "mica", "sunset", "lime"])
        XCTAssertEqual(catalog.themes.first?.start, "#7BFFE0")
        XCTAssertEqual(catalog.themes.last?.end, "#7DDB66")
        XCTAssertEqual(catalog.warning, "#FFC857")
        XCTAssertEqual(catalog.critical, "#FF5E6C")
    }

    func testWidgetGeometrySnapsAndKeepsDetailsInsideTheVisibleFrame() {
        let visible = CGRect(x: -1920, y: -120, width: 1920, height: 1000)
        let left = WidgetGeometry.snappedFrame(
            CGRect(x: -1910, y: 300, width: 100, height: 100), visibleFrame: visible)
        XCTAssertEqual(left.frame.minX, -1921)
        XCTAssertEqual(left.edge, .left)

        let top = WidgetGeometry.snappedFrame(
            CGRect(x: -1000, y: 770, width: 100, height: 100), visibleFrame: visible)
        XCTAssertEqual(top.frame.minY, 781)
        XCTAssertEqual(top.edge, .top)

        let rightWidget = CGRect(x: -110, y: 500, width: 100, height: 100)
        let detail = WidgetGeometry.detailPlacement(widgetFrame: rightWidget, size: CGSize(width: 310, height: 506), visibleFrame: visible)
        XCTAssertTrue(detail.opensLeft)
        XCTAssertGreaterThanOrEqual(detail.frame.minX, visible.minX + 8)
        XCTAssertLessThanOrEqual(detail.frame.maxX, visible.maxX - 8)
        XCTAssertGreaterThanOrEqual(detail.frame.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(detail.frame.maxY, visible.maxY - 8)
    }

    func testPresentationDistinguishesAllObservationStates() throws {
        let limit = UsageLimitSnapshot(name: "primary", remainingPercent: "55.0", resetAt: 4_102_441_200_000, windowMinutes: 300)
        var state = try demoState()
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: limit, stale: false, demo: true, now: fixedNow).statusKey, "status.sufficient")

        state.classification = .partial
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: limit, stale: false, demo: false, now: fixedNow).statusKey, "status.partial")
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: limit, stale: true, demo: false, now: fixedNow).statusKey, "status.stale")
        state.classification = .unsupported
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: nil, stale: false, demo: false, now: fixedNow).statusKey, "status.unsupported")
        state.classification = .error
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: nil, stale: false, demo: false, now: fixedNow).statusKey, "status.error")
        state.classification = .empty
        XCTAssertEqual(WidgetPresentation.make(state: state, limit: nil, stale: false, demo: false, now: fixedNow).statusKey, "status.noData")
    }

    func testLimitCountdownAndFreshnessUseLocalizedRules() throws {
        let localization = try WidgetLocalization.load(directory: repositoryRoot.appendingPathComponent("locales"))
        let english = localization.pack(code: "en-US")
        XCTAssertEqual(WidgetFormatter.limitWindow(minutes: 10_080, language: english), "7 days")
        XCTAssertEqual(WidgetFormatter.limitWindow(minutes: 300, language: english), "5 hours")
        XCTAssertEqual(WidgetFormatter.countdown(resetAt: fixedNow.addingTimeInterval(2 * 86_400 + 3 * 3_600), now: fixedNow, language: english), "Resets in 2 days 3 hours")
        XCTAssertEqual(WidgetFormatter.countdown(resetAt: fixedNow.addingTimeInterval(61), now: fixedNow, language: english), "Resets in 2 minutes")
        XCTAssertEqual(WidgetFormatter.countdown(resetAt: fixedNow, now: fixedNow, language: english), "Waiting for a new cycle")
        XCTAssertEqual(WidgetFormatter.observationKey(observedAt: fixedNow.addingTimeInterval(-60), now: fixedNow), "observed.recent")
        XCTAssertEqual(WidgetFormatter.observationKey(observedAt: fixedNow.addingTimeInterval(-1_801), now: fixedNow), "observed.older")
    }

    func testScannerPreservesSelectedLimitForTheUIEnvelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageWidget-ui-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures/contract/v1/inputs/demo.jsonl"))
            .write(to: sessions.appendingPathComponent("demo.jsonl"))

        let result = try SessionScanner.scan(dataDirectory: root, now: fixedNow)
        XCTAssertEqual(result.selectedLimit, UsageLimitSnapshot(
            name: "primary", remainingPercent: "55.0", resetAt: 4_102_441_200_000, windowMinutes: 300))
        let generation = "0123456789abcdef0123456789abcdef"
        let decoded = try ScanSupervisor.decodeEnvelope(
            ScanWorker.encodePayload(result, generation: generation), generation: generation)
        XCTAssertEqual(decoded.selectedLimit, result.selectedLimit)
    }

    func testRefreshResolvesTheDataDirectoryAgainAfterRuntimeMigration() throws {
        let temporary = FileManager.default.temporaryDirectory
        let stateDirectory = temporary.appendingPathComponent("CodexUsageWidget-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let oldDirectory = temporary.appendingPathComponent("CodexUsageWidget-old-\(UUID().uuidString)")
        let migratedDirectory = temporary.appendingPathComponent("CodexUsageWidget-migrated-\(UUID().uuidString)")
        var resolvedDirectories = [oldDirectory, migratedDirectory]
        var savedPaths: [String?] = []
        let scanResult = try WidgetDemo.load(
            fixtureURL: repositoryRoot.appendingPathComponent("fixtures/contract/v1/inputs/demo.jsonl"),
            now: fixedNow
        )
        let scanFinished = expectation(description: "scan uses migrated directory")
        let model = try WidgetModel(
            demo: false,
            stateDirectory: stateDirectory,
            resolveDataDirectory: { savedPath in
                savedPaths.append(savedPath)
                return resolvedDirectories.removeFirst()
            },
            scanDataDirectory: { _, directory in
                XCTAssertEqual(directory, migratedDirectory)
                scanFinished.fulfill()
                return scanResult
            }
        )

        XCTAssertEqual(model.dataDirectory, oldDirectory)
        model.refresh()

        wait(for: [scanFinished], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while model.result == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.dataDirectory, migratedDirectory)
        XCTAssertEqual(savedPaths, [String?](repeating: nil, count: 2))
        XCTAssertEqual(model.result?.state.remainingPercent, scanResult.state.remainingPercent)
    }

    func testHoverPinDragAndEscapeShareOneInteractionStateMachine() {
        var interaction = WidgetInteractionState()
        interaction.pointerEnteredRing(at: 0)
        XCTAssertFalse(interaction.advance(to: 0.179))
        XCTAssertTrue(interaction.advance(to: 0.180))
        XCTAssertEqual(interaction.detailMode, .temporary)

        interaction.pointerExitedRing(at: 0.200)
        interaction.pointerEnteredDetail(at: 0.300)
        XCTAssertFalse(interaction.advance(to: 0.450))
        XCTAssertEqual(interaction.detailMode, .temporary)
        interaction.pointerExitedDetail(at: 0.500)
        XCTAssertFalse(interaction.advance(to: 0.749))
        XCTAssertTrue(interaction.advance(to: 0.750))
        XCTAssertEqual(interaction.detailMode, .closed)

        interaction.pointerEnteredRing(at: 1)
        interaction.pointerDown(at: CGPoint(x: 10, y: 10))
        XCTAssertFalse(interaction.pointerMoved(to: CGPoint(x: 13, y: 10)))
        XCTAssertTrue(interaction.pointerMoved(to: CGPoint(x: 15, y: 10)))
        XCTAssertTrue(interaction.pointerUp())
        XCTAssertEqual(interaction.detailMode, .closed)

        interaction.togglePinned()
        XCTAssertEqual(interaction.detailMode, .pinned)
        interaction.escape()
        XCTAssertEqual(interaction.detailMode, .closed)
    }

    func testDemoUsesTheReviewedFixtureWithoutASeparateParser() throws {
        let result = try WidgetDemo.load(
            fixtureURL: repositoryRoot.appendingPathComponent("fixtures/contract/v1/inputs/demo.jsonl"),
            now: fixedNow
        )
        XCTAssertEqual(result.state.remainingPercent, "55.0")
        XCTAssertEqual(result.selectedLimit?.windowMinutes, 300)
        XCTAssertEqual(result.state.observedAt, Int64(fixedNow.addingTimeInterval(-60).timeIntervalSince1970 * 1_000))
        XCTAssertEqual(result.selectedLimit?.resetAt, Int64(fixedNow.addingTimeInterval(5 * 3_600 + 19 * 60).timeIntervalSince1970 * 1_000))
        XCTAssertTrue(result.sessions.isEmpty)
    }
}
