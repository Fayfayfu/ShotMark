import Testing
import Foundation
@testable import ShotMark

@Test
func saveCopiesDefaultsToFalse() {
    let defaults = makeSettingsDefaults()
    let store = SettingsStore(defaults: defaults)

    #expect(store.saveCopies == false)
}

@Test
func saveDirectoryURLRoundTripsThroughDefaults() {
    let defaults = makeSettingsDefaults()
    let expectedURL = URL(fileURLWithPath: "/tmp/shotmark-settings-test", isDirectory: true)
    let store = SettingsStore(defaults: defaults)

    store.saveDirectoryURL = expectedURL

    let reloadedStore = SettingsStore(defaults: defaults)
    #expect(reloadedStore.saveDirectoryURL == expectedURL)
}

private func makeSettingsDefaults() -> UserDefaults {
    let suiteName = "ShotMarkTests.SettingsStore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
