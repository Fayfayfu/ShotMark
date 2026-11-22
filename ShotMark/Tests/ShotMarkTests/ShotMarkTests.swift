import Testing
@testable import ShotMark

@MainActor @Test
func applicationDelegateCanBeCreated() {
    let delegate = AppDelegate()
    #expect(ObjectIdentifier(type(of: delegate)) == ObjectIdentifier(AppDelegate.self))
}
