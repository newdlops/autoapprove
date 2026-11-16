import Foundation
import Darwin

/// GUI-launched MCP hosts often inherit LANG=C or no locale at all.
/// Keep an explicit UTF-8 locale; otherwise use the user's macOS language.
public enum MCPProcessEnvironment {
    public static func locale(environment: [String: String], preferredLanguages: [String]) -> String {
        for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
            if let value = environment[key], value.range(of: #"^[A-Za-z]{2,3}_[A-Za-z]{2}\.(UTF-8|utf8)$"#, options: .regularExpression) != nil {
                return value
            }
        }
        for language in preferredLanguages {
            let locale = Locale(identifier: language)
            guard let code = locale.language.languageCode?.identifier else { continue }
            // Prefer the region in the OS language, with familiar defaults for
            // language-only preferences. Never forward arbitrary locale text.
            let defaults = ["ko": "KR", "en": "US", "ja": "JP", "zh": "CN", "de": "DE", "fr": "FR", "es": "ES", "pt": "BR"]
            guard let region = locale.region?.identifier ?? defaults[code] else { continue }
            let candidate = "\(code)_\(region).UTF-8"
            if candidate.range(of: #"^[a-z]{2,3}_[A-Z]{2}\.UTF-8$"#, options: .regularExpression) != nil { return candidate }
        }
        return "en_US.UTF-8"
    }

    public static func configure() {
        let value = locale(environment: ProcessInfo.processInfo.environment, preferredLanguages: Locale.preferredLanguages)
        // LC_ALL wins over LANG, so update them together for subprocesses too.
        for key in ["LANG", "LC_CTYPE", "LC_ALL"] { setenv(key, value, 1) }
        _ = setlocale(LC_ALL, "")
    }
}
