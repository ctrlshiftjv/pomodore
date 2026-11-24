import Foundation

struct CompletedSession: Codable, Equatable, Sendable {
    let endedAt: Date
    /// What the duration setting was when the phase was loaded. A bare count of sessions
    /// is ambiguous once the setting changes.
    let plannedDuration: TimeInterval
    /// Stored exactly as typed. Normalization happens at read time, for grouping only.
    let tag: String?
}

/// Tags are typed by hand, so they drift. `writing`, `Writing` and `writing ` are the same
/// piece of work and have to group together.
enum Tag {
    static let untagged = "Untagged"

    /// Trim, collapse inner runs of whitespace. Blank becomes `nil`, never `""`.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Grouping key. A real tag can never normalize to empty, so `""` is free to mean
    /// untagged.
    static func key(_ raw: String?) -> String {
        normalized(raw)?.lowercased() ?? ""
    }
}

struct TagTotal: Identifiable, Equatable {
    /// `nil` renders as `Untagged` and always sorts last.
    let label: String?
    let count: Int
    let duration: TimeInterval

    var id: String { label.map { "t:\($0)" } ?? "" }
    var displayLabel: String { label ?? Tag.untagged }

    /// Clamped, not just converted. `Int(Double)` traps on a value past `Int.max`, and
    /// `plannedDuration` comes off disk: a hand-edited `1e300` decodes perfectly well and
    /// would then crash the breakdown. The file is meant to degrade, not to detonate.
    var minutes: Int {
        let value = (duration / 60).rounded()
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), Double(Int.max / 2)))
    }
}

/// Append-only log of focus sessions that actually completed.
///
/// A single JSON array rather than SwiftData: the data is append-only, never queried in
/// anger, and a year of heavy use is tens of kilobytes. It is inspectable with `cat`,
/// trivially backed up, and carries no schema or container lifecycle.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [CompletedSession] = []

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let clock: () -> Date

    init(url: URL = SessionStore.defaultURL(), clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "Pomodore"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    // MARK: - Recording

    /// Only focus phases, and only when they reached their deadline. A history that counts
    /// skips is worthless for the one thing it is for.
    func record(_ transition: Transition) {
        guard transition.ended == .focus, transition.completedNaturally else { return }
        sessions.append(CompletedSession(
            endedAt: clock(),
            plannedDuration: transition.plannedDuration,
            tag: transition.tag
        ))
        save()
    }

    // MARK: - Derived

    var today: [CompletedSession] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: clock())
        return sessions.filter { calendar.isDate($0.endedAt, inSameDayAs: start) }
    }

    /// Consecutive days, counting back from today, with at least one completed session.
    ///
    /// Today being empty does not break the streak until the day is over, or it would
    /// read zero every morning, which is both wrong and demoralizing.
    var streak: Int {
        let calendar = Calendar.current
        let days = Set(sessions.map { calendar.startOfDay(for: $0.endedAt) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: clock())
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = yesterday
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Today's sessions grouped case-insensitively, labelled with the first casing seen
    /// today, sorted by count then recency, untagged always last.
    var todayByTag: [TagTotal] {
        struct Bucket {
            var label: String?
            var count = 0
            var duration: TimeInterval = 0
            var last = Date.distantPast
        }

        var order: [String] = []
        var buckets: [String: Bucket] = [:]

        for session in today.sorted(by: { $0.endedAt < $1.endedAt }) {
            let key = Tag.key(session.tag)
            // First casing seen today wins the label.
            var bucket = buckets[key] ?? {
                order.append(key)
                return Bucket(label: Tag.normalized(session.tag))
            }()
            bucket.count += 1
            bucket.duration += session.plannedDuration
            bucket.last = max(bucket.last, session.endedAt)
            buckets[key] = bucket
        }

        return order
            .compactMap { buckets[$0] }
            .sorted { left, right in
                if (left.label == nil) != (right.label == nil) { return right.label == nil }
                if left.count != right.count { return left.count > right.count }
                return left.last > right.last
            }
            .map { TagTotal(label: $0.label, count: $0.count, duration: $0.duration) }
    }

    /// Distinct past tags, newest first, for the popover's recents menu.
    func recentTags(limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions.reversed() {
            guard let label = Tag.normalized(session.tag) else { continue }
            guard seen.insert(Tag.key(session.tag)).inserted else { continue }
            result.append(label)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }  // absent is normal
        do {
            sessions = try Self.decoder.decode([CompletedSession].self, from: data)
        } catch {
            // This is the only state the app cannot regenerate, but losing a session count
            // is still not worth refusing to launch.
            NSLog("Pomodore: could not read \(url.path): \(error). Continuing with no history.")
            sessions = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so an interrupted write leaves the previous good file rather than a
            // truncated one.
            try Self.encoder.encode(sessions).write(to: url, options: .atomic)
        } catch {
            NSLog("Pomodore: could not write \(url.path): \(error)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // So the file stays worth opening with cat.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
