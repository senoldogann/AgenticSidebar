import Foundation

/// “2 minutes ago”, formatted once per bucket instead of once per frame.
///
/// The sidebar renders on every state change of the session service, which during
/// a turn is many times a second, and each visible row was formatting its own
/// relative date: Foundation's relative formatting is not cheap, and the answer
/// for a given minute does not change. Rounding to a bucket makes the result
/// cacheable, and the cache is bounded so an app left open for days does not
/// accumulate one entry per timestamp ever seen.
@MainActor
enum RelativeTimestamp {
    /// A minute: coarser than the formatter's own steps, fine enough that the
    /// sidebar never contradicts the timestamps it labels.
    static let bucketInterval: TimeInterval = 60

    static let maximumCachedEntries = 256

    private static var cache: [Date: String] = [:]
    private static var recency: [Date] = []

    static func bucket(_ date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / bucketInterval).rounded(.down)
                * bucketInterval
        )
    }

    static func text(for date: Date) -> String {
        let key = bucket(date)

        if let cached = cache[key] {
            return cached
        }

        let formatted = key.formatted(.relative(presentation: .named))
        cache[key] = formatted
        recency.append(key)

        while recency.count > maximumCachedEntries {
            let oldest = recency.removeFirst()
            cache[oldest] = nil
        }

        return formatted
    }

    /// Used by the tests to start from a known state.
    static func reset() {
        cache.removeAll()
        recency.removeAll()
    }

    static var cachedEntryCount: Int {
        cache.count
    }
}
