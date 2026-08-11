import AppKit
import CoreFoundation
import Foundation

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
                guard keys.count == 115 else { throw WidgetUIError.invalidResource }
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
