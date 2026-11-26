import Foundation

/// The interface language. `system` follows the Mac's preferred language.
nonisolated public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case korean = "ko"
}

nonisolated public enum Localization {
    public static let defaultsKey = "language"

    public static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public static var usesKorean: Bool {
        switch language {
        case .korean: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
    }
}

/// Korean particles change with the sound the word before them ends in. Titles and names are
/// arbitrary text, so the choice is made at run time instead of writing "이(가)".
nonisolated public enum Josa {
    /// `word` with the right particle attached: `Josa.attach("기록", "이", "가")` is "기록이".
    public static func attach(_ word: String, _ afterConsonant: String, _ afterVowel: String) -> String {
        word + pick(word, afterConsonant, afterVowel)
    }

    /// The particle alone, for sentences assembled from styled pieces.
    public static func pick(_ word: String, _ afterConsonant: String, _ afterVowel: String) -> String {
        endsInConsonant(word) ? afterConsonant : afterVowel
    }

    /// Whether the last pronounced character ends in a consonant sound. Trailing punctuation is skipped;
    /// digits are read in Korean; for Latin words only the endings that are consonants in Korean
    /// transliteration count (l, m, n, ng).
    static func endsInConsonant(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        var index = scalars.count - 1
        while index >= 0 {
            let value = scalars[index].value
            if (0xAC00...0xD7A3).contains(value) { return (value - 0xAC00) % 28 != 0 }
            if (48...57).contains(value) { return [0, 1, 3, 6, 7, 8].contains(Int(value) - 48) }
            if (65...90).contains(value) || (97...122).contains(value) {
                let letter = value | 0x20
                if letter == 0x67, index > 0, scalars[index - 1].value | 0x20 == 0x6E { return true }  // "ng"
                return letter == 0x6C || letter == 0x6D || letter == 0x6E  // l, m, n
            }
            index -= 1
        }
        return false
    }
}

/// A user-facing string in both interface languages, written at the call site.
/// The package builds with `swift build` alone and carries no resource bundle, so there is no strings file.
nonisolated public func L(_ english: String, ko korean: String) -> String {
    Localization.usesKorean ? korean : english
}
