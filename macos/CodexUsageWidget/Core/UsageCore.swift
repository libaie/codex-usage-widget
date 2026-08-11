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
            "tasks": [],
            "metrics": metrics.jsonObject()
        ]
    }

    var estimatedMaximumJSONBytes: Int { 8192 }
}

private struct ParsedWindow {
    let name: String
    let primary: Bool
    let used: Decimal
    let remaining: Decimal
    let resetAt: Int64
    let observedAt: Int64
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
        var observedAt: Int64?
        var dataIssue = false

        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline }) {
            let line = Data(rawLine.utf8)
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let event = object as? [String: Any],
                let payload = event["payload"] as? [String: Any],
                let payloadType = payload["type"] as? String
            else {
                metrics.malformedLineCount += 1
                continue
            }
            guard event["type"] as? String == "event_msg", payloadType == "token_count" else {
                metrics.unknownEventCount += 1
                continue
            }
            metrics.validEventCount += 1
            let timestamp = (event["timestamp"] as? String).flatMap(timestampMilliseconds)
            if timestamp == nil { dataIssue = true }
            if let timestamp { observedAt = max(observedAt ?? timestamp, timestamp) }

            if let limits = payload["rate_limits"] as? [String: Any] {
                for (name, primary) in [("primary", true), ("secondary", false)] {
                    guard let raw = limits[name], !(raw is NSNull) else { continue }
                    guard
                        let window = raw as? [String: Any],
                        let used = decimal(window["used_percent"]),
                        used >= 0, used <= 100,
                        let resetSeconds = integer(window["resets_at"]),
                        let observed = timestamp
                    else {
                        dataIssue = true
                        continue
                    }
                    let reset = resetSeconds.multipliedReportingOverflow(by: 1000)
                    guard !reset.overflow else { dataIssue = true; continue }
                    let parsed = ParsedWindow(
                        name: name,
                        primary: primary,
                        used: used,
                        remaining: 100 - used,
                        resetAt: reset.partialValue,
                        observedAt: observed
                    )
                    if let previous = windows[name] {
                        if parsed.resetAt == previous.resetAt {
                            if parsed.used > previous.used { windows[name] = parsed }
                        } else if parsed.observedAt >= previous.observedAt {
                            windows[name] = parsed
                        }
                    } else {
                        windows[name] = parsed
                    }
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
        if metrics.validEventCount == 0 {
            if metrics.unknownEventCount > 0 { classification = .unsupported }
            else if metrics.malformedLineCount > 0 || metrics.readFailureCount > 0 { classification = .error }
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
            contextPercent: ratio(contextTokens, contextLimit),
            inputPercent: ratio(lastInput, contextTokens),
            outputPercent: ratio(lastOutput, contextTokens),
            reasoningOutputPercent: ratio(lastReasoning, lastOutput),
            observedAt: observedAt,
            metrics: metrics
        )
    }

    private static func token(_ object: [String: Any], _ key: String) -> (present: Bool, value: Int64?) {
        guard let raw = object[key] else { return (false, nil) }
        return (true, integer(raw))
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

struct CacheLedger: Codable, StateValidating {
    var schemaVersion: Int
    var sessions: [String: CacheRecord]

    static let defaultValue = CacheLedger(schemaVersion: 1, sessions: [:])
    var isValid: Bool {
        schemaVersion == 1 && sessions.count <= 10_000 && sessions.allSatisfy {
            !$0.key.isEmpty && $0.key.count <= 500 && $0.value.isValid
        }
    }
}

struct ReminderLedger: Codable, StateValidating {
    var schemaVersion: Int
    var notifiedResetAt: [String: Int64]

    static let defaultValue = ReminderLedger(schemaVersion: 1, notifiedResetAt: [:])
    var isValid: Bool {
        schemaVersion == 1 && notifiedResetAt.count <= 100 && notifiedResetAt.allSatisfy {
            !$0.key.isEmpty && $0.key.count <= 100 && $0.value >= 0
        }
    }
}

private func validToken(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy({ $0 >= "0" && $0 <= "9" }) && Int64(text) != nil
}

enum LocalStateStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL, defaultValue: T) -> LoadedState<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return LoadedState(condition: .missing, value: defaultValue) }
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 256 * 1024 else {
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
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CoreError.unavailable }
        acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
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
    }

    static func scan(dataDirectory: URL, now: Date = Date()) throws -> NormalizedUsageState {
        guard let root = DataDirectoryResolver.validated(dataDirectory) else { throw CoreError.unavailable }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var metrics = ScanMetrics()
        var candidates: [Candidate] = []
        var enumerationFailures = 0
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in enumerationFailures += 1; return true }
        ) else { throw CoreError.unavailable }

        for case let url as URL in enumerator {
            if metrics.candidateFileCount + enumerationFailures >= 10_000 { enumerationFailures += 1; break }
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
            candidates.append(Candidate(url: resolved, modified: values.contentModificationDate ?? .distantPast))
            // ponytail: 30-item linear ordering is simpler and bounded; use a heap only if the cap grows by an order of magnitude.
            candidates.sort { $0.modified > $1.modified }
            if candidates.count > 30 { candidates.removeLast() }
        }
        metrics.candidateFileCount = candidates.count
        metrics.readFailureCount = enumerationFailures

        var combined = Data()
        for candidate in candidates {
            do {
                combined.append(try tail(of: candidate.url, maximumBytes: 256 * 1024))
                combined.append(0x0a)
            } catch {
                metrics.readFailureCount += 1
            }
        }
        return UsageContract.evaluate(data: combined, now: now, metrics: metrics)
    }

    private static func tail(of url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let offset = length > maximumBytes ? length - maximumBytes : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        if offset > 0, let newline = data.firstIndex(of: 0x0a) { data.removeSubrange(...newline) }
        return data
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
            let state = try SessionScanner.scan(dataDirectory: URL(fileURLWithPath: directory, isDirectory: true))
            guard state.estimatedMaximumJSONBytes <= maximumResultBytes else { throw CoreError.outputTooLarge }
            let object: [String: Any] = ["schemaVersion": 1, "generation": generation, "state": state.jsonObject()]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try writePayload(data, to: URL(fileURLWithPath: output))
            return 0
        } catch CoreError.outputTooLarge {
            return 65
        } catch {
            return 1
        }
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
              permissions.intValue & 0o777 == 0o700
        else { return false }
        return true
    }

    private static func isHexIdentifier(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit }
    }
}

enum ScanSupervisor {
    static func scan(executableURL: URL, dataDirectory: URL, timeout: TimeInterval = 10) throws -> NormalizedUsageState {
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

    private static func decodeEnvelope(_ data: Data, generation: String) throws -> NormalizedUsageState {
        guard
            data.count <= ScanWorker.maximumResultBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(["schemaVersion", "generation", "state"]),
            object["schemaVersion"] as? Int == 1,
            object["generation"] as? String == generation,
            let state = object["state"] as? [String: Any]
        else { throw CoreError.invalidData }
        return try normalizedState(from: state)
    }

    private static func normalizedState(from object: [String: Any]) throws -> NormalizedUsageState {
        guard
            object["schemaVersion"] as? Int == 1,
            object["sourceKind"] as? String == "local-session-observation",
            let rawClassification = object["classification"] as? String,
            let classification = UsageClassification(rawValue: rawClassification),
            let metricsObject = object["metrics"] as? [String: Any]
        else { throw CoreError.invalidData }
        func optionalString(_ key: String, token: Bool = false) throws -> String? {
            guard let raw = object[key] else { throw CoreError.invalidData }
            if raw is NSNull { return nil }
            guard let text = raw as? String, text.count <= 64, !token || validToken(text) else { throw CoreError.invalidData }
            return text
        }
        func metric(_ key: String, maximum: Int = 100_000) throws -> Int {
            guard let value = metricsObject[key] as? Int, value >= 0, value <= maximum else { throw CoreError.invalidData }
            return value
        }
        let selected = try optionalString("selectedWindow")
        if let selected, selected != "primary" && selected != "secondary" { throw CoreError.invalidData }
        let observed: Int64?
        if object["observedAt"] is NSNull { observed = nil }
        else if let number = object["observedAt"] as? NSNumber { observed = Int64(number.stringValue) }
        else { throw CoreError.invalidData }
        let metrics = ScanMetrics(
            validEventCount: try metric("validEventCount"),
            malformedLineCount: try metric("malformedLineCount"),
            unknownEventCount: try metric("unknownEventCount"),
            readFailureCount: try metric("readFailureCount"),
            candidateFileCount: try metric("candidateFileCount", maximum: 60),
            limitWindowCount: try metric("limitWindowCount", maximum: 2)
        )
        return NormalizedUsageState(
            classification: classification,
            selectedWindow: selected,
            remainingPercent: try optionalString("remainingPercent"),
            cumulativeTokens: try optionalString("cumulativeTokens", token: true),
            cacheHitTokens: try optionalString("cacheHitTokens", token: true),
            cacheMissTokens: try optionalString("cacheMissTokens", token: true),
            contextTokens: try optionalString("contextTokens", token: true),
            contextLimit: try optionalString("contextLimit", token: true),
            contextPercent: try optionalString("contextPercent"),
            inputPercent: try optionalString("inputPercent"),
            outputPercent: try optionalString("outputPercent"),
            reasoningOutputPercent: try optionalString("reasoningOutputPercent"),
            observedAt: observed,
            metrics: metrics
        )
    }
}

enum ApplicationPaths {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexUsageWidget", isDirectory: true)
    }
}
