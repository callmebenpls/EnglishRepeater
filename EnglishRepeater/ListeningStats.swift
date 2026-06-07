import Foundation
import Combine

/// Listening-time stats persisted to UserDefaults.
///
/// Stores raw seconds (per-day map + lifetime total) and publishes whole-minute values
/// for display. Republishes only when the minute count actually changes, so the UI
/// doesn't churn every 0.25s timer tick.
///
/// Day rollover (e.g. crossing midnight while playing) is handled implicitly: every call
/// to `record` re-reads "today's key" from the device's current local time, so seconds
/// after midnight land in the new day's bucket.
final class ListeningStats: ObservableObject {

    @Published private(set) var todayMinutes: Int = 0
    @Published private(set) var totalMinutes: Int = 0

    // Raw accumulators (seconds). Source of truth.
    private var totalSeconds: Double = 0
    private var dayBuckets: [String: Double] = [:]

    private var ticksSinceFlush = 0

    private static let totalKey = "stats_total_seconds_v1"
    private static let dayKey   = "stats_day_seconds_v1"

    // Cached so we don't allocate a DateFormatter on every 0.25s tick.
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    init() { load() }

    /// Add elapsed seconds to today's bucket and the lifetime total. Cheap; safe to call
    /// from the playback timer every quarter-second.
    func record(seconds: Double) {
        guard seconds > 0 else { return }
        let key = dayFormatter.string(from: Date())
        dayBuckets[key, default: 0] += seconds
        totalSeconds += seconds

        let newToday = Int((dayBuckets[key] ?? 0) / 60)
        let newTotal = Int(totalSeconds / 60)
        if newToday != todayMinutes { todayMinutes = newToday }
        if newTotal != totalMinutes { totalMinutes = newTotal }

        // Persist roughly every 30s (assuming a 0.25s tick) so a crash loses at most that.
        ticksSinceFlush += 1
        if ticksSinceFlush >= 120 {
            ticksSinceFlush = 0
            persist()
        }
    }

    /// Force a synchronous write — call on pause, app background, and terminate.
    func flush() {
        ticksSinceFlush = 0
        Self.write(total: totalSeconds, buckets: dayBuckets)
    }

    // MARK: - Persistence

    private let ioQueue = DispatchQueue(label: "EnglishRepeater.stats.io", qos: .utility)

    /// Periodic save — encode off the main thread from a value snapshot.
    private func persist() {
        let total = totalSeconds
        let buckets = dayBuckets
        ioQueue.async { Self.write(total: total, buckets: buckets) }
    }

    private static func write(total: Double, buckets: [String: Double]) {
        let defaults = UserDefaults.standard
        defaults.set(total, forKey: totalKey)
        if let data = try? JSONEncoder().encode(buckets) {
            defaults.set(data, forKey: dayKey)
        }
    }

    private func load() {
        let defaults = UserDefaults.standard
        totalSeconds = defaults.double(forKey: ListeningStats.totalKey)
        if let data = defaults.data(forKey: ListeningStats.dayKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            dayBuckets = decoded
        }
        let todayKey = dayFormatter.string(from: Date())
        todayMinutes = Int((dayBuckets[todayKey] ?? 0) / 60)
        totalMinutes = Int(totalSeconds / 60)
    }
}
