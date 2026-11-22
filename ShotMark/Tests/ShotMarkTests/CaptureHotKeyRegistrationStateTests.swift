import Carbon
import Testing
@testable import ShotMark

@Test
func occupiedHotKeyUsesOccupiedMenuTitle() {
    #expect(
        CaptureHotKeyRegistrationState.menuTitle(
            for: .registrationFailed(OSStatus(eventHotKeyExistsErr))
        ) == "开始截图（⌘⇧A 已被占用）"
    )
}

@Test
func otherRegistrationFailureUsesDistinctUnavailableMenuTitle() {
    #expect(
        CaptureHotKeyRegistrationState.menuTitle(for: .registrationFailed(OSStatus(-50)))
            == "开始截图（⌘⇧A 注册失败）"
    )
}

@Test(arguments: [
    (CaptureCoordinator.State.idle, "开始截图（⌘⇧A 已被占用）"),
    (.editing, "开始截图（⌘⇧A 已被占用）"),
    (.capturing, "正在准备截图…")
])
func captureProgressTemporarilyOverridesAndThenRestoresTheHotKeyDiagnostic(
    state: CaptureCoordinator.State,
    expectedTitle: String
) {
    #expect(
        CaptureMenuTitle.menuTitle(
            for: state,
            hotKeyRegistrationDiagnostic: "开始截图（⌘⇧A 已被占用）"
        ) == expectedTitle
    )
}

@Test
func idleStateRestoresTheGenericHotKeyRegistrationFailureDiagnostic() {
    #expect(
        CaptureMenuTitle.menuTitle(
            for: .idle,
            hotKeyRegistrationDiagnostic: "开始截图（⌘⇧A 注册失败）"
        ) == "开始截图（⌘⇧A 注册失败）"
    )
}
