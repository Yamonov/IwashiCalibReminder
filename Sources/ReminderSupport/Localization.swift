import Foundation

private final class LocalizationBundleAnchor: NSObject {}

/// App presentation only. The CLI and machine-readable acquisition data stay in English.
public enum L10n {
    #if DEBUG
    @TaskLocal static var languageOverride: String?
    #endif

    private static let resources: Bundle = {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: LocalizationBundleAnchor.self)
        #endif
    }()
    private static let localizedBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: ["en", "ja"].compactMap { language in
            guard let path = resources.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        })
    }()
    private static let preferredLanguage = Bundle.preferredLocalizations(
        from: ["en", "ja"], forPreferences:
            UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages).first ?? "en"

    public static func text(_ key: String, _ arguments: any CVarArg...) -> String {
        #if DEBUG
        let language = languageOverride ?? preferredLanguage
        #else
        let language = preferredLanguage
        #endif
        let bundle = localizedBundles[language] ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
    }
}
