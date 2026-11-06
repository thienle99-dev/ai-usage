import Foundation

enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        let languageCode = locale.identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init) ?? locale.identifier

        let bundle = Bundle.module.url(forResource: languageCode, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? .module

        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
