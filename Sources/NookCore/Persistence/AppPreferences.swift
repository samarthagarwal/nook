import Foundation

/// Lightweight app preferences backed by UserDefaults.
public enum AppPreferences {
    private enum Key {
        static let onboardingComplete  = "nook.onboarding.complete"
        static let activeTierId        = "nook.models.activeTierId"
        static let downloadedTierIds   = "nook.models.downloadedTierIds"
        // Cloud inference
        static let cloudEnabled        = "nook.inference.cloudEnabled"
        static let openAIAPIKey        = "nook.inference.openAIKey"
        static let openAIModel         = "nook.inference.openAIModel"
    }

    // MARK: - Cloud inference settings

    public static let availableOpenAIModels: [(id: String, label: String)] = [
        ("gpt-4o",       "GPT-4o"),
        ("gpt-4o-mini",  "GPT-4o mini"),
        ("o1",           "o1"),
        ("o1-mini",      "o1 mini"),
        ("o3-mini",      "o3 mini"),
    ]

    public static let defaultOpenAIModel = "gpt-4o-mini"

    public static var cloudEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.cloudEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.cloudEnabled) }
    }

    public static var openAIAPIKey: String {
        get { UserDefaults.standard.string(forKey: Key.openAIAPIKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.openAIAPIKey) }
    }

    public static var openAIModel: String {
        get { UserDefaults.standard.string(forKey: Key.openAIModel) ?? defaultOpenAIModel }
        set { UserDefaults.standard.set(newValue, forKey: Key.openAIModel) }
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

    public static func markOnboardingComplete(chosenTier: ModelTier) {
        activeTier = chosenTier
        isOnboardingComplete = true
    }
}
