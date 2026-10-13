import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case vietnamese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System Default"
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .current
        case .english: Locale(identifier: "en")
        case .vietnamese: Locale(identifier: "vi")
        }
    }

    static func preference(_ rawValue: String?) -> AppLanguage {
        guard let rawValue, let language = AppLanguage(rawValue: rawValue) else { return .system }
        return language
    }
}
