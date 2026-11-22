import Foundation

final class SettingsStore {
    private enum Key {
        static let saveCopies = "saveCopies"
        static let saveDirectoryURL = "saveDirectoryURL"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var saveCopies: Bool {
        get { defaults.bool(forKey: Key.saveCopies) }
        set { defaults.set(newValue, forKey: Key.saveCopies) }
    }

    var saveDirectoryURL: URL {
        get {
            defaults.url(forKey: Key.saveDirectoryURL) ?? defaultSaveDirectoryURL
        }
        set {
            defaults.set(newValue, forKey: Key.saveDirectoryURL)
        }
    }

    private var defaultSaveDirectoryURL: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
    }
}
