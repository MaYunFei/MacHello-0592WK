import Foundation
import Combine
import AppKit

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en = "en"
    case zh = "zh-Hans"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return LanguageManager.shared.isChinese ? "跟随系统 (System Default)" : "System Default"
        case .en:
            return "English"
        case .zh:
            return "简体中文"
        }
    }
}

public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    public static let languageDidChangeNotification = Notification.Name("com.machello.languageDidChange")

    @Published public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "com.machello.appLanguage")
            NotificationCenter.default.post(name: LanguageManager.languageDidChangeNotification, object: selectedLanguage)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "com.machello.appLanguage") ?? "system"
        self.selectedLanguage = AppLanguage(rawValue: saved) ?? .system
    }

    public var isChinese: Bool {
        switch selectedLanguage {
        case .zh:
            return true
        case .en:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh")
        }
    }

    public var currentDisplayName: String {
        selectedLanguage.title
    }

    public func localized(_ en: String, _ zh: String) -> String {
        return isChinese ? zh : en
    }
}

/// Global convenience function for inline localization
public func loc(_ en: String, _ zh: String) -> String {
    return LanguageManager.shared.localized(en, zh)
}
