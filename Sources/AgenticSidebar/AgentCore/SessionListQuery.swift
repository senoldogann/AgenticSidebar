import Foundation

/// Kenar çubuğundaki oturum listesi için sıralama seçenekleri.
enum SessionSortOption: String, CaseIterable, Sendable {
    case lastUsedNewest
    case createdNewest
    case createdOldest
    case alphabetical

    /// Menüde gösterilen ad.
    var displayName: String {
        switch self {
        case .lastUsedNewest:
            "Last used"
        case .createdNewest:
            "Newest first"
        case .createdOldest:
            "Oldest first"
        case .alphabetical:
            "Alphabetical"
        }
    }
}

/// Referans zamana (`lastMessageAt ?? completedAt ?? createdAt`) göre tarih filtresi.
enum SessionDateFilter: String, CaseIterable, Sendable {
    case all
    case today
    case last7Days
    case last30Days
    case older

    /// Menüde/chip'te gösterilen ad.
    var displayName: String {
        switch self {
        case .all:
            "All"
        case .today:
            "Today"
        case .last7Days:
            "Last 7 days"
        case .last30Days:
            "Last 30 days"
        case .older:
            "Older"
        }
    }
}

/// View'dan bağımsız saf liste mantığı: arama + tarih filtresi + sıralama.
///
/// Sabitliler her sıralamada üstte kalır; grup içi sıra seçilen `sort` ile
/// belirlenir. Eşit zamanlarda `createdAt desc, id` ile deterministik kırılır.
func filterSortSessions(
    _ sessions: [SessionSummary],
    query: String,
    sort: SessionSortOption,
    dateFilter: SessionDateFilter,
    now: Date,
    calendar: Calendar
) -> [SessionSummary] {
    filterSortSessions(
        sessions,
        query: query,
        sort: sort,
        dateFilter: dateFilter,
        now: now,
        calendar: calendar,
        pinnedFirst: true
    )
}

/// Pin grubunu kapatmak isteyen çağrılar için (örn. section'lara bölünmüş UI).
func filterSortSessions(
    _ sessions: [SessionSummary],
    query: String,
    sort: SessionSortOption,
    dateFilter: SessionDateFilter,
    now: Date,
    calendar: Calendar,
    pinnedFirst: Bool
) -> [SessionSummary] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    var filtered = sessions
    if !trimmedQuery.isEmpty {
        filtered = filtered.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.qualifiedTitle.localizedCaseInsensitiveContains(trimmedQuery)
                || ($0.workingDirectoryName?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    filtered = filtered.filter {
        matchesDateFilter($0.referenceDate, filter: dateFilter, now: now, calendar: calendar)
    }

    return filtered.sorted { lhs, rhs in
        if pinnedFirst, lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        switch sort {
        case .alphabetical:
            let comparison = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        case .createdNewest:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        case .createdOldest:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
        case .lastUsedNewest:
            if lhs.referenceDate != rhs.referenceDate {
                return lhs.referenceDate > rhs.referenceDate
            }
        }
        // Kararsızlığı önlemek için deterministik kırılma.
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Tek bir tarihin seçili filtreye uyup uymadığı.
///
/// - `today`: takvim gününe göre bugün.
/// - `last7Days` / `last30Days`: son N gün (bugün dahil).
/// - `older`: 30 günden eski.
func matchesDateFilter(
    _ date: Date,
    filter: SessionDateFilter,
    now: Date,
    calendar: Calendar
) -> Bool {
    switch filter {
    case .all:
        return true
    case .today:
        return calendar.isDate(date, inSameDayAs: now)
    case .last7Days:
        guard let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return date >= cutoff && date <= now.addingTimeInterval(60)
    case .last30Days:
        guard let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return date >= cutoff && date <= now.addingTimeInterval(60)
    case .older:
        guard let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return date < cutoff
    }
}
