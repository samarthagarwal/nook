import Foundation

/// Lightweight app preferences backed by UserDefaults.
public enum AppPreferences {
    private enum Key {
        static let onboardingComplete = "nook.onboarding.complete"
        static let activeTierId = "nook.models.activeTierId"
        static let downloadedTierIds = "nook.models.downloadedTierIds"
        static let skipDemoKnowledgeSeed = "nook.knowledge.skipDemoSeed"
    }

    public static var isOnboardingComplete: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboardingComplete) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingComplete) }
    }

    public static var activeTierId: String {
        get {
            UserDefaults.standard.string(forKey: Key.activeTierId)
                ?? ModelTier.standardTiers[0].id
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.activeTierId) }
    }

    public static var activeTier: ModelTier {
        get {
            ModelTier.standardTiers.first { $0.id == activeTierId }
                ?? ModelTier.standardTiers[0]
        }
        set { activeTierId = newValue.id }
    }

    public static var downloadedTierIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.downloadedTierIds) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Key.downloadedTierIds) }
    }

    public static func markTierDownloaded(_ tierId: String) {
        var ids = downloadedTierIds
        ids.insert(tierId)
        downloadedTierIds = ids
    }

    public static func isTierDownloaded(_ tierId: String) -> Bool {
        downloadedTierIds.contains(tierId)
    }

    public static var skipDemoKnowledgeSeed: Bool {
        get { UserDefaults.standard.bool(forKey: Key.skipDemoKnowledgeSeed) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skipDemoKnowledgeSeed) }
    }

    public static func markOnboardingComplete(chosenTier: ModelTier) {
        activeTier = chosenTier
        isOnboardingComplete = true
    }
}
