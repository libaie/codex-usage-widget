import CoreFoundation
import Darwin
import Foundation

enum CoreError: Error {
    case invalidData
    case outputTooLarge
    case unavailable
    case timedOut
}

enum UsageClassification: String {
    case complete, partial, unsupported, error, empty
}

struct ScanMetrics {
    var validEventCount = 0
    var malformedLineCount = 0
    var unknownEventCount = 0
    var readFailureCount = 0
    var candidateFileCount = 0
    var limitWindowCount = 0

    func jsonObject() -> [String: Any] {
        [
            "validEventCount": validEventCount,
            "malformedLineCount": malformedLineCount,
            "unknownEventCount": unknownEventCount,
            "readFailureCount": readFailureCount,
            "candidateFileCount": candidateFileCount,
            "limitWindowCount": limitWindowCount
        ]
    }
}

struct SessionTokenSnapshot: Equatable {
    var id: String
    var cacheHitTokens: String?
    var cacheMissTokens: String?

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "cacheHitTokens": jsonValue(cacheHitTokens),
            "cacheMissTokens": jsonValue(cacheMissTokens)
        ]
    }
}

struct UsageLimitSnapshot: Equatable {
    var name: String
    var remainingPercent: String
    var resetAt: Int64
    var windowMinutes: Int64?

    func jsonObject() -> [String: Any] {
        [
            "name": name,
            "remainingPercent": remainingPercent,
            "resetAt": resetAt,
            "windowMinutes": jsonValue(windowMinutes)
        ]
    }
}

struct UsageTaskSnapshot: Equatable {
    var id: String
    var name: String
    var observedAt: Int64
    var cumulativeTokens: String? = nil
    var cacheHitTokens: String? = nil
    var cacheMissTokens: String? = nil
    var contextTokens: String? = nil
    var contextLimit: String? = nil
    var contextPercent: String? = nil
    var inputPercent: String? = nil
    var outputPercent: String? = nil
    var reasoningOutputPercent: String? = nil

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "observedAt": observedAt,
            "cumulativeTokens": jsonValue(cumulativeTokens),
            "cacheHitTokens": jsonValue(cacheHitTokens),
            "cacheMissTokens": jsonValue(cacheMissTokens),
            "contextTokens": jsonValue(contextTokens),
            "contextLimit": jsonValue(contextLimit),
            "contextPercent": jsonValue(contextPercent),
            "inputPercent": jsonValue(inputPercent),
            "outputPercent": jsonValue(outputPercent),
            "reasoningOutputPercent": jsonValue(reasoningOutputPercent)
        ]
    }
}

private func jsonValue(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func jsonValue(_ value: Int64?) -> Any { value.map { NSNumber(value: $0) as Any } ?? NSNull() }

struct NormalizedUsageState {
    var classification: UsageClassification
    var selectedWindow: String?
    var remainingPercent: String?
    var cumulativeTokens: String?
    var cacheHitTokens: String?
    var cacheMissTokens: String?
    var contextTokens: String?
    var contextLimit: String?
    var contextPercent: String?
    var inputPercent: String?
    var outputPercent: String?
    var reasoningOutputPercent: String?
    var observedAt: Int64?
    var selectedResetAt: Int64? = nil
    var selectedWindowMinutes: Int64? = nil
    var tasks: [UsageTaskSnapshot] = []
    var taskNamesAvailable = false
    var metrics: ScanMetrics

    func jsonObject() -> [String: Any] {
        [
            "schemaVersion": 1,
            "sourceKind": "local-session-observation",
            "classification": classification.rawValue,
            "freshness": "current",
            "selectedWindow": jsonValue(selectedWindow),
            "remainingPercent": jsonValue(remainingPercent),
            "cumulativeTokens": jsonValue(cumulativeTokens),
            "cacheHitTokens": jsonValue(cacheHitTokens),
            "cacheMissTokens": jsonValue(cacheMissTokens),
            "contextTokens": jsonValue(contextTokens),
            "contextLimit": jsonValue(contextLimit),
            "contextPercent": jsonValue(contextPercent),
            "inputPercent": jsonValue(inputPercent),
            "outputPercent": jsonValue(outputPercent),
            "reasoningOutputPercent": jsonValue(reasoningOutputPercent),
            "observedAt": jsonValue(observedAt),
            "tasks": tasks.map { $0.jsonObject() },
            "taskNamesAvailable": taskNamesAvailable,
            "metrics": metrics.jsonObject()
        ]
    }
}

struct UsageScanResult {
    var state: NormalizedUsageState
    var sessions: [SessionTokenSnapshot]
    var selectedLimit: UsageLimitSnapshot?

    init(state: NormalizedUsageState, sessions: [SessionTokenSnapshot], selectedLimit: UsageLimitSnapshot? = nil) {
        self.state = state
        self.sessions = sessions
        self.selectedLimit = selectedLimit ?? state.selectedLimitSnapshot
    }
}

private extension NormalizedUsageState {
    var selectedLimitSnapshot: UsageLimitSnapshot? {
        guard let name = selectedWindow, let remainingPercent, let resetAt = selectedResetAt else { return nil }
        return UsageLimitSnapshot(
            name: name,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowMinutes: selectedWindowMinutes
        )
    }
}

private struct ParsedWindow {
    let name: String
    let primary: Bool
    let used: Decimal
    let remaining: Decimal
    let resetAt: Int64
    let windowMinutes: Int64?
    var observedAt: Int64
}

enum UsageContract {
    static func evaluate(fileURL: URL, now: Date) throws -> NormalizedUsageState {
        var metrics = ScanMetrics()
        metrics.candidateFileCount = 1
        return evaluate(data: try Data(contentsOf: fileURL), now: now, metrics: metrics)
    }

    static func evaluate(data: Data, now: Date, metrics initialMetrics: ScanMetrics = ScanMetrics()) -> NormalizedUsageState {
        var metrics = initialMetrics
        var windows: [String: ParsedWindow] = [:]
        var cumulativeTokens: Int64?
        var cacheHitTokens: Int64?
        var cacheMissTokens: Int64?
        var detailsTimestamp = Int64.min
        var contextTokens: Int64?
        var contextLimit: Int64?
        var lastInput: Int64?
        var lastOutput: Int64?
        var lastReasoning: Int64?
        var dataIssue = false

        var candidates: [(event: [String: Any], payload: [String: Any], limits: [String: Any])] = []
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline }) {
            let line = Data(rawLine.utf8)
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let event = object as? [String: Any]
            else {
                metrics.malformedLineCount += 1
                continue
            }
            let payload = event["payload"] as? [String: Any] ?? [:]
            if let schemaVersion = payload["schema_version"], integer(schemaVersion) != 1 {
                metrics.unknownEventCount += 1
                continue
            }
            guard let limits = rateLimits(in: event) else { continue }
            metrics.validEventCount += 1
            candidates.append((event, payload, limits))
        }

        let hasCodexLimit = candidates.contains { candidate in
            guard (candidate.limits["limit_id"] as? String) == "codex" else { return false }
            let timestamp = (candidate.event["timestamp"] as? String).flatMap(timestampMilliseconds)
            return [("primary", true), ("secondary", false)].contains {
                parsedWindow(candidate.limits[$0.0], name: $0.0, primary: $0.1, timestamp: timestamp).window != nil
            }
        }
        for candidate in candidates {
            let rawLimitID = candidate.limits["limit_id"]
            if hasCodexLimit {
                guard (rawLimitID as? String) == "codex" else { continue }
            } else {
                guard rawLimitID == nil || rawLimitID is NSNull else { continue }
            }
            let event = candidate.event
            let payload = candidate.payload
            let limits = candidate.limits
            let timestamp = (event["timestamp"] as? String).flatMap(timestampMilliseconds)
            if timestamp == nil { dataIssue = true }

            for (name, primary) in [("primary", true), ("secondary", false)] {
                let result = parsedWindow(limits[name], name: name, primary: primary, timestamp: timestamp)
                if result.invalid { dataIssue = true }
                guard let parsed = result.window else { continue }
                if let previous = windows[name] {
                    if parsed.resetAt == previous.resetAt {
                        var retained = parsed.used > previous.used ? parsed : previous
                        retained.observedAt = max(parsed.observedAt, previous.observedAt)
                        windows[name] = retained
                    } else if parsed.resetAt > previous.resetAt {
                        windows[name] = parsed
                    }
                } else {
                    windows[name] = parsed
                }
            }

            guard let info = payload["info"] as? [String: Any] else { continue }
            if let total = info["total_token_usage"] as? [String: Any] {
                let totalTokens = token(total, "total_tokens")
                if totalTokens.present {
                    guard let value = totalTokens.value else { dataIssue = true; continue }
                    cumulativeTokens = max(cumulativeTokens ?? value, value)
                }
                let input = token(total, "input_tokens")
                let cached = token(total, "cached_input_tokens")
                if input.present && input.value == nil { dataIssue = true }
                if cached.present && cached.value == nil { dataIssue = true }
                if let value = cached.value { cacheHitTokens = max(cacheHitTokens ?? value, value) }
                if let inputValue = input.value, let cacheValue = cached.value {
                    if inputValue >= cacheValue {
                        let miss = inputValue - cacheValue
                        cacheMissTokens = max(cacheMissTokens ?? miss, miss)
                    } else {
                        dataIssue = true
                    }
                }
            }

            if let last = info["last_token_usage"] as? [String: Any], (timestamp ?? Int64.min) >= detailsTimestamp {
                detailsTimestamp = timestamp ?? Int64.min
                let total = token(last, "total_tokens")
                let input = token(last, "input_tokens")
                let output = token(last, "output_tokens")
                let reasoning = token(last, "reasoning_output_tokens")
                for value in [total, input, output, reasoning] where value.present && value.value == nil { dataIssue = true }
                contextTokens = total.value
                lastInput = input.value
                lastOutput = output.value
                lastReasoning = reasoning.value
                let limit = token(info, "model_context_window")
                if limit.present && limit.value == nil { dataIssue = true }
                contextLimit = limit.value
            }
        }

        metrics.limitWindowCount = windows.count
        func checkedRatio(_ numerator: Int64?, _ denominator: Int64?) -> String? {
            guard let numerator, let denominator else { return nil }
            guard denominator > 0, numerator <= denominator else { dataIssue = true; return nil }
            return ratio(numerator, denominator)
        }
        let contextPercent = checkedRatio(contextTokens, contextLimit)
        let inputPercent = checkedRatio(lastInput, contextTokens)
        let outputPercent = checkedRatio(lastOutput, contextTokens)
        let reasoningOutputPercent = checkedRatio(lastReasoning, lastOutput)
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let active = windows.values.filter { $0.resetAt > nowMilliseconds }.sorted {
            if $0.remaining != $1.remaining { return $0.remaining < $1.remaining }
            if $0.primary != $1.primary { return $0.primary }
            if $0.resetAt != $1.resetAt { return $0.resetAt < $1.resetAt }
            return $0.name < $1.name
        }
        let selected = active.first
        let classification: UsageClassification
        let hasIssue = dataIssue || metrics.malformedLineCount > 0 || metrics.unknownEventCount > 0 || metrics.readFailureCount > 0
        if windows.isEmpty {
            if metrics.unknownEventCount > 0 && metrics.malformedLineCount == 0 && metrics.readFailureCount == 0 {
                classification = .unsupported
            }
            else if metrics.validEventCount > 0 || metrics.malformedLineCount > 0 || metrics.readFailureCount > 0 || dataIssue {
                classification = .error
            }
            else { classification = .empty }
        } else {
            classification = hasIssue ? .partial : .complete
        }

        return NormalizedUsageState(
            classification: classification,
            selectedWindow: selected?.name,
            remainingPercent: selected.map { rounded($0.remaining) },
            cumulativeTokens: cumulativeTokens.map(String.init),
            cacheHitTokens: cacheHitTokens.map(String.init),
            cacheMissTokens: cacheMissTokens.map(String.init),
            contextTokens: contextTokens.map(String.init),
            contextLimit: contextLimit.map(String.init),
            contextPercent: contextPercent,
            inputPercent: inputPercent,
            outputPercent: outputPercent,
            reasoningOutputPercent: reasoningOutputPercent,
            observedAt: windows.values.map(\.observedAt).max(),
            selectedResetAt: selected?.resetAt,
            selectedWindowMinutes: selected?.windowMinutes,
            metrics: metrics
        )
    }

    private static func token(_ object: [String: Any], _ key: String) -> (present: Bool, value: Int64?) {
        guard let raw = object[key] else { return (false, nil) }
        return (true, integer(raw))
    }

    private static func parsedWindow(
        _ raw: Any?,
        name: String,
        primary: Bool,
        timestamp: Int64?
    ) -> (window: ParsedWindow?, invalid: Bool) {
        guard let raw, !(raw is NSNull) else { return (nil, false) }
        guard
            let value = raw as? [String: Any],
            let used = decimal(value["used_percent"]), used >= 0, used <= 100,
            let resetSeconds = integer(value["resets_at"]),
            let observed = timestamp
        else { return (nil, true) }
        let reset = resetSeconds.multipliedReportingOverflow(by: 1000)
        guard !reset.overflow else { return (nil, true) }
        var windowMinutes: Int64?
        if let rawMinutes = value["window_minutes"] {
            guard let minutes = integer(rawMinutes) else { return (nil, true) }
            windowMinutes = minutes
        }
        return (ParsedWindow(
            name: name,
            primary: primary,
            used: used,
            remaining: 100 - used,
            resetAt: reset.partialValue,
            windowMinutes: windowMinutes,
            observedAt: observed
        ), false)
    }

    private static func rateLimits(in event: [String: Any]) -> [String: Any]? {
        var pending = [event]
        var index = 0
        while index < pending.count, index < 1_000 {
            let object = pending[index]
            index += 1
            if let limits = object["rate_limits"] as? [String: Any] { return limits }
            pending.append(contentsOf: object.values.compactMap { $0 as? [String: Any] })
        }
        return nil
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int64(text)
    }

    private static func decimal(_ raw: Any?) -> Decimal? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func timestampMilliseconds(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func rounded(_ value: Decimal) -> String {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 1, .bankers)
        let text = NSDecimalNumber(decimal: output).stringValue
        return text.contains(".") ? text : text + ".0"
    }

    private static func ratio(_ numerator: Int64?, _ denominator: Int64?) -> String? {
        guard let numerator, let denominator, denominator > 0 else { return nil }
        return rounded(Decimal(numerator) * 100 / Decimal(denominator))
    }
}

enum DataDirectoryResolver {
    static func resolve(
        savedPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [URL] = []
        if let savedPath, !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: savedPath, isDirectory: true))
        }
        if let path = environment["CODEX_HOME"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        candidates.append(homeDirectory.appendingPathComponent(".codex", isDirectory: true))
        return candidates.lazy.compactMap(validated).first
    }

    static func validated(_ candidate: URL) -> URL? {
        let root = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory), isDirectory.boolValue,
            contains(root: root, child: sessions)
        else { return nil }
        return root
    }

    static func contains(root: URL, child: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

enum StorageCondition: Equatable { case missing, valid, invalid }

struct LoadedState<Value> {
    let condition: StorageCondition
    let value: Value
}

protocol StateValidating { var isValid: Bool { get } }

struct WidgetPreferences: Codable, StateValidating {
    var language: String
    var theme: Int
    var left: Double?
    var top: Double?
    var screen: String?
    var codexDataDirectory: String?

    static let defaultValue = WidgetPreferences(language: "en-US", theme: 7)
    var isValid: Bool {
        ["en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR"].contains(language) &&
            (0..<8).contains(theme) && (left?.isFinite ?? true) && (top?.isFinite ?? true)
    }
}

struct CacheRecord: Codable, StateValidating {
    var hitTokens: String
    var missTokens: String
    var isValid: Bool { validToken(hitTokens) && validToken(missTokens) }
}

struct CacheTotals: Equatable {
    var hitTokens: Int64
    var missTokens: Int64
}

struct CacheLedger: Codable, StateValidating {
    var schemaVersion: Int
    var sessions: [String: CacheRecord]

    static let defaultValue = CacheLedger(schemaVersion: 1, sessions: [:])
    var isValid: Bool {
        schemaVersion == 1 && sessions.count <= 10_000 && sessions.allSatisfy {
            validSessionIdentifier($0.key) && $0.value.isValid
        }
    }

    mutating func merge(_ snapshots: [SessionTokenSnapshot]) throws -> CacheTotals? {
        guard snapshots.count <= 60 else { throw CoreError.invalidData }
        var updated = sessions
        for snapshot in snapshots {
            guard validSessionIdentifier(snapshot.id) else { throw CoreError.invalidData }
            guard let rawHit = snapshot.cacheHitTokens, let rawMiss = snapshot.cacheMissTokens else { continue }
            guard let hit = Int64(rawHit), let miss = Int64(rawMiss), hit >= 0, miss >= 0 else {
                throw CoreError.invalidData
            }
            let previous = updated[snapshot.id]
            let previousHit = previous.flatMap { Int64($0.hitTokens) } ?? 0
            let previousMiss = previous.flatMap { Int64($0.missTokens) } ?? 0
            updated[snapshot.id] = CacheRecord(
                hitTokens: String(max(previousHit, hit)),
                missTokens: String(max(previousMiss, miss))
            )
            guard updated.count <= 10_000 else { throw CoreError.invalidData }
        }
        sessions = updated
        return totals()
    }

    func totals() -> CacheTotals? {
        var hit: Int64 = 0
        var miss: Int64 = 0
        for record in sessions.values {
            guard let nextHit = Int64(record.hitTokens), let nextMiss = Int64(record.missTokens) else { return nil }
            let hitResult = hit.addingReportingOverflow(nextHit)
            let missResult = miss.addingReportingOverflow(nextMiss)
            guard !hitResult.overflow, !missResult.overflow else { return nil }
            hit = hitResult.partialValue
            miss = missResult.partialValue
        }
        return sessions.isEmpty ? nil : CacheTotals(hitTokens: hit, missTokens: miss)
    }
}

struct ReminderLedger: Codable, StateValidating {
    var schemaVersion: Int
    var notifiedResetAt: [String: Int64]

    static let defaultValue = ReminderLedger(schemaVersion: 1, notifiedResetAt: [:])
    var isValid: Bool {
        let allowed = Set(["primary|10", "primary|20", "secondary|10", "secondary|20"])
        return schemaVersion == 1 && notifiedResetAt.count <= allowed.count && notifiedResetAt.allSatisfy {
            allowed.contains($0.key) && $0.value >= 0
        }
    }

    mutating func register(window: String, resetAt: Int64, remainingPercent: Decimal, threshold: Int, now: Int64) -> Bool {
        guard
            (window == "primary" || window == "secondary"),
            threshold == 10 || threshold == 20,
            remainingPercent >= 0, remainingPercent <= 100,
            remainingPercent <= Decimal(threshold),
            resetAt > now
        else { return false }
        notifiedResetAt = notifiedResetAt.filter { $0.value > now }
        let key = "\(window)|\(threshold)"
        guard notifiedResetAt[key] != resetAt else { return false }
        notifiedResetAt[key] = resetAt
        return true
    }
}

private func validToken(_ text: String) -> Bool {
    !text.isEmpty && (text == "0" || text.first != "0") &&
        text.allSatisfy({ $0 >= "0" && $0 <= "9" }) && Int64(text) != nil
}

private func validSessionIdentifier(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 500 && text.utf8.count <= 2_000 &&
        !text.contains("/") && !text.contains("\\") &&
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}

enum LocalStateStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL, defaultValue: T) -> LoadedState<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return LoadedState(condition: .missing, value: defaultValue) }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 256 * 1024 else {
                return LoadedState(condition: .invalid, value: defaultValue)
            }
            let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
            if let validated = value as? StateValidating, !validated.isValid {
                return LoadedState(condition: .invalid, value: defaultValue)
            }
            return LoadedState(condition: .valid, value: value)
        } catch {
            return LoadedState(condition: .invalid, value: defaultValue)
        }
    }

    @discardableResult
    static func save<T: Encodable>(
        _ value: T,
        to url: URL,
        previous: StorageCondition,
        resetInvalid: Bool = false
    ) throws -> Bool {
        guard previous != .invalid || resetInvalid else { return false }
        let data = try JSONEncoder.sorted.encode(value)
        guard data.count <= 256 * 1024 else { throw CoreError.outputTooLarge }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        return true
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

final class WriterLock {
    private let descriptor: Int32
    let acquired: Bool

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let opened = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw CoreError.unavailable }
        var information = stat()
        guard fstat(opened, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid()
        else {
            close(opened)
            throw CoreError.unavailable
        }
        descriptor = opened
        acquired = flock(opened, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if acquired { flock(descriptor, LOCK_UN) }
        close(descriptor)
    }
}

enum SessionScanner {
    private struct Candidate {
        let url: URL
        let modified: Date
        let id: String
        let taskID: String?
    }

    static func scan(dataDirectory: URL, now: Date = Date(), maximumEntries: Int = 10_000) throws -> UsageScanResult {
        guard maximumEntries > 0 else { throw CoreError.invalidData }
        guard let root = DataDirectoryResolver.validated(dataDirectory) else { throw CoreError.unavailable }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var metrics = ScanMetrics()
        var candidates: [Candidate] = []
        var activeCandidates: [Candidate] = []
        var enumerationFailures = 0
        var inspectedEntries = 0
        let entryLimit = min(maximumEntries, 10_000)
        let activeCutoff = now.addingTimeInterval(-30 * 60)
        func retain(_ candidate: Candidate, in list: inout [Candidate]) {
            list.append(candidate)
            // ponytail: fixed 30-item lists are simpler than a heap; replace only if either cap grows by an order of magnitude.
            list.sort {
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.url.path < $1.url.path
            }
            if list.count > 30 { list.removeLast() }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in enumerationFailures += 1; return true }
        ) else { throw CoreError.unavailable }

        for case let url as URL in enumerator {
            if inspectedEntries >= entryLimit { enumerationFailures += 1; break }
            inspectedEntries += 1
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: Set(keys)) }
            catch { enumerationFailures += 1; continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                enumerationFailures += 1
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "jsonl" else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard DataDirectoryResolver.contains(root: sessions, child: resolved) else { enumerationFailures += 1; continue }
            let id = resolved.deletingPathExtension().lastPathComponent
            guard validSessionIdentifier(id) else { enumerationFailures += 1; continue }
            let candidate = Candidate(
                url: resolved,
                modified: values.contentModificationDate ?? .distantPast,
                id: id,
                taskID: trailingUUID(from: id)
            )
            retain(candidate, in: &candidates)
            if candidate.modified >= activeCutoff { retain(candidate, in: &activeCandidates) }
        }
        metrics.candidateFileCount = candidates.count
        metrics.readFailureCount = enumerationFailures

        let taskNames = readTaskNames(at: root.appendingPathComponent("session_index.jsonl"), containedBy: root)
        var readCandidates = candidates
        var readPaths = Set(candidates.map { $0.url.path })
        if let taskNames {
            for candidate in activeCandidates where candidate.taskID.flatMap({ taskNames[$0] }) != nil {
                if readPaths.insert(candidate.url.path).inserted { readCandidates.append(candidate) }
            }
        }
        let usagePaths = Set(candidates.map { $0.url.path })
        var combined = Data()
        var sessionSnapshots: [SessionTokenSnapshot] = []
        var tasks: [UsageTaskSnapshot] = []
        for candidate in readCandidates {
            var fileState: NormalizedUsageState?
            do {
                var data = try tail(of: candidate.url, maximumBytes: 256 * 1024)
                fileState = UsageContract.evaluate(data: data, now: now)
                if candidate.url == candidates.first?.url, fileState?.metrics.validEventCount == 0 {
                    data = try tail(of: candidate.url, maximumBytes: 1024 * 1024)
                    fileState = UsageContract.evaluate(data: data, now: now)
                }
                if usagePaths.contains(candidate.url.path) {
                    combined.append(data)
                    combined.append(0x0a)
                    sessionSnapshots.append(SessionTokenSnapshot(
                        id: candidate.id,
                        cacheHitTokens: fileState?.cacheHitTokens,
                        cacheMissTokens: fileState?.cacheMissTokens
                    ))
                }
            } catch {
                metrics.readFailureCount += 1
            }
            if
                let taskID = candidate.taskID,
                let name = taskNames?[taskID]
            {
                tasks.append(UsageTaskSnapshot(
                    id: taskID,
                    name: name,
                    observedAt: milliseconds(candidate.modified),
                    cumulativeTokens: fileState?.cumulativeTokens,
                    cacheHitTokens: fileState?.cacheHitTokens,
                    cacheMissTokens: fileState?.cacheMissTokens,
                    contextTokens: fileState?.contextTokens,
                    contextLimit: fileState?.contextLimit,
                    contextPercent: fileState?.contextPercent,
                    inputPercent: fileState?.inputPercent,
                    outputPercent: fileState?.outputPercent,
                    reasoningOutputPercent: fileState?.reasoningOutputPercent
                ))
            }
        }
        var state = UsageContract.evaluate(data: combined, now: now, metrics: metrics)
        state.tasks = tasks.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            return $0.id < $1.id
        }
        state.taskNamesAvailable = taskNames != nil
        return UsageScanResult(
            state: state,
            sessions: sessionSnapshots.sorted { $0.id < $1.id }
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let interval = date.timeIntervalSince1970 * 1000
        if !interval.isFinite || interval <= Double(Int64.min) { return Int64.min }
        if interval >= Double(Int64.max) { return Int64.max }
        return Int64(interval.rounded())
    }

    private static func trailingUUID(from text: String) -> String? {
        guard text.count >= 36 else { return nil }
        let suffix = String(text.suffix(36))
        guard let value = UUID(uuidString: suffix) else { return nil }
        return value.uuidString.lowercased()
    }

    private static func readTaskNames(at url: URL, containedBy root: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  DataDirectoryResolver.contains(root: root, child: resolved)
            else { return nil }
            let data = try tail(of: resolved, maximumBytes: 1024 * 1024)
            var names: [String: String] = [:]
            for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline }).prefix(10_000) {
                guard
                    let decoded = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)),
                    let object = decoded as? [String: Any],
                    let rawID = object["id"] as? String,
                    let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                    let rawName = object["thread_name"] as? String
                else { continue }
                let name = rawName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty, name.count <= 500, name.utf8.count <= 2_000 else { continue }
                names[id] = name
            }
            return names
        } catch {
            return nil
        }
    }

    private static func tail(of url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let offset = length > maximumBytes ? length - maximumBytes : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0a) else { return Data() }
            data.removeSubrange(...newline)
        }
        return data
    }
}

private func validPercentage(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 1,
          (parts[0] == "0" || parts[0].first != "0"),
          parts[0].allSatisfy({ $0 >= "0" && $0 <= "9" }),
          parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    else { return false }
    return value >= 0 && value <= 100
}

private func validTaskIdentifier(_ text: String) -> Bool {
    UUID(uuidString: text)?.uuidString.lowercased() == text
}

private func jsonInt64(_ raw: Any?) -> Int64? {
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int64(number.stringValue)
}

private extension UsageScanResult {
    func conservativeJSONByteUpperBound() throws -> Int {
        guard sessions.count <= 30, state.tasks.count <= 30,
              state.metrics.validEventCount >= 0, state.metrics.validEventCount <= 100_000,
              state.metrics.malformedLineCount >= 0, state.metrics.malformedLineCount <= 100_000,
              state.metrics.unknownEventCount >= 0, state.metrics.unknownEventCount <= 100_000,
              state.metrics.readFailureCount >= 0, state.metrics.readFailureCount <= 100_000,
              state.metrics.candidateFileCount >= 0, state.metrics.candidateFileCount <= 30,
              state.metrics.limitWindowCount >= 0, state.metrics.limitWindowCount <= 2,
              state.selectedWindow == nil || state.selectedWindow == "primary" || state.selectedWindow == "secondary",
              [state.remainingPercent, state.contextPercent, state.inputPercent, state.outputPercent, state.reasoningOutputPercent]
                .allSatisfy({ $0 == nil || validPercentage($0!) }),
              [state.cumulativeTokens, state.cacheHitTokens, state.cacheMissTokens, state.contextTokens, state.contextLimit]
                .allSatisfy({ $0 == nil || validToken($0!) })
        else { throw CoreError.invalidData }

        var bytes = 32 * 1024
        func add(_ text: String?, maximumUTF8Bytes: Int) throws {
            guard let text else { return }
            guard text.utf8.count <= maximumUTF8Bytes else { throw CoreError.outputTooLarge }
            let escaped = text.utf8.count.multipliedReportingOverflow(by: 6)
            guard !escaped.overflow else { throw CoreError.outputTooLarge }
            let total = bytes.addingReportingOverflow(escaped.partialValue)
            guard !total.overflow else { throw CoreError.outputTooLarge }
            bytes = total.partialValue
        }
        for value in [state.selectedWindow, state.remainingPercent, state.cumulativeTokens, state.cacheHitTokens,
                      state.cacheMissTokens, state.contextTokens, state.contextLimit, state.contextPercent,
                      state.inputPercent, state.outputPercent, state.reasoningOutputPercent] {
            try add(value, maximumUTF8Bytes: 64)
        }
        guard selectedLimit == state.selectedLimitSnapshot else { throw CoreError.invalidData }
        if let selectedLimit {
            guard (selectedLimit.name == "primary" || selectedLimit.name == "secondary"),
                  validPercentage(selectedLimit.remainingPercent), selectedLimit.resetAt >= 0,
                  selectedLimit.windowMinutes == nil || selectedLimit.windowMinutes! >= 0
            else { throw CoreError.invalidData }
            try add(selectedLimit.name, maximumUTF8Bytes: 16)
            try add(selectedLimit.remainingPercent, maximumUTF8Bytes: 64)
        }
        guard sessions == sessions.sorted(by: { $0.id < $1.id }) else { throw CoreError.invalidData }
        for session in sessions {
            guard validSessionIdentifier(session.id),
                  session.cacheHitTokens == nil || validToken(session.cacheHitTokens!),
                  session.cacheMissTokens == nil || validToken(session.cacheMissTokens!)
            else { throw CoreError.invalidData }
            try add(session.id, maximumUTF8Bytes: 2_000)
            try add(session.cacheHitTokens, maximumUTF8Bytes: 19)
            try add(session.cacheMissTokens, maximumUTF8Bytes: 19)
        }
        guard state.tasks == state.tasks.sorted(by: {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            return $0.id < $1.id
        }) else { throw CoreError.invalidData }
        for task in state.tasks {
            guard validTaskIdentifier(task.id), !task.name.isEmpty, task.name.count <= 500,
                  task.name.utf8.count <= 2_000,
                  [task.cumulativeTokens, task.cacheHitTokens, task.cacheMissTokens, task.contextTokens, task.contextLimit]
                    .allSatisfy({ $0 == nil || validToken($0!) }),
                  [task.contextPercent, task.inputPercent, task.outputPercent, task.reasoningOutputPercent]
                    .allSatisfy({ $0 == nil || validPercentage($0!) })
            else { throw CoreError.invalidData }
            try add(task.id, maximumUTF8Bytes: 36)
            try add(task.name, maximumUTF8Bytes: 2_000)
            for value in [task.cumulativeTokens, task.cacheHitTokens, task.cacheMissTokens, task.contextTokens,
                          task.contextLimit, task.contextPercent, task.inputPercent, task.outputPercent,
                          task.reasoningOutputPercent] {
                try add(value, maximumUTF8Bytes: 64)
            }
        }
        return bytes
    }
}

enum ScanWorker {
    static let maximumResultBytes = 256 * 1024

    static func runFromEnvironment() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard
            let directory = environment["CODEX_WIDGET_DATA_DIRECTORY"],
            let output = environment["CODEX_WIDGET_RESULT_PATH"],
            let generation = environment["CODEX_WIDGET_GENERATION"], isHexIdentifier(generation)
        else { return 64 }

        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 12)
        watchdog.setEventHandler { _exit(124) }
        watchdog.resume()
        defer { watchdog.cancel() }

        do {
            let result = try SessionScanner.scan(dataDirectory: URL(fileURLWithPath: directory, isDirectory: true))
            let data = try encodePayload(result, generation: generation)
            try writePayload(data, to: URL(fileURLWithPath: output))
            return 0
        } catch CoreError.outputTooLarge {
            return 65
        } catch {
            return 1
        }
    }

    static func encodePayload(_ result: UsageScanResult, generation: String) throws -> Data {
        guard isHexIdentifier(generation) else { throw CoreError.invalidData }
        guard try result.conservativeJSONByteUpperBound() <= maximumResultBytes else { throw CoreError.outputTooLarge }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "generation": generation,
            "state": result.state.jsonObject(),
            "sessions": result.sessions.map { $0.jsonObject() },
            "selectedLimit": result.selectedLimit?.jsonObject() ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumResultBytes else { throw CoreError.outputTooLarge }
        return data
    }

    static func writePayload(_ data: Data, to url: URL) throws {
        guard data.count <= maximumResultBytes, validResultURL(url) else { throw CoreError.outputTooLarge }
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private static func validResultURL(_ url: URL) -> Bool {
        guard url.lastPathComponent == "result.json" else { return false }
        let parent = url.deletingLastPathComponent()
        let name = parent.lastPathComponent
        guard name.hasPrefix("CodexUsageWidget-scan-") else { return false }
        let token = String(name.dropFirst("CodexUsageWidget-scan-".count))
        guard isHexIdentifier(token) else { return false }
        guard let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              permissions.intValue & 0o777 == 0o700,
              owner.uint32Value == geteuid()
        else { return false }
        return true
    }

    static func isHexIdentifier(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit }
    }
}

enum ScanSupervisor {
    static func scan(executableURL: URL, dataDirectory: URL, timeout: TimeInterval = 10) throws -> UsageScanResult {
        let generation = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let channel = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageWidget-scan-\(generation)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: channel,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: channel) }
        let result = channel.appendingPathComponent("result.json")
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--scan-worker"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_WIDGET_DATA_DIRECTORY"] = dataDirectory.path
        environment["CODEX_WIDGET_RESULT_PATH"] = result.path
        environment["CODEX_WIDGET_GENERATION"] = generation
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            throw CoreError.timedOut
        }
        guard process.terminationStatus == 0 else { throw CoreError.invalidData }
        let values = try result.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let size = values.fileSize, size <= ScanWorker.maximumResultBytes else {
            throw CoreError.outputTooLarge
        }
        return try decodeEnvelope(Data(contentsOf: result), generation: generation)
    }

    static func cleanupOrphans(in root: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let prefix = "CodexUsageWidget-scan-"
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix), ScanWorker.isHexIdentifier(String(name.dropFirst(prefix.count))),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 24 * 60 * 60,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == geteuid()
            else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    static func decodeEnvelope(_ data: Data, generation: String) throws -> UsageScanResult {
        guard
            data.count <= ScanWorker.maximumResultBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(["schemaVersion", "generation", "state", "sessions", "selectedLimit"]),
            jsonInt64(object["schemaVersion"]) == 1,
            object["generation"] as? String == generation,
            let stateObject = object["state"] as? [String: Any],
            let sessionObjects = object["sessions"] as? [[String: Any]], sessionObjects.count <= 30
        else { throw CoreError.invalidData }
        var state = try normalizedState(from: stateObject)
        let sessions = try sessionObjects.map { try sessionSnapshot(from: $0) }
        let selectedLimit: UsageLimitSnapshot?
        if object["selectedLimit"] is NSNull {
            selectedLimit = nil
        } else if let limitObject = object["selectedLimit"] as? [String: Any] {
            selectedLimit = try limitSnapshot(from: limitObject)
        } else {
            throw CoreError.invalidData
        }
        guard (selectedLimit == nil) == (state.selectedWindow == nil && state.remainingPercent == nil) else {
            throw CoreError.invalidData
        }
        if let selectedLimit {
            guard state.selectedWindow == selectedLimit.name,
                  state.remainingPercent == selectedLimit.remainingPercent else { throw CoreError.invalidData }
            state.selectedResetAt = selectedLimit.resetAt
            state.selectedWindowMinutes = selectedLimit.windowMinutes
        }
        let result = UsageScanResult(state: state, sessions: sessions, selectedLimit: selectedLimit)
        guard try result.conservativeJSONByteUpperBound() <= ScanWorker.maximumResultBytes else {
            throw CoreError.outputTooLarge
        }
        return result
    }

    private static func sessionSnapshot(from object: [String: Any]) throws -> SessionTokenSnapshot {
        guard Set(object.keys) == Set(["id", "cacheHitTokens", "cacheMissTokens"]),
              let id = object["id"] as? String, validSessionIdentifier(id)
        else { throw CoreError.invalidData }
        func token(_ key: String) throws -> String? {
            guard let raw = object[key] else { throw CoreError.invalidData }
            if raw is NSNull { return nil }
            guard let text = raw as? String, validToken(text) else { throw CoreError.invalidData }
            return text
        }
        return SessionTokenSnapshot(id: id, cacheHitTokens: try token("cacheHitTokens"), cacheMissTokens: try token("cacheMissTokens"))
    }

    private static func limitSnapshot(from object: [String: Any]) throws -> UsageLimitSnapshot {
        guard Set(object.keys) == Set(["name", "remainingPercent", "resetAt", "windowMinutes"]),
              let name = object["name"] as? String, name == "primary" || name == "secondary",
              let remaining = object["remainingPercent"] as? String, validPercentage(remaining),
              let resetAt = jsonInt64(object["resetAt"]), resetAt >= 0
        else { throw CoreError.invalidData }
        let windowMinutes: Int64?
        if object["windowMinutes"] is NSNull { windowMinutes = nil }
        else if let value = jsonInt64(object["windowMinutes"]), value >= 0 { windowMinutes = value }
        else { throw CoreError.invalidData }
        return UsageLimitSnapshot(name: name, remainingPercent: remaining, resetAt: resetAt, windowMinutes: windowMinutes)
    }

    private static func normalizedState(from object: [String: Any]) throws -> NormalizedUsageState {
        let expectedKeys = Set([
            "schemaVersion", "sourceKind", "classification", "freshness", "selectedWindow", "remainingPercent",
            "cumulativeTokens", "cacheHitTokens", "cacheMissTokens", "contextTokens", "contextLimit", "contextPercent",
            "inputPercent", "outputPercent", "reasoningOutputPercent", "observedAt", "tasks", "taskNamesAvailable", "metrics"
        ])
        guard
            Set(object.keys) == expectedKeys,
            jsonInt64(object["schemaVersion"]) == 1,
            object["sourceKind"] as? String == "local-session-observation",
            object["freshness"] as? String == "current",
            let rawClassification = object["classification"] as? String,
            let classification = UsageClassification(rawValue: rawClassification),
            let metricsObject = object["metrics"] as? [String: Any],
            Set(metricsObject.keys) == Set(["validEventCount", "malformedLineCount", "unknownEventCount", "readFailureCount", "candidateFileCount", "limitWindowCount"]),
            let taskObjects = object["tasks"] as? [[String: Any]], taskObjects.count <= 30,
            let taskNamesAvailable = object["taskNamesAvailable"] as? Bool
        else { throw CoreError.invalidData }
        func optionalString(_ key: String, token: Bool = false, percentage: Bool = false) throws -> String? {
            guard let raw = object[key] else { throw CoreError.invalidData }
            if raw is NSNull { return nil }
            guard let text = raw as? String, text.utf8.count <= 64,
                  !token || validToken(text), !percentage || validPercentage(text)
            else { throw CoreError.invalidData }
            return text
        }
        func metric(_ key: String, maximum: Int = 100_000) throws -> Int {
            guard let raw = jsonInt64(metricsObject[key]), raw >= 0, raw <= Int64(maximum) else { throw CoreError.invalidData }
            return Int(raw)
        }
        let selected = try optionalString("selectedWindow")
        if let selected, selected != "primary" && selected != "secondary" { throw CoreError.invalidData }
        let observed: Int64?
        if object["observedAt"] is NSNull { observed = nil }
        else if let value = jsonInt64(object["observedAt"]) { observed = value }
        else { throw CoreError.invalidData }
        let tasks = try taskObjects.map { try taskSnapshot(from: $0) }
        let metrics = ScanMetrics(
            validEventCount: try metric("validEventCount"),
            malformedLineCount: try metric("malformedLineCount"),
            unknownEventCount: try metric("unknownEventCount"),
            readFailureCount: try metric("readFailureCount"),
            candidateFileCount: try metric("candidateFileCount", maximum: 30),
            limitWindowCount: try metric("limitWindowCount", maximum: 2)
        )
        return NormalizedUsageState(
            classification: classification,
            selectedWindow: selected,
            remainingPercent: try optionalString("remainingPercent", percentage: true),
            cumulativeTokens: try optionalString("cumulativeTokens", token: true),
            cacheHitTokens: try optionalString("cacheHitTokens", token: true),
            cacheMissTokens: try optionalString("cacheMissTokens", token: true),
            contextTokens: try optionalString("contextTokens", token: true),
            contextLimit: try optionalString("contextLimit", token: true),
            contextPercent: try optionalString("contextPercent", percentage: true),
            inputPercent: try optionalString("inputPercent", percentage: true),
            outputPercent: try optionalString("outputPercent", percentage: true),
            reasoningOutputPercent: try optionalString("reasoningOutputPercent", percentage: true),
            observedAt: observed,
            tasks: tasks,
            taskNamesAvailable: taskNamesAvailable,
            metrics: metrics
        )
    }

    private static func taskSnapshot(from object: [String: Any]) throws -> UsageTaskSnapshot {
        let keys = Set(["id", "name", "observedAt", "cumulativeTokens", "cacheHitTokens", "cacheMissTokens", "contextTokens", "contextLimit", "contextPercent", "inputPercent", "outputPercent", "reasoningOutputPercent"])
        guard Set(object.keys) == keys,
              let id = object["id"] as? String, validTaskIdentifier(id),
              let name = object["name"] as? String, !name.isEmpty, name.count <= 500, name.utf8.count <= 2_000,
              let observedAt = jsonInt64(object["observedAt"])
        else { throw CoreError.invalidData }
        func optional(_ key: String, token: Bool = false, percentage: Bool = false) throws -> String? {
            guard let raw = object[key] else { throw CoreError.invalidData }
            if raw is NSNull { return nil }
            guard let text = raw as? String, text.utf8.count <= 64,
                  !token || validToken(text), !percentage || validPercentage(text)
            else { throw CoreError.invalidData }
            return text
        }
        return UsageTaskSnapshot(
            id: id,
            name: name,
            observedAt: observedAt,
            cumulativeTokens: try optional("cumulativeTokens", token: true),
            cacheHitTokens: try optional("cacheHitTokens", token: true),
            cacheMissTokens: try optional("cacheMissTokens", token: true),
            contextTokens: try optional("contextTokens", token: true),
            contextLimit: try optional("contextLimit", token: true),
            contextPercent: try optional("contextPercent", percentage: true),
            inputPercent: try optional("inputPercent", percentage: true),
            outputPercent: try optional("outputPercent", percentage: true),
            reasoningOutputPercent: try optional("reasoningOutputPercent", percentage: true)
        )
    }
}

enum ApplicationPaths {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexUsageWidget", isDirectory: true)
    }
}
