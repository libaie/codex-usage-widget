import AppKit
import CoreFoundation
import Foundation
import QuartzCore
import SwiftUI
import UserNotifications

enum WidgetUIError: Error { case invalidResource }

struct WidgetLanguagePack {
    let code: String
    let nativeName: String
    let culture: String
    let strings: [String: String]

    func text(_ key: String, _ arguments: [String] = []) -> String {
        var result = strings[key] ?? ""
        for (index, argument) in arguments.enumerated() {
            let expression = try! NSRegularExpression(pattern: "\\{\(index)(?::[^{}]*)?\\}")
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: argument)
            )
        }
        return result
    }
}

struct WidgetLocalization {
    static let codes = ["zh-CN", "zh-TW", "en-US", "ja-JP", "ko-KR"]
    let packs: [String: WidgetLanguagePack]
    let requiredKeys: Set<String>

    static func load(directory: URL) throws -> WidgetLocalization {
        var loaded: [String: WidgetLanguagePack] = [:]
        var canonicalKeys: Set<String>?
        var canonicalPlaceholders: [String: [String]] = [:]
        for code in codes {
            let pack = try loadPack(from: directory.appendingPathComponent("\(code).json"), expectedCode: code)
            let keys = Set(pack.strings.keys)
            if code == "en-US" {
                guard keys.count == 118 else { throw WidgetUIError.invalidResource }
                canonicalKeys = keys
                canonicalPlaceholders = pack.strings.mapValues { placeholders($0) }
            }
            loaded[code] = pack
        }
        guard let requiredKeys = canonicalKeys else { throw WidgetUIError.invalidResource }
        for pack in loaded.values {
            guard Set(pack.strings.keys) == requiredKeys else { throw WidgetUIError.invalidResource }
            for key in requiredKeys where placeholders(pack.strings[key] ?? "") != (canonicalPlaceholders[key] ?? []) {
                throw WidgetUIError.invalidResource
            }
        }
        return WidgetLocalization(packs: loaded, requiredKeys: requiredKeys)
    }

    func resolve(preferred: [String]) -> String {
        for raw in preferred {
            if packs[raw] != nil { return raw }
            let code = raw.lowercased()
            let mapped: String?
            if code.hasPrefix("zh-hans") || code.hasPrefix("zh-cn") { mapped = "zh-CN" }
            else if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") { mapped = "zh-TW" }
            else if code.hasPrefix("ja") { mapped = "ja-JP" }
            else if code.hasPrefix("ko") { mapped = "ko-KR" }
            else if code.hasPrefix("en") { mapped = "en-US" }
            else { mapped = nil }
            if let mapped, packs[mapped] != nil { return mapped }
        }
        return "en-US"
    }

    func pack(code: String) -> WidgetLanguagePack { packs[code] ?? packs["en-US"]! }

    private static func loadPack(from url: URL, expectedCode: String) throws -> WidgetLanguagePack {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 256 * 1024 else { throw WidgetUIError.invalidResource }
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["code", "nativeName", "culture", "strings"]),
              root["code"] as? String == expectedCode,
              root["culture"] as? String == expectedCode,
              let nativeName = root["nativeName"] as? String, (1...64).contains(nativeName.count),
              let rawStrings = root["strings"] as? [String: Any]
        else { throw WidgetUIError.invalidResource }
        var strings: [String: String] = [:]
        for (key, rawValue) in rawStrings {
            guard let value = rawValue as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 1_000 else { throw WidgetUIError.invalidResource }
            strings[key] = value
        }
        guard let title = strings["app.title"], title.count < 64 else { throw WidgetUIError.invalidResource }
        return WidgetLanguagePack(code: expectedCode, nativeName: nativeName, culture: expectedCode, strings: strings)
    }

    private static func placeholders(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\{([0-9]+)(?::[^{}]*)?\}"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }.sorted()
    }
}

struct WidgetTheme: Equatable {
    let id: String
    let nameKey: String
    let start: String
    let end: String
}

struct WidgetThemeCatalog {
    let themes: [WidgetTheme]
    let warning: String
    let critical: String

    static func load(from url: URL) throws -> WidgetThemeCatalog {
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["schemaVersion", "themes", "status"]),
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              let rawThemes = root["themes"] as? [[String: Any]], rawThemes.count == 8,
              let status = root["status"] as? [String: Any], Set(status.keys) == Set(["warning", "critical"]),
              let warning = status["warning"] as? String, validColor(warning),
              let critical = status["critical"] as? String, validColor(critical)
        else { throw WidgetUIError.invalidResource }
        let expectedIDs = ["glacier", "nebula", "ocean", "sakura", "aurora", "mica", "sunset", "lime"]
        let themes = try rawThemes.enumerated().map { index, raw -> WidgetTheme in
            guard Set(raw.keys) == Set(["id", "nameKey", "start", "end"]),
                  let id = raw["id"] as? String, id == expectedIDs[index],
                  let nameKey = raw["nameKey"] as? String, nameKey == "theme.\(id)",
                  let start = raw["start"] as? String, validColor(start),
                  let end = raw["end"] as? String, validColor(end)
            else { throw WidgetUIError.invalidResource }
            return WidgetTheme(id: id, nameKey: nameKey, start: start, end: end)
        }
        return WidgetThemeCatalog(themes: themes, warning: warning, critical: critical)
    }

    private static func validColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil
    }
}

enum WidgetEdge: Equatable { case left, right, top, bottom }
struct SnappedWidgetFrame { let frame: CGRect; let edge: WidgetEdge? }
struct DetailPlacement { let frame: CGRect; let opensLeft: Bool }

enum WidgetGeometry {
    static func snappedFrame(
        _ frame: CGRect,
        visibleFrame: CGRect,
        visibleSize: CGFloat = 82,
        threshold: CGFloat = 28,
        edgeInset: CGFloat = 8
    ) -> SnappedWidgetFrame {
        let horizontalInset = (frame.width - visibleSize) / 2
        let verticalInset = (frame.height - visibleSize) / 2
        let distances: [(WidgetEdge, CGFloat)] = [
            (.left, abs(frame.minX + horizontalInset - visibleFrame.minX)),
            (.right, abs(frame.maxX - horizontalInset - visibleFrame.maxX)),
            (.top, abs(frame.maxY - verticalInset - visibleFrame.maxY)),
            (.bottom, abs(frame.minY + verticalInset - visibleFrame.minY))
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else {
            return SnappedWidgetFrame(frame: frame, edge: nil)
        }
        var origin = frame.origin
        switch nearest.0 {
        case .left: origin.x = visibleFrame.minX + edgeInset - horizontalInset
        case .right: origin.x = visibleFrame.maxX - edgeInset - frame.width + horizontalInset
        case .top: origin.y = visibleFrame.maxY - edgeInset - frame.height + verticalInset
        case .bottom: origin.y = visibleFrame.minY + edgeInset - verticalInset
        }
        return SnappedWidgetFrame(frame: CGRect(origin: origin, size: frame.size), edge: nearest.0)
    }

    static func detailPlacement(widgetFrame: CGRect, size: CGSize, visibleFrame: CGRect) -> DetailPlacement {
        let width = min(size.width, max(1, visibleFrame.width - 16))
        let height = min(size.height, max(1, visibleFrame.height - 16))
        let rightSpace = visibleFrame.maxX - widgetFrame.maxX
        let leftSpace = widgetFrame.minX - visibleFrame.minX
        let opensLeft = rightSpace < width + 12 && leftSpace > rightSpace
        let preferredX = opensLeft ? widgetFrame.minX - 12 - width : widgetFrame.maxX + 12
        let x = max(visibleFrame.minX + 8, min(visibleFrame.maxX - 8 - width, preferredX))
        let preferredY = widgetFrame.maxY - height
        let y = max(visibleFrame.minY + 8, min(visibleFrame.maxY - 8 - height, preferredY))
        return DetailPlacement(frame: CGRect(x: x, y: y, width: width, height: height), opensLeft: opensLeft)
    }
}

enum WidgetFormatter {
    static func limitWindow(minutes: Int64?, language: WidgetLanguagePack) -> String {
        guard let minutes, minutes >= 0 else { return language.text("limit.unknown") }
        if minutes % 1_440 == 0 { return language.text("limit.days", [String(minutes / 1_440)]) }
        if minutes % 60 == 0 { return language.text("limit.hours", [String(minutes / 60)]) }
        return language.text("limit.minutes", [String(minutes)])
    }

    static func countdown(resetAt: Date, now: Date, language: WidgetLanguagePack) -> String {
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return language.text("countdown.waiting") }
        if seconds >= 86_400 {
            let days = Int(seconds / 86_400)
            let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
            return language.text("countdown.daysHours", [String(days), String(hours)])
        }
        if seconds >= 3_600 {
            let hours = Int(seconds / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            return language.text("countdown.hoursMinutes", [String(hours), String(minutes)])
        }
        return language.text("countdown.minutes", [String(max(1, Int(ceil(seconds / 60))))])
    }

    static func observationKey(observedAt: Date, now: Date) -> String {
        max(0, now.timeIntervalSince(observedAt)) <= 30 * 60 ? "observed.recent" : "observed.older"
    }

    static func compactToken(_ raw: String?, language: WidgetLanguagePack) -> String {
        guard let raw, let value = Int64(raw), value >= 0 else { return "—" }
        let culture = Locale(identifier: language.culture)
        func decimal(_ divisor: Int64, _ format: String) -> String {
            let number = Double(value) / Double(divisor)
            let formatter = NumberFormatter()
            formatter.locale = culture
            formatter.maximumFractionDigits = number >= 1_000 ? 0 : 1
            formatter.minimumFractionDigits = 0
            return language.text(format, [formatter.string(from: NSNumber(value: number)) ?? String(number)])
        }
        if language.code == "en-US" {
            if value >= 1_000_000_000 { return decimal(1_000_000_000, "number.billion") }
            if value >= 1_000_000 { return decimal(1_000_000, "number.million") }
            if value >= 1_000 { return decimal(1_000, "number.thousand") }
        } else {
            if value >= 100_000_000 { return decimal(100_000_000, "number.hundredMillion") }
            if value >= 10_000 { return decimal(10_000, "number.tenThousand") }
        }
        let formatter = NumberFormatter()
        formatter.locale = culture
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? raw
    }
}

struct WidgetPresentation {
    let ringPercent: Double?
    let statusKey: String
    let demo: Bool

    static func make(
        state: NormalizedUsageState?,
        limit: UsageLimitSnapshot?,
        stale: Bool,
        demo: Bool,
        now: Date
    ) -> WidgetPresentation {
        let percent = state?.remainingPercent.flatMap { Double($0) }
        let statusKey: String
        if stale { statusKey = "status.stale" }
        else if let state {
            switch state.classification {
            case .partial: statusKey = "status.partial"
            case .unsupported: statusKey = "status.unsupported"
            case .error: statusKey = "status.error"
            case .empty: statusKey = "status.noData"
            case .complete:
                guard limit != nil, let percent else {
                    return WidgetPresentation(ringPercent: nil, statusKey: "status.waiting", demo: demo)
                }
                if percent <= 10 { statusKey = "status.critical" }
                else if percent <= 20 { statusKey = "status.attention" }
                else { statusKey = "status.sufficient" }
            }
        } else { statusKey = "status.unavailable" }
        return WidgetPresentation(ringPercent: percent, statusKey: statusKey, demo: demo)
    }
}

enum WidgetDetailMode: Equatable { case closed, temporary, pinned }

struct WidgetInteractionState {
    private(set) var detailMode: WidgetDetailMode = .closed
    private var ringInside = false
    private var detailInside = false
    private var pointerStart: CGPoint?
    private var dragging = false
    private var showAt: TimeInterval?
    private var closeAt: TimeInterval?

    var nextDeadline: TimeInterval? { [showAt, closeAt].compactMap { $0 }.min() }

    mutating func pointerEnteredRing(at now: TimeInterval) {
        ringInside = true
        closeAt = nil
        if detailMode == .closed, !dragging { showAt = now + 0.180 }
    }

    mutating func pointerExitedRing(at now: TimeInterval) {
        ringInside = false
        showAt = nil
        if detailMode == .temporary, !detailInside { closeAt = now + 0.250 }
    }

    mutating func pointerEnteredDetail(at now: TimeInterval) {
        detailInside = true
        closeAt = nil
    }

    mutating func pointerExitedDetail(at now: TimeInterval) {
        detailInside = false
        if detailMode == .temporary, !ringInside { closeAt = now + 0.250 }
    }

    mutating func pointerDown(at point: CGPoint) {
        pointerStart = point
        dragging = false
        showAt = nil
    }

    mutating func pointerMoved(to point: CGPoint) -> Bool {
        guard let pointerStart else { return false }
        if !dragging, hypot(point.x - pointerStart.x, point.y - pointerStart.y) > 4 {
            dragging = true
            showAt = nil
            closeAt = nil
            if detailMode == .temporary { detailMode = .closed }
        }
        return dragging
    }

    mutating func pointerUp() -> Bool {
        let wasDragging = dragging
        pointerStart = nil
        dragging = false
        return wasDragging
    }

    mutating func togglePinned() {
        detailMode = detailMode == .pinned ? .closed : .pinned
        showAt = nil
        closeAt = nil
    }

    mutating func escape() {
        detailMode = .closed
        showAt = nil
        closeAt = nil
    }

    mutating func advance(to now: TimeInterval) -> Bool {
        var changed = false
        if let deadline = showAt, deadline <= now {
            showAt = nil
            if ringInside, !dragging, detailMode == .closed {
                detailMode = .temporary
                changed = true
            }
        }
        if let deadline = closeAt, deadline <= now {
            closeAt = nil
            if !ringInside, !detailInside, detailMode == .temporary {
                detailMode = .closed
                changed = true
            }
        }
        return changed
    }
}

enum WidgetDemo {
    static func load(fixtureURL: URL, now: Date) throws -> UsageScanResult {
        var state = UsageContract.evaluate(data: try Data(contentsOf: fixtureURL), now: now)
        // ponytail: keep the fixture far-future for parser tests and rebase only the demo presentation dates.
        state.observedAt = Int64((now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000).rounded())
        state.selectedResetAt = Int64((now.addingTimeInterval(5 * 3_600 + 19 * 60).timeIntervalSince1970 * 1_000).rounded())
        return UsageScanResult(state: state, sessions: [])
    }
}

final class WidgetModel: ObservableObject {
    let localization: WidgetLocalization
    let catalog: WidgetThemeCatalog
    let demo: Bool

    @Published private(set) var result: UsageScanResult?
    @Published private(set) var stale = false
    @Published private(set) var diagnosticKey: String?
    @Published private(set) var languageCode: String
    @Published private(set) var themeIndex: Int
    @Published private(set) var cacheTotals: CacheTotals?
    @Published var selectedTaskID: String?
    @Published private(set) var now = Date()

    private var preferences: WidgetPreferences
    private var preferenceCondition: StorageCondition
    private var cacheLedger: CacheLedger
    private var cacheCondition: StorageCondition
    private var reminderLedger: ReminderLedger
    private var reminderCondition: StorageCondition
    private var scanInFlight = false
    private var refreshPending = false
    private var scanGeneration = 0
    private var refreshTimer: Timer?
    private var taskHideWorkItem: DispatchWorkItem?
    private(set) var dataDirectory: URL?
    var remindersEnabled = false
    var onReminder: ((UsageLimitSnapshot, Int) -> Void)?

    private var preferenceURL: URL { ApplicationPaths.supportDirectory.appendingPathComponent("preferences.json") }
    private var cacheURL: URL { ApplicationPaths.supportDirectory.appendingPathComponent("cache-token-ledger.json") }
    private var reminderURL: URL { ApplicationPaths.supportDirectory.appendingPathComponent("reminders.json") }

    init(demo: Bool, bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else { throw WidgetUIError.invalidResource }
        localization = try WidgetLocalization.load(directory: resources.appendingPathComponent("locales", isDirectory: true))
        catalog = try WidgetThemeCatalog.load(from: resources.appendingPathComponent("theme-catalog.json"))
        self.demo = demo

        let loadedPreferences = demo
            ? LoadedState(condition: .missing, value: WidgetPreferences.defaultValue)
            : LocalStateStore.load(WidgetPreferences.self, from: ApplicationPaths.supportDirectory.appendingPathComponent("preferences.json"), defaultValue: .defaultValue)
        var initialPreferences = loadedPreferences.value
        if loadedPreferences.condition != .valid {
            initialPreferences.language = localization.resolve(preferred: Locale.preferredLanguages)
            initialPreferences.theme = 7
        }
        preferences = initialPreferences
        preferenceCondition = loadedPreferences.condition
        languageCode = initialPreferences.language
        themeIndex = min(max(0, initialPreferences.theme), catalog.themes.count - 1)

        let loadedCache = demo
            ? LoadedState(condition: .missing, value: CacheLedger.defaultValue)
            : LocalStateStore.load(CacheLedger.self, from: ApplicationPaths.supportDirectory.appendingPathComponent("cache-token-ledger.json"), defaultValue: .defaultValue)
        cacheLedger = loadedCache.value
        cacheCondition = loadedCache.condition
        cacheTotals = loadedCache.value.totals()

        let loadedReminders = demo
            ? LoadedState(condition: .missing, value: ReminderLedger.defaultValue)
            : LocalStateStore.load(ReminderLedger.self, from: ApplicationPaths.supportDirectory.appendingPathComponent("reminders.json"), defaultValue: .defaultValue)
        reminderLedger = loadedReminders.value
        reminderCondition = loadedReminders.condition

        dataDirectory = demo ? nil : DataDirectoryResolver.resolve(savedPath: initialPreferences.codexDataDirectory)
        if demo {
            let demoResult = try WidgetDemo.load(fixtureURL: resources.appendingPathComponent("demo.jsonl"), now: now)
            result = demoResult
            if let hit = demoResult.state.cacheHitTokens.flatMap(Int64.init),
               let miss = demoResult.state.cacheMissTokens.flatMap(Int64.init) {
                cacheTotals = CacheTotals(hitTokens: hit, missTokens: miss)
            }
            diagnosticKey = nil
        } else {
            result = nil
            diagnosticKey = dataDirectory == nil ? "diagnostic.missingDirectory" : "diagnostic.unavailable"
        }
    }

    deinit { refreshTimer?.invalidate() }

    var language: WidgetLanguagePack { localization.pack(code: languageCode) }
    var presentation: WidgetPresentation {
        WidgetPresentation.make(state: result?.state, limit: result?.selectedLimit, stale: stale, demo: demo, now: now)
    }
    var theme: WidgetTheme { catalog.themes[themeIndex] }
    var storedOrigin: CGPoint? {
        guard let left = preferences.left, let top = preferences.top else { return nil }
        return CGPoint(x: left, y: top)
    }
    var storedScreen: String? { preferences.screen }
    var hasInvalidState: Bool {
        preferenceCondition == .invalid || cacheCondition == .invalid || reminderCondition == .invalid
    }
    var accentHexes: (String, String) {
        if let percent = presentation.ringPercent, percent <= 10 { return (catalog.critical, catalog.critical) }
        if let percent = presentation.ringPercent, percent <= 20 { return (catalog.warning, catalog.warning) }
        return (theme.start, theme.end)
    }

    func start() {
        guard !demo else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.refresh()
        }
    }

    func refresh() {
        guard !demo else { return }
        if scanInFlight {
            refreshPending = true
            return
        }
        now = Date()
        if dataDirectory == nil {
            dataDirectory = DataDirectoryResolver.resolve(savedPath: preferences.codexDataDirectory)
        }
        guard let directory = dataDirectory, let executable = Bundle.main.executableURL else {
            diagnosticKey = "diagnostic.missingDirectory"
            return
        }
        scanInFlight = true
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = Result { try ScanSupervisor.scan(executableURL: executable, dataDirectory: directory) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                if generation == self.scanGeneration {
                    switch scanned {
                    case .success(let value): self.apply(value)
                    case .failure:
                        self.stale = self.result != nil
                        self.diagnosticKey = "diagnostic.readFailed"
                    }
                }
                let refreshAgain = self.refreshPending || generation != self.scanGeneration
                self.refreshPending = false
                if refreshAgain { self.refresh() }
            }
        }
    }

    private func apply(_ scan: UsageScanResult) {
        let usable = scan.state.classification == .complete ||
            (scan.state.classification == .partial && scan.selectedLimit != nil)
        if !usable, result != nil {
            stale = true
            diagnosticKey = diagnostic(for: scan.state.classification)
            return
        }
        result = scan
        stale = false
        diagnosticKey = diagnostic(for: scan.state.classification)
        if scan.state.classification == .complete || scan.state.classification == .partial {
            updateCache(with: scan.sessions)
        }
        if scan.state.classification == .complete { triggerReminders(for: scan) }
    }

    private func diagnostic(for classification: UsageClassification) -> String? {
        switch classification {
        case .complete, .partial: return nil
        case .unsupported: return "diagnostic.noValidEvent"
        case .error: return "diagnostic.readFailed"
        case .empty: return "diagnostic.emptyDirectory"
        }
    }

    private func updateCache(with sessions: [SessionTokenSnapshot]) {
        guard cacheCondition != .invalid else { return }
        var updated = cacheLedger
        guard let totals = try? updated.merge(sessions),
              (try? LocalStateStore.save(updated, to: cacheURL, previous: cacheCondition)) == true else { return }
        cacheLedger = updated
        cacheCondition = .valid
        cacheTotals = totals
    }

    private func triggerReminders(for scan: UsageScanResult) {
        guard remindersEnabled, reminderCondition != .invalid,
              let limit = scan.selectedLimit,
              let remaining = Decimal(string: limit.remainingPercent, locale: Locale(identifier: "en_US_POSIX")),
              let observed = scan.state.observedAt,
              (0...(30 * 60)).contains(now.timeIntervalSince(Date(timeIntervalSince1970: Double(observed) / 1_000)))
        else { return }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        var updated = reminderLedger
        let triggered = [20, 10].filter {
            updated.register(window: limit.name, resetAt: limit.resetAt, remainingPercent: remaining, threshold: $0, now: nowMilliseconds)
        }
        guard !triggered.isEmpty,
              (try? LocalStateStore.save(updated, to: reminderURL, previous: reminderCondition)) == true else { return }
        reminderLedger = updated
        reminderCondition = .valid
        for threshold in triggered { onReminder?(limit, threshold) }
    }

    func setLanguage(_ code: String) {
        guard localization.packs[code] != nil else { return }
        languageCode = code
        preferences.language = code
        savePreferences()
    }

    func setTheme(_ index: Int) {
        guard catalog.themes.indices.contains(index) else { return }
        themeIndex = index
        preferences.theme = index
        savePreferences()
    }

    func setPosition(_ origin: CGPoint, screen: String?) {
        preferences.left = Double(origin.x)
        preferences.top = Double(origin.y)
        preferences.screen = screen
        savePreferences()
    }

    func setDataDirectory(_ url: URL) {
        guard let validated = DataDirectoryResolver.validated(url) else { return }
        dataDirectory = validated
        preferences.codexDataDirectory = validated.path
        scanGeneration += 1
        savePreferences()
        refresh()
    }

    private func savePreferences() {
        guard !demo, preferenceCondition != .invalid,
              (try? LocalStateStore.save(preferences, to: preferenceURL, previous: preferenceCondition)) == true else { return }
        preferenceCondition = .valid
    }

    func resetLocalState() throws {
        guard !demo else { return }
        var defaults = WidgetPreferences.defaultValue
        defaults.language = localization.resolve(preferred: Locale.preferredLanguages)
        try LocalStateStore.save(defaults, to: preferenceURL, previous: preferenceCondition, resetInvalid: true)
        try LocalStateStore.save(CacheLedger.defaultValue, to: cacheURL, previous: cacheCondition, resetInvalid: true)
        try LocalStateStore.save(ReminderLedger.defaultValue, to: reminderURL, previous: reminderCondition, resetInvalid: true)
        preferences = defaults
        preferenceCondition = .valid
        cacheLedger = .defaultValue
        cacheCondition = .valid
        reminderLedger = .defaultValue
        reminderCondition = .valid
        languageCode = defaults.language
        themeIndex = defaults.theme
        cacheTotals = nil
        dataDirectory = DataDirectoryResolver.resolve(savedPath: nil)
        refresh()
    }

    func taskHover(id: String, inside: Bool) {
        taskHideWorkItem?.cancel()
        if inside {
            selectedTaskID = id
        } else {
            let item = DispatchWorkItem { [weak self] in self?.selectedTaskID = nil }
            taskHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.150, execute: item)
        }
    }

    func taskDetailsHover(_ inside: Bool) {
        if inside { taskHideWorkItem?.cancel() }
        else if selectedTaskID != nil { taskHover(id: selectedTaskID!, inside: false) }
    }
}

private extension Color {
    init(widgetHex value: String) {
        var rgb: UInt64 = 0
        Scanner(string: String(value.dropFirst())).scanHexInt64(&rgb)
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}

struct WidgetRingView: View {
    @ObservedObject var model: WidgetModel
    let toggleDetails: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Double? { model.presentation.ringPercent.map { min(100, max(0, $0)) } }
    private var symbol: String {
        if percent != nil { return "" }
        switch model.presentation.statusKey {
        case "status.waiting": return "…"
        case "status.error", "status.unsupported": return "!"
        default: return "—"
        }
    }
    private var accessibilityText: String {
        let language = model.language
        guard let percent,
              let limit = model.result?.selectedLimit,
              let observed = model.result?.state.observedAt
        else {
            return language.text(model.presentation.statusKey == "status.waiting"
                ? "accessibility.waitingState" : "accessibility.unavailableState")
        }
        let observedDate = Date(timeIntervalSince1970: Double(observed) / 1_000)
        return language.text("accessibility.usageSummary", [
            language.text(model.presentation.statusKey),
            String(Int(percent.rounded())),
            WidgetFormatter.limitWindow(minutes: limit.windowMinutes, language: language),
            DetailFormatting.date(observedDate, language: language)
        ])
    }

    var body: some View {
        let accents = model.accentHexes
        let gradient = AngularGradient(
            colors: [Color(widgetHex: accents.0), Color(widgetHex: accents.1)],
            center: .center
        )
        Button(action: toggleDetails) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.055, green: 0.065, blue: 0.075).opacity(0.98))
                    .shadow(color: Color(widgetHex: accents.0).opacity(0.34), radius: 9)
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 6)
                    .padding(7)
                if let percent {
                    Circle()
                        .trim(from: 0, to: percent / 100)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(7)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: percent)
                }
                if model.stale || model.result?.state.classification == .partial {
                    Circle()
                        .stroke(Color.white.opacity(0.42), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                        .padding(2)
                }
                if let percent {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(Int(percent.rounded())))
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                } else {
                    Text(symbol)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: 82, height: 82)
            .padding(9)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("usage-ring")
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(model.language.text("accessibility.ringHelp"))
        .onHover(perform: hoverChanged)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { dragChanged($0.translation) }
                .onEnded { _ in dragEnded() }
        )
        .frame(width: 100, height: 100)
    }
}

private enum DetailFormatting {
    static func date(_ date: Date, language: WidgetLanguagePack) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.culture)
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func percent(_ raw: String?, language: WidgetLanguagePack) -> String {
        guard let raw, let value = Double(raw) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language.culture)
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: value)) ?? raw) + "%"
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(Color.white.opacity(0.62))
            Spacer(minLength: 6)
            Text(value)
                .foregroundStyle(accent ? Color.white : Color.white.opacity(0.88))
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12.5, weight: accent ? .semibold : .regular))
    }
}

private struct TaskDetailsView: View {
    let task: UsageTaskSnapshot
    let language: WidgetLanguagePack
    let accent: Color

    var body: some View {
        VStack(spacing: 7) {
            DetailRow(title: language.text("token.total"), value: WidgetFormatter.compactToken(task.cumulativeTokens, language: language), accent: true)
            DetailRow(title: language.text("cache.taskHit"), value: WidgetFormatter.compactToken(task.cacheHitTokens, language: language))
            DetailRow(title: language.text("cache.taskMiss"), value: WidgetFormatter.compactToken(task.cacheMissTokens, language: language))
            DetailRow(
                title: language.text("token.context"),
                value: "\(WidgetFormatter.compactToken(task.contextTokens, language: language)) / \(WidgetFormatter.compactToken(task.contextLimit, language: language))"
            )
            if let context = task.contextPercent.flatMap(Double.init) {
                VStack(spacing: 4) {
                    DetailRow(title: language.text("token.contextUsage"), value: DetailFormatting.percent(task.contextPercent, language: language))
                    ProgressView(value: min(100, max(0, context)), total: 100).tint(accent)
                }
            }
            DetailRow(
                title: language.text("token.composition"),
                value: language.text("composition.values", [task.inputPercent ?? "—", task.outputPercent ?? "—"])
            )
            DetailRow(title: language.text("token.reasoningShare"), value: DetailFormatting.percent(task.reasoningOutputPercent, language: language))
        }
        .padding(10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { _ in }
    }
}

struct WidgetDetailView: View {
    @ObservedObject var model: WidgetModel
    let hoverChanged: (Bool) -> Void
    @FocusState private var focusedTaskID: String?

    private var accent: Color { Color(widgetHex: model.accentHexes.0) }
    private var state: NormalizedUsageState? { model.result?.state }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    header
                    usageSummary
                    activity
                    localCache
                }
                .padding(16)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 310, height: 506)
        .background(
            ZStack {
                Color(red: 0.055, green: 0.065, blue: 0.078)
                LinearGradient(
                    colors: [accent.opacity(0.10), Color.clear],
                    startPoint: .topTrailing,
                    endPoint: .center
                )
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-details")
        .onHover(perform: hoverChanged)
        .onChange(of: focusedTaskID) { id in
            if let id { model.selectedTaskID = id }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4, height: 22)
                Text(model.language.text("detail.title"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if model.demo {
                    Text(model.language.text("demo.badge"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .foregroundStyle(accent)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                Circle().fill(accent).frame(width: 7, height: 7).shadow(color: accent, radius: 4)
            }
            HStack {
                Text(model.language.text("detail.status"))
                Spacer()
                Text(model.language.text(model.presentation.statusKey))
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .accessibilityIdentifier("usage-status")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.white.opacity(0.62))
        }
    }

    private var usageSummary: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.language.text("detail.remaining"))
                        .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.56))
                    Text(DetailFormatting.percent(state?.remainingPercent, language: model.language))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
                Spacer()
                if let limit = model.result?.selectedLimit {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(WidgetFormatter.limitWindow(minutes: limit.windowMinutes, language: model.language))
                            .font(.system(size: 13, weight: .semibold))
                        Text(WidgetFormatter.countdown(
                            resetAt: Date(timeIntervalSince1970: Double(limit.resetAt) / 1_000),
                            now: model.now,
                            language: model.language
                        ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.58))
                    }
                }
            }
            if let observed = state?.observedAt {
                DetailRow(
                    title: model.language.text("detail.observed"),
                    value: "\(model.language.text(WidgetFormatter.observationKey(observedAt: Date(timeIntervalSince1970: Double(observed) / 1_000), now: model.now))) · \(DetailFormatting.date(Date(timeIntervalSince1970: Double(observed) / 1_000), language: model.language))"
                )
            }
            if let diagnosticKey = model.diagnosticKey {
                Text(model.language.text(diagnosticKey))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.language.text("activity.title"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(model.language.text("activity.window30m"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            if state?.taskNamesAvailable != true {
                Text(model.language.text("activity.namesUnavailable"))
                    .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.60))
            } else if state?.tasks.isEmpty != false {
                Text(model.language.text("activity.empty30m"))
                    .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.60))
            } else {
                ForEach(state?.tasks ?? [], id: \.id) { task in
                    Button {
                        model.selectedTaskID = model.selectedTaskID == task.id ? nil : task.id
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(accent).frame(width: 5, height: 5)
                            Text(task.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(model.selectedTaskID == task.id ? accent : Color.white.opacity(0.88))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            (model.selectedTaskID == task.id ? accent.opacity(0.13) : Color.white.opacity(0.055)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTaskID, equals: task.id)
                    .onHover { model.taskHover(id: task.id, inside: $0) }
                    .accessibilityLabel(model.language.text("accessibility.activeTask", [task.name]))
                }
                if let selected = state?.tasks.first(where: { $0.id == model.selectedTaskID }) {
                    TaskDetailsView(task: selected, language: model.language, accent: accent)
                        .onHover(perform: model.taskDetailsHover)
                }
            }
        }
    }

    private var localCache: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.10))
            cacheRow(title: model.language.text("cache.localHit"), value: model.cacheTotals?.hitTokens)
            cacheRow(title: model.language.text("cache.localMiss"), value: model.cacheTotals?.missTokens)
        }
    }

    private func cacheRow(title: String, value: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(Color.white.opacity(0.62))
            Spacer(minLength: 6)
            Text(value.map { WidgetFormatter.compactToken(String($0), language: model.language) } ?? "—")
                .fontWeight(.semibold).foregroundStyle(Color.white.opacity(0.90))
        }
        .font(.system(size: 12.5))
    }
}

final class WidgetPanel: NSPanel {
    var escapeHandler: (() -> Void)?
    var contextMenuHandler: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { escapeHandler?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            escapeHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextMenuHandler?(event)
    }
}

final class WidgetController: NSObject, UNUserNotificationCenterDelegate {
    let model: WidgetModel
    private let ringPanel: WidgetPanel
    private let detailPanel: WidgetPanel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var interaction = WidgetInteractionState()
    private var interactionTimer: Timer?
    private var dragOrigin: CGPoint?
    private var suppressClick = false
    private var notificationsDenied = false

    init(model: WidgetModel) {
        self.model = model
        ringPanel = WidgetPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        detailPanel = WidgetPanel(
            contentRect: CGRect(x: 0, y: 0, width: 310, height: 506),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanels()
        configureStatusItem()
        configureNotifications()
        observeScreens()
    }

    deinit {
        interactionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func start() {
        placeInitialWindow()
        ringPanel.orderFront(nil)
        rebuildMenu()
        if model.demo {
            NSApp.activate(ignoringOtherApps: true)
            ringPanel.makeKey()
        }
        model.start()
    }

    private func configurePanels() {
        for panel in [ringPanel, detailPanel] {
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .none
        }
        ringPanel.hasShadow = false
        detailPanel.hasShadow = true
        ringPanel.escapeHandler = { [weak self] in self?.closeDetails() }
        detailPanel.escapeHandler = { [weak self] in self?.closeDetails() }
        ringPanel.contextMenuHandler = { [weak self] event in self?.showContextMenu(event) }

        ringPanel.contentView = NSHostingView(rootView: WidgetRingView(
            model: model,
            toggleDetails: { [weak self] in self?.toggleDetails() },
            hoverChanged: { [weak self] in self?.ringHover($0) },
            dragChanged: { [weak self] in self?.dragChanged($0) },
            dragEnded: { [weak self] in self?.dragEnded() }
        ))
        let detailHost = NSHostingView(rootView: WidgetDetailView(
            model: model,
            hoverChanged: { [weak self] in self?.detailHover($0) }
        ))
        detailHost.setAccessibilityElement(true)
        detailHost.setAccessibilityRole(.group)
        detailHost.setAccessibilityIdentifier("usage-details")
        detailPanel.contentView = detailHost
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "chart.donut", accessibilityDescription: model.language.text("app.title"))
        statusItem.button?.toolTip = model.language.text("app.title")
        rebuildMenu()
    }

    private func configureNotifications() {
        guard !model.demo else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationsDenied = settings.authorizationStatus == .denied
                self.model.remindersEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.rebuildMenu()
            }
        }
        model.onReminder = { [weak self] limit, threshold in self?.sendReminder(limit: limit, threshold: threshold) }
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func placeInitialWindow() {
        let screen = screen(identifier: model.storedScreen) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let preferred = model.storedOrigin ?? CGPoint(x: visible.maxX - 112, y: visible.maxY - 112)
        let x = min(max(preferred.x, visible.minX), visible.maxX - ringPanel.frame.width)
        let y = min(max(preferred.y, visible.minY), visible.maxY - ringPanel.frame.height)
        ringPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func screen(identifier: String?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first { screenIdentifier($0) == identifier }
    }

    private func screenIdentifier(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? screen.localizedName
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.max {
            $0.visibleFrame.intersection(ringPanel.frame).width * $0.visibleFrame.intersection(ringPanel.frame).height <
                $1.visibleFrame.intersection(ringPanel.frame).width * $1.visibleFrame.intersection(ringPanel.frame).height
        } ?? NSScreen.main
    }

    private func ringHover(_ inside: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if inside { interaction.pointerEnteredRing(at: now) }
        else { interaction.pointerExitedRing(at: now) }
        scheduleInteraction()
    }

    private func detailHover(_ inside: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if inside { interaction.pointerEnteredDetail(at: now) }
        else { interaction.pointerExitedDetail(at: now) }
        scheduleInteraction()
    }

    private func scheduleInteraction() {
        interactionTimer?.invalidate()
        let now = Date.timeIntervalSinceReferenceDate
        if interaction.advance(to: now) { syncDetails() }
        guard let deadline = interaction.nextDeadline else { return }
        interactionTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, deadline - now), repeats: false) { [weak self] _ in
            self?.scheduleInteraction()
        }
    }

    private func toggleDetails() {
        guard !suppressClick else { return }
        interaction.togglePinned()
        syncDetails()
    }

    private func closeDetails() {
        interaction.escape()
        syncDetails()
    }

    private func showDetails() {
        if !ringPanel.isVisible { ringPanel.orderFront(nil) }
        if interaction.detailMode != .pinned { interaction.togglePinned() }
        syncDetails()
    }

    private func syncDetails() {
        rebuildMenu()
        guard interaction.detailMode != .closed, ringPanel.isVisible,
              let screen = currentScreen()
        else {
            detailPanel.orderOut(nil)
            return
        }
        let height = min(506, max(260, screen.visibleFrame.height - 24))
        let placement = WidgetGeometry.detailPlacement(
            widgetFrame: ringPanel.frame,
            size: CGSize(width: 310, height: height),
            visibleFrame: screen.visibleFrame
        )
        detailPanel.setFrame(placement.frame, display: true)
        if interaction.detailMode == .pinned {
            detailPanel.makeKeyAndOrderFront(nil)
        } else {
            detailPanel.orderFront(nil)
        }
    }

    private func dragChanged(_ translation: CGSize) {
        if dragOrigin == nil {
            dragOrigin = ringPanel.frame.origin
            interaction.escape()
            detailPanel.orderOut(nil)
        }
        guard let origin = dragOrigin else { return }
        suppressClick = true
        ringPanel.setFrameOrigin(CGPoint(x: origin.x + translation.width, y: origin.y - translation.height))
    }

    private func dragEnded() {
        guard dragOrigin != nil, let screen = currentScreen() else { return }
        dragOrigin = nil
        let snapped = WidgetGeometry.snappedFrame(ringPanel.frame, visibleFrame: screen.visibleFrame)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ringPanel.setFrame(snapped.frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ringPanel.animator().setFrame(snapped.frame, display: true)
            }
        }
        model.setPosition(snapped.frame.origin, screen: screenIdentifier(screen))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.suppressClick = false }
    }

    @objc private func screenParametersChanged() {
        let screen = currentScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: min(max(ringPanel.frame.minX, visible.minX), visible.maxX - ringPanel.frame.width),
            y: min(max(ringPanel.frame.minY, visible.minY), visible.maxY - ringPanel.frame.height)
        )
        ringPanel.setFrameOrigin(origin)
        if let screen { model.setPosition(origin, screen: screenIdentifier(screen)) }
        syncDetails()
    }

    private func rebuildMenu() {
        let language = model.language
        let menu = NSMenu()
        let visibleTitle = ringPanel.isVisible ? language.text("menu.hideWidget") : language.text("menu.showWidget")
        menu.addItem(NSMenuItem(title: visibleTitle, action: #selector(toggleWidgetVisibility), keyEquivalent: ""))
        let detailsTitle = interaction.detailMode == .closed ? language.text("menu.showDetails") : language.text("menu.hideDetails")
        menu.addItem(NSMenuItem(title: detailsTitle, action: #selector(toggleMenuDetails), keyEquivalent: ""))
        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: language.text("menu.language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for code in WidgetLocalization.codes {
            let item = NSMenuItem(title: language.text("language.\(code)"), action: #selector(selectLanguage), keyEquivalent: "")
            item.representedObject = code
            item.state = code == model.languageCode ? .on : .off
            item.target = self
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let themeItem = NSMenuItem(title: language.text("menu.theme"), action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (index, theme) in model.catalog.themes.enumerated() {
            let item = NSMenuItem(title: language.text(theme.nameKey), action: #selector(selectTheme), keyEquivalent: "")
            item.tag = index
            item.state = index == model.themeIndex ? .on : .off
            item.target = self
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        let directoryItem = NSMenuItem(title: language.text("menu.chooseDirectory"), action: #selector(chooseDirectory), keyEquivalent: "")
        directoryItem.isEnabled = !model.demo
        menu.addItem(directoryItem)

        let reminder = NSMenuItem(
            title: language.text(notificationsDenied ? "menu.remindersDenied" : "menu.enableReminders"),
            action: #selector(enableReminders),
            keyEquivalent: ""
        )
        reminder.state = model.remindersEnabled ? .on : .off
        reminder.isEnabled = !model.demo && !notificationsDenied && !model.remindersEnabled
        menu.addItem(reminder)
        let resetItem = NSMenuItem(title: language.text("menu.resetState"), action: #selector(resetState), keyEquivalent: "")
        resetItem.isEnabled = !model.demo
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: language.text("menu.exit"), action: #selector(exitWidget), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        statusItem.button?.toolTip = language.text("app.title")
    }

    private func showContextMenu(_ event: NSEvent) {
        rebuildMenu()
        guard let menu = statusItem.menu, let view = ringPanel.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func toggleWidgetVisibility() {
        if ringPanel.isVisible {
            closeDetails()
            ringPanel.orderOut(nil)
        } else {
            ringPanel.orderFront(nil)
        }
        rebuildMenu()
    }

    @objc private func toggleMenuDetails() {
        if interaction.detailMode == .closed { showDetails() }
        else { closeDetails() }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        model.setLanguage(code)
        rebuildMenu()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        model.setTheme(sender.tag)
        rebuildMenu()
    }

    @objc private func chooseDirectory() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        picker.message = model.language.text("picker.description")
        picker.begin { [weak self] response in
            guard response == .OK, let self, let url = picker.url else { return }
            guard DataDirectoryResolver.validated(url) != nil else {
                self.alert(message: self.model.language.text("picker.invalidDirectory"))
                return
            }
            self.model.setDataDirectory(url)
        }
    }

    @objc private func enableReminders() {
        guard !model.demo, !notificationsDenied, !model.remindersEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.remindersEnabled = allowed
                self.notificationsDenied = !allowed
                self.rebuildMenu()
            }
        }
    }

    @objc private func resetState() {
        let alert = NSAlert()
        alert.messageText = model.language.text("reset.title")
        alert.informativeText = model.language.text("reset.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: model.language.text("action.reset"))
        alert.addButton(withTitle: model.language.text("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try model.resetLocalState() }
        catch { self.alert(message: model.language.text("diagnostic.readFailed")) }
        rebuildMenu()
    }

    @objc private func exitWidget() { NSApp.terminate(nil) }

    private func alert(message: String) {
        let alert = NSAlert()
        alert.messageText = model.language.text("app.title")
        alert.informativeText = message
        alert.runModal()
    }

    private func sendReminder(limit: UsageLimitSnapshot, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = model.language.text("reminder.title", [String(threshold)])
        content.body = model.language.text("reminder.body", [
            DetailFormatting.date(Date(timeIntervalSince1970: Double(limit.resetAt) / 1_000), language: model.language)
        ])
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "\(limit.name)-\(limit.resetAt)-\(threshold)",
            content: content,
            trigger: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.ringPanel.orderFront(nil)
            self?.showDetails()
            completionHandler()
        }
    }
}

final class WidgetAppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private var controller: WidgetController?

    init(demo: Bool) { self.demo = demo }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try WidgetModel(demo: demo)
            let controller = WidgetController(model: model)
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Codex Usage Widget"
            alert.informativeText = "Required application resources could not be loaded."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
