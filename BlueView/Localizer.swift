import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    /// 選單中一律用該語言自己的名稱顯示，切換後才找得回來。
    var displayName: String {
        switch self {
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }
}

/// App 介面語言。切換後畫面上的文字立即更新，並記住選擇。
@Observable
final class Localizer {
    static let shared = Localizer()
    private static let defaultsKey = "BlueViewLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            // 讓 macOS 內建的選單（編輯、視窗、說明…）在下次開啟 App 時也換成同一種語言
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey), let language = AppLanguage(rawValue: saved) {
            self.language = language
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            self.language = preferred.hasPrefix("en") ? .english : .traditionalChinese
        }
    }
}

/// 依目前語言回傳英文或繁體中文。
func tr(_ english: String, _ chinese: String) -> String {
    Localizer.shared.language == .traditionalChinese ? chinese : english
}
