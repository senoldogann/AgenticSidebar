import Foundation
import Observation

/// Zaman çizelgesindeki grup ve aktivite kartlarının açık/kapalı durumu.
///
/// Eskiden her `AgentActivityTimelineView` bu kümeleri kendi `@State`'inde
/// tutuyordu. Sohbet değişiminde `ScrollView.id(activeSessionID)` tüm alt
/// ağacı yok ettiği için kapatılan kartlar varsayılanına dönüyordu (çalışan
/// turda açık). Bu depo uygulama ömrü boyunca yaşar.
///
/// Anahtarlar oturum-ad-alanlıdır: iki sohbet aynı grup kimliğini taşısa
/// (dal!) bile açık/kapalı durumu karışmaz. Okuma eski çıplak anahtara da
/// düşer (sessiz göç), yazma hep ad-alanlıdır.
@MainActor
@Observable
final class TimelineCollapseStore {
    private(set) var collapsedIDs: Set<String> = []
    private(set) var expandedIDs: Set<String> = []
    private(set) var thinkingManuallyCollapsedGroups: Set<String> = []

    /// Kimlikler UUID olduğu için küme kendiliğinden küçülmez; sınır aşılınca
    /// rastgele budanır. Düşen kayıt yalnız bir kartın açık/kapalı varsayılanı
    /// demektir, veri kaybı değildir.
    private static let maximumStoredKeys = 2000

    static func groupKey(_ groupID: UUID) -> String {
        "grp:\(groupID.uuidString)"
    }

    static func groupKey(_ groupID: UUID, sessionID: UUID) -> String {
        namespacedKey(groupKey(groupID), sessionID: sessionID)
    }

    static func activityKey(_ rawID: String, sessionID: UUID) -> String {
        namespacedKey("act:\(rawID)", sessionID: sessionID)
    }

    static func namespacedKey(_ key: String, sessionID: UUID) -> String {
        "ses:\(sessionID.uuidString):\(key)"
    }

    /// Ad-alanlı okuma yazmadan önce çıplak anahtara da bakar.
    private func contains(_ set: Set<String>, key: String, legacyKey: String) -> Bool {
        set.contains(key) || set.contains(legacyKey)
    }

    func isGroupExpanded(groupID: UUID, sessionID: UUID, isTurnRunning: Bool) -> Bool {
        let key = Self.groupKey(groupID, sessionID: sessionID)
        let legacyKey = Self.groupKey(groupID)
        if contains(collapsedIDs, key: key, legacyKey: legacyKey) {
            return false
        }
        if contains(expandedIDs, key: key, legacyKey: legacyKey) {
            return true
        }
        return isTurnRunning
    }

    func toggleGroup(groupID: UUID, sessionID: UUID, isTurnRunning: Bool) {
        let key = Self.groupKey(groupID, sessionID: sessionID)
        if isGroupExpanded(groupID: groupID, sessionID: sessionID, isTurnRunning: isTurnRunning) {
            expandedIDs.remove(key)
            collapsedIDs.insert(key)
        } else {
            collapsedIDs.remove(key)
            expandedIDs.insert(key)
        }
        pruneIfNeeded()
    }

    func isActivityExpanded(
        _ activity: AgentActivity,
        groupID: UUID,
        sessionID: UUID,
        isTurnRunning: Bool
    ) -> Bool {
        let key = Self.activityKey(activity.id.rawValue, sessionID: sessionID)
        let legacyKey = activity.id.rawValue
        if contains(collapsedIDs, key: key, legacyKey: legacyKey) {
            return false
        }
        if contains(expandedIDs, key: key, legacyKey: legacyKey) {
            return true
        }
        if activity.kind == .subagent, activity.phase == .running {
            return true
        }
        // Boş düşünme varsayılan-açık değildir: içeriksiz kartın otomatik
        // açılması, boş gri "Thought" kutusunu her turda flaşlatıyordu.
        if activity.kind == .thinking,
            isTurnRunning,
            ThinkingDurationPresentation.hasVisibleContent(output: activity.output),
            !contains(
                thinkingManuallyCollapsedGroups,
                key: Self.groupKey(groupID, sessionID: sessionID),
                legacyKey: Self.groupKey(groupID)
            )
        {
            return true
        }
        return false
    }

    func toggleActivity(
        _ activity: AgentActivity,
        groupID: UUID,
        sessionID: UUID,
        isTurnRunning: Bool
    ) {
        let key = Self.activityKey(activity.id.rawValue, sessionID: sessionID)
        let namespacedGroup = Self.groupKey(groupID, sessionID: sessionID)
        if isActivityExpanded(
            activity,
            groupID: groupID,
            sessionID: sessionID,
            isTurnRunning: isTurnRunning
        ) {
            expandedIDs.remove(key)
            collapsedIDs.insert(key)
            if activity.kind == .thinking, isTurnRunning {
                thinkingManuallyCollapsedGroups.insert(namespacedGroup)
            }
        } else {
            collapsedIDs.remove(key)
            expandedIDs.insert(key)
            if activity.kind == .thinking, isTurnRunning {
                thinkingManuallyCollapsedGroups.remove(namespacedGroup)
            }
        }
        pruneIfNeeded()
    }

    private func pruneIfNeeded() {
        guard collapsedIDs.count + expandedIDs.count > Self.maximumStoredKeys else {
            return
        }
        while collapsedIDs.count + expandedIDs.count > Self.maximumStoredKeys {
            if !collapsedIDs.isEmpty {
                collapsedIDs.removeFirst()
            } else {
                expandedIDs.removeFirst()
            }
        }
        while thinkingManuallyCollapsedGroups.count > Self.maximumStoredKeys / 2 {
            thinkingManuallyCollapsedGroups.removeFirst()
        }
    }
}
