import Foundation
import Observation

/// Settings that belong to the app shell. The interface language lives in `Localization`.
@Observable
final class Preferences {
    /// Show how many records are in progress next to the menu bar icon.
    var showsCount: Bool {
        didSet { defaults.set(showsCount, forKey: Keys.showsCount) }
    }
    /// Toggle the panel from anywhere with Control-Option-T.
    var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Keys.hotkeyEnabled) }
    }
    /// False when the system refused the shortcut, usually because another app holds it.
    var hotkeyRegistered = true

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let showsCount = "showsInProgressCount"
        static let hotkeyEnabled = "hotkeyEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsCount = defaults.bool(forKey: Keys.showsCount)
        hotkeyEnabled = defaults.object(forKey: Keys.hotkeyEnabled) as? Bool ?? true
    }
}
