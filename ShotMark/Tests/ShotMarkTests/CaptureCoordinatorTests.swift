import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import ShotMark

@Suite(.serialized)
struct CaptureCoordinatorTests {
@MainActor @Test
func appCapturePresenterActivatesBeforeShowingAnError() {
    var events: [String] = []
    let presenter = AppCapturePresenter(
        activate: { events.append("activate") },
        messagePresenter: { message in events.append("alert: \(message)") }
    )

    presenter.show(message: "截图失败，请重试。")

    #expect(events == ["activate", "alert: 截图失败，请重试。"])
}

@MainActor @Test
func appCapturePresenterShowsCopyConfirmationWithoutActivating() {
    var events: [String] = []
    let presenter = AppCapturePresenter(
        activate: { events.append("activate") },
        messagePresenter: { _ in events.append("alert") },
        copyConfirmationPresenter: { _ in events.append("copy-confirmation") }
    )

    presenter.showCopyConfirmation(on: nil)

    #expect(events == ["copy-confirmation"])
}

@Test(arguments: [
    (CaptureCoordinator.State.idle, "开始截图"),
    (.capturing, "正在准备截图…"),
    (.editing, "开始截图")
])
func captureMenuTitleReflectsOnlyTheStartInProgressState(
    state: CaptureCoordinator.State,
    expectedTitle: String
) {
    #expect(CaptureCoordinator.menuTitle(for: state) == expectedTitle)
}

@MainActor @Test
func permissionDeniedShowsScreenRecordingInstructions() async {
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: PermissionDeniedScreenImageProvider(),
        presenter: presenter,
        settingsStore: makeSettingsStore()
    )

    await coordinator.startCapture()

    #expect(presenter.messages == ["请在系统设置中允许 ShotMark 录制屏幕。"])
    #expect(coordinator.state == .idle)
}

@MainActor @Test
func startupTimeoutShowsRecoveryInstructions() async {
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: TimedOutScreenImageProvider(),
        presenter: presenter,
        settingsStore: makeSettingsStore()
    )

    await coordinator.startCapture()

    #expect(presenter.messages == ["截图启动超时，请重试。"])
    #expect(coordinator.state == .idle)
}

@MainActor @Test
func coordinatorWatchdogRecoversAHungProviderAndAllowsAnotherStart() async {
    let provider = MultiSuspendedScreenImageProvider()
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: provider,
        presenter: presenter,
        settingsStore: makeSettingsStore(),
        captureRecoveryTimeout: .milliseconds(10)
    )

    let firstCapture = Task { await coordinator.startCapture() }
    #expect(await eventually { provider.captureCount == 1 })
    #expect(await eventually { coordinator.state == .idle })
    #expect(presenter.messages == ["截图启动超时，请重试。"])

    provider.resume(request: 0, throwing: CaptureError.noDisplays)
    await firstCapture.value
    #expect(presenter.messages.count == 1)

    let secondCapture = Task { await coordinator.startCapture() }
    #expect(await eventually { provider.captureCount == 2 })
    provider.resume(request: 1, throwing: CaptureError.noDisplays)
    await secondCapture.value

    #expect(coordinator.state == .idle)
    #expect(presenter.messages.last == "未找到可截图的显示器。")
}

@MainActor @Test
func failedCaptureReportsProgressThenReturnsMenuToReadyState() async {
    let provider = SuspendedScreenImageProvider()
    var observedStates: [CaptureCoordinator.State] = []
    let coordinator = CaptureCoordinator(
        imageProvider: provider,
        presenter: CapturePresenterSpy(),
        settingsStore: makeSettingsStore(),
        onStateChange: { observedStates.append($0) }
    )

    let capture = Task { await coordinator.startCapture() }
    let didSuspend = await eventually { provider.continuation != nil }
    #expect(didSuspend)
    guard didSuspend else { return }
    #expect(CaptureCoordinator.menuTitle(for: coordinator.state) == "正在准备截图…")

    provider.continuation?.resume(throwing: CaptureError.noDisplays)
    await capture.value

    #expect(observedStates == [.capturing, .idle])
    #expect(CaptureCoordinator.menuTitle(for: coordinator.state) == "开始截图")
}

@MainActor @Test
func deniedAuthorizationRequestStopsBeforeLoadingShareableContent() async {
    var requestCount = 0
    var didLoadContent = false
    let provider = ScreenImageProvider(
        permissionChecker: { false },
        authorizationRequester: {
            requestCount += 1
            return false
        },
        contentLoader: {
            didLoadContent = true
            throw TestFailure.writerFailed
        }
    )

    do {
        _ = try await provider.captureDisplays()
        Issue.record("A denied authorization request must fail before invoking ScreenCaptureKit")
    } catch CaptureError.permissionDenied {
        // Expected.
    } catch {
        Issue.record("A denied authorization request must use the existing permission message path")
    }
    #expect(requestCount == 1)
    #expect(!didLoadContent)
}

@MainActor @Test
func grantedAuthorizationRequestContinuesToLoadShareableContent() async {
    var requestCount = 0
    var didLoadContent = false
    let provider = ScreenImageProvider(
        permissionChecker: { false },
        authorizationRequester: {
            requestCount += 1
            return true
        },
        contentLoader: {
            didLoadContent = true
            throw TestFailure.writerFailed
        }
    )

    do {
        _ = try await provider.captureDisplays()
        Issue.record("The test loader must fail after a granted authorization request")
    } catch {
        // The loader's failure proves that the authorization request continued into ScreenCaptureKit.
    }

    #expect(requestCount == 1)
    #expect(didLoadContent)
}

@MainActor @Test
func creatingScreenProviderDoesNotRequestAuthorizationBeforeCaptureStarts() {
    var requestCount = 0
    _ = ScreenImageProvider(
        permissionChecker: { false },
        authorizationRequester: {
            requestCount += 1
            return false
        }
    )

    #expect(requestCount == 0)
}

@MainActor @Test
func screenProviderTimesOutWhenShareableContentNeverArrives() async {
    let provider = ScreenImageProvider(
        permissionChecker: { true },
        contentLoader: {
            try await withCheckedThrowingContinuation { (_: CheckedContinuation<SCShareableContent, any Error>) in }
        },
        captureTimeout: .milliseconds(10)
    )

    do {
        _ = try await provider.captureDisplays()
        Issue.record("A hung ScreenCaptureKit request must time out")
    } catch CaptureError.captureTimedOut {
        // Expected.
    } catch {
        Issue.record("Hung ScreenCaptureKit requests must use the startup-timeout error")
    }
}

@MainActor @Test
func successfulCaptureRetainsOverlaysAndIgnoresStartsUntilCancelled() async throws {
    _ = NSApplication.shared
    let captures = try displayCaptures()
    let provider = SuccessfulScreenImageProvider(images: captures)
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: provider,
        presenter: presenter,
        settingsStore: makeSettingsStore()
    )

    await coordinator.startCapture()

    #expect(coordinator.state == .editing)
    #expect(presenter.overlays.count == captures.count)
    #expect(provider.captureCount == 1)

    await coordinator.startCapture()
    #expect(provider.captureCount == 1)

    let overlay = try #require(presenter.overlays.first)
    overlay.overlayDelegate?.overlayDidCancel()
    #expect(coordinator.state == .idle)
}

@MainActor @Test
func copiedOCRTextClosesAllOverlaysAndShowsConfirmation() async throws {
    _ = NSApplication.shared
    let captures = try displayCaptures()
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: captures),
        presenter: presenter,
        settingsStore: makeSettingsStore()
    )

    await coordinator.startCapture()
    let overlay = try #require(presenter.overlays.first)

    overlay.overlayDelegate?.overlayDidCopyOCRText(on: overlay.screen)

    #expect(coordinator.state == .idle)
    #expect(presenter.overlays.allSatisfy { !$0.isVisible })
    #expect(presenter.copyConfirmationCount == 1)
}

@MainActor @Test
func startWhileCapturingIsIgnoredAndErrorReturnsToIdle() async {
    let provider = SuspendedScreenImageProvider()
    let coordinator = CaptureCoordinator(
        imageProvider: provider,
        presenter: CapturePresenterSpy(),
        settingsStore: makeSettingsStore()
    )

    let capture = Task { await coordinator.startCapture() }
    let didSuspend = await eventually { provider.continuation != nil }
    #expect(didSuspend)
    guard didSuspend else { return }

    await coordinator.startCapture()
    #expect(provider.captureCount == 1)

    provider.continuation?.resume(throwing: CaptureError.noDisplays)
    await capture.value
    #expect(coordinator.state == .idle)
}

@MainActor @Test
func finishCopiesPNGAndDoesNotSaveWhenCopiesAreDisabled() async throws {
    let saveDirectory = temporaryDirectory(named: "disabled")
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: saveDirectory) }
    let settings = makeSettingsStore()
    settings.saveCopies = false
    settings.saveDirectoryURL = saveDirectory
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotMarkTests.\(UUID().uuidString)"))
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: presenter,
        settingsStore: settings,
        pasteboard: pasteboard
    )

    coordinator.finish(image: makeBitmapImage())

    let pngData = try #require(pasteboard.data(forType: .png))
    #expect(Array(pngData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    #expect(NSBitmapImageRep(data: pngData) != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: saveDirectory.path).isEmpty)
    #expect(coordinator.state == .idle)
}

@MainActor @Test
func finishSavesTimestampedPNGWhenCopiesAreEnabled() throws {
    let saveDirectory = temporaryDirectory(named: "enabled")
    defer { try? FileManager.default.removeItem(at: saveDirectory) }
    let settings = makeSettingsStore()
    settings.saveCopies = true
    settings.saveDirectoryURL = saveDirectory
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: presenter,
        settingsStore: settings,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ShotMarkTests.\(UUID().uuidString)")),
        timestampProvider: { "20260819-123456" }
    )

    coordinator.finish(image: makeBitmapImage())

    let savedURL = saveDirectory.appendingPathComponent("ShotMark-20260819-123456.png")
    let savedData = try Data(contentsOf: savedURL)
    #expect(Array(savedData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    #expect(NSBitmapImageRep(data: savedData) != nil)
    #expect(coordinator.state == .idle)
    #expect(presenter.messages.isEmpty)
}

@Test
func screenProviderMapsUserDeclinedSeparatelyFromOtherErrors() {
    let declined = NSError(
        domain: SCStreamErrorDomain,
        code: SCStreamError.userDeclined.rawValue
    )
    let other = NSError(domain: "ShotMarkTests", code: 41)

    if case .permissionDenied = ScreenImageProvider.captureError(for: declined) {
        // Expected.
    } else {
        Issue.record("SCStreamError.userDeclined must map to permissionDenied")
    }

    if case .captureFailed = ScreenImageProvider.captureError(for: other) {
        // Expected.
    } else {
        Issue.record("Non-permission failures must remain distinct")
    }
}

@Test(arguments: [SCStreamError.Code.noDisplayList, .noCaptureSource])
func screenProviderMapsMissingDisplayFrameworkErrors(_ streamError: SCStreamError.Code) {
    let error = NSError(domain: SCStreamErrorDomain, code: streamError.rawValue)

    if case .noDisplays = ScreenImageProvider.captureError(for: error) {
        // Expected.
    } else {
        Issue.record("Missing-display ScreenCaptureKit errors must map to noDisplays")
    }
}

@MainActor @Test
func shareableContentLoadingMissingDisplayMapsToNoDisplays() async {
    let provider = ScreenImageProvider(
        permissionChecker: { true },
        contentLoader: {
            throw NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.noCaptureSource.rawValue
            )
        }
    )

    do {
        _ = try await provider.captureDisplays()
        Issue.record("A missing capture source must not return display images")
    } catch CaptureError.noDisplays {
        // Expected.
    } catch {
        Issue.record("Shareable-content loading errors must use the noDisplays mapping")
    }
}

@Test
func retinaCaptureDimensionsUseNativePixelsAndLogicalImageSize() throws {
    let dimensions = try #require(ScreenImageProvider.captureDimensions(
        contentRect: CGRect(x: 10, y: 20, width: 1512, height: 982),
        pointPixelScale: 2
    ))

    #expect(dimensions.pixelWidth == 3024)
    #expect(dimensions.pixelHeight == 1964)
    #expect(dimensions.logicalSize == NSSize(width: 1512, height: 982))
}

@Test
func mismatchedDisplayTopologyIsRejected() {
    do {
        try CaptureCoordinator.validateDisplayTopology(
            capturedDisplayIDs: [CGDirectDisplayID(11), CGDirectDisplayID(12)],
            activeDisplayIDs: [CGDirectDisplayID(11)]
        )
        Issue.record("A partial overlay set must not be presented")
    } catch CaptureError.displayTopologyChanged {
        // Expected.
    } catch {
        Issue.record("Topology mismatch must have its own error")
    }
}

@MainActor @Test
func saveFailureDismissesOverlaysBeforePresentingError() async throws {
    _ = NSApplication.shared
    let presenter = CapturePresenterSpy()
    let settings = makeSettingsStore()
    settings.saveCopies = true
    settings.saveDirectoryURL = temporaryDirectory(named: "writer-failure")
    var coordinator: CaptureCoordinator!
    var stateWhenMessageWasShown: CaptureCoordinator.State?
    var retainedOverlayCountWhenMessageWasShown: Int?
    presenter.onMessage = { _ in
        stateWhenMessageWasShown = coordinator.state
        retainedOverlayCountWhenMessageWasShown = presenter.overlays.count
    }
    coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: try displayCaptures()),
        presenter: presenter,
        settingsStore: settings,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ShotMarkTests.\(UUID().uuidString)")),
        saveCopyWriter: { _, _ in throw TestFailure.writerFailed }
    )
    await coordinator.startCapture()
    #expect(coordinator.state == .editing)

    coordinator.finish(image: makeBitmapImage())

    #expect(presenter.messages.last == "截图已复制，但保存副本失败。")
    #expect(stateWhenMessageWasShown == .idle)
    #expect(retainedOverlayCountWhenMessageWasShown == 0)
}

@MainActor @Test
func pasteboardRejectionIsPresentedToTheUser() {
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: presenter,
        settingsStore: makeSettingsStore(),
        pasteboardWriter: { _ in false }
    )

    coordinator.finish(image: makeBitmapImage())

    #expect(presenter.messages == ["无法将截图复制到剪贴板。"])
    #expect(coordinator.state == .idle)
}

@Test
func completionMessagesDescribeCopyAndSaveOutcomesTruthfully() {
    #expect(CaptureCoordinator.completionMessage(copied: true, saveOutcome: .notRequested) == nil)
    #expect(CaptureCoordinator.completionMessage(copied: false, saveOutcome: .notRequested) == "无法将截图复制到剪贴板。")
    #expect(CaptureCoordinator.completionMessage(copied: true, saveOutcome: .succeeded) == nil)
    #expect(CaptureCoordinator.completionMessage(copied: false, saveOutcome: .succeeded) == "截图副本已保存，但无法复制到剪贴板。")
    #expect(CaptureCoordinator.completionMessage(copied: true, saveOutcome: .failed) == "截图已复制，但保存副本失败。")
    #expect(CaptureCoordinator.completionMessage(copied: false, saveOutcome: .failed) == "无法复制截图，且保存副本失败。")
}

@MainActor @Test
func copyFailureAndSaveSuccessPresentSavedCopyMessage() throws {
    let saveDirectory = temporaryDirectory(named: "copy-failed-save-succeeded")
    defer { try? FileManager.default.removeItem(at: saveDirectory) }
    let settings = makeSettingsStore()
    settings.saveCopies = true
    settings.saveDirectoryURL = saveDirectory
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: presenter,
        settingsStore: settings,
        pasteboardWriter: { _ in false },
        timestampProvider: { "20260819-123456" }
    )

    coordinator.finish(image: makeBitmapImage())

    #expect(presenter.messages == ["截图副本已保存，但无法复制到剪贴板。"])
    #expect(FileManager.default.fileExists(
        atPath: saveDirectory.appendingPathComponent("ShotMark-20260819-123456.png").path
    ))
}

@MainActor @Test
func copyAndSaveFailurePresentOneCombinedMessage() {
    let settings = makeSettingsStore()
    settings.saveCopies = true
    settings.saveDirectoryURL = temporaryDirectory(named: "copy-and-save-failed")
    let presenter = CapturePresenterSpy()
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: presenter,
        settingsStore: settings,
        pasteboardWriter: { _ in false },
        saveCopyWriter: { _, _ in throw TestFailure.writerFailed }
    )

    coordinator.finish(image: makeBitmapImage())

    #expect(presenter.messages == ["无法复制截图，且保存副本失败。"])
}

@MainActor @Test
func saveCopyUsesSuffixWhenTimestampFilenameAlreadyExists() throws {
    let saveDirectory = temporaryDirectory(named: "collision")
    try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: saveDirectory) }
    let existingURL = saveDirectory.appendingPathComponent("ShotMark-20260819-123456.png")
    try Data("existing".utf8).write(to: existingURL)
    let settings = makeSettingsStore()
    settings.saveCopies = true
    settings.saveDirectoryURL = saveDirectory
    let coordinator = CaptureCoordinator(
        imageProvider: SuccessfulScreenImageProvider(images: [:]),
        presenter: CapturePresenterSpy(),
        settingsStore: settings,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ShotMarkTests.\(UUID().uuidString)")),
        timestampProvider: { "20260819-123456" }
    )

    coordinator.finish(image: makeBitmapImage())

    let suffixedURL = saveDirectory.appendingPathComponent("ShotMark-20260819-123456-1.png")
    let savedData = try Data(contentsOf: suffixedURL)
    #expect(NSBitmapImageRep(data: savedData) != nil)
    #expect(try Data(contentsOf: existingURL) == Data("existing".utf8))
}

@Test
func defaultSaveWriterRefusesToOverwriteExistingFile() throws {
    let directory = temporaryDirectory(named: "default-writer-no-overwrite")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("capture.png")
    let original = Data("original".utf8)
    try original.write(to: url)
    var rejectedOverwrite = false

    do {
        try CaptureCoordinator.writeSaveCopy(Data("replacement".utf8), to: url)
    } catch {
        rejectedOverwrite = true
    }

    #expect(rejectedOverwrite)
    #expect(try Data(contentsOf: url) == original)
}

@MainActor @Test
func appDelegateStartCaptureInvokesCoordinator() async {
    let provider = SuccessfulScreenImageProvider(images: [:])
    let coordinator = CaptureCoordinator(
        imageProvider: provider,
        presenter: CapturePresenterSpy(),
        settingsStore: makeSettingsStore()
    )
    let delegate = AppDelegate(captureCoordinator: coordinator)

    delegate.startCapture()
    let didStart = await eventually { provider.captureCount == 1 }

    #expect(didStart)
}
}

@MainActor
private struct PermissionDeniedScreenImageProvider: ScreenImageProviding {
    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        throw CaptureError.permissionDenied
    }
}

@MainActor
private struct TimedOutScreenImageProvider: ScreenImageProviding {
    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        throw CaptureError.captureTimedOut
    }
}

@MainActor
private final class SuccessfulScreenImageProvider: ScreenImageProviding {
    let images: [CGDirectDisplayID: NSImage]
    private(set) var captureCount = 0

    init(images: [CGDirectDisplayID: NSImage]) {
        self.images = images
    }

    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        captureCount += 1
        return images
    }
}

@MainActor
private final class SuspendedScreenImageProvider: ScreenImageProviding {
    private(set) var captureCount = 0
    var continuation: CheckedContinuation<[CGDirectDisplayID: NSImage], any Error>?

    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        captureCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class MultiSuspendedScreenImageProvider: ScreenImageProviding {
    private(set) var captureCount = 0
    private var continuations: [Int: CheckedContinuation<[CGDirectDisplayID: NSImage], any Error>] = [:]

    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        let request = captureCount
        captureCount += 1
        return try await withCheckedThrowingContinuation { continuations[request] = $0 }
    }

    func resume(request: Int, throwing error: any Error) {
        continuations.removeValue(forKey: request)?.resume(throwing: error)
    }
}

@MainActor
private final class CapturePresenterSpy: CapturePresenting {
    private(set) var messages: [String] = []
    private(set) var copyConfirmationCount = 0
    private var weakOverlays: [WeakOverlay] = []
    var onMessage: ((String) -> Void)?

    var overlays: [SelectionOverlayWindow] {
        weakOverlays.compactMap(\.window)
    }

    func show(message: String) {
        messages.append(message)
        onMessage?(message)
    }

    func show(overlays: [SelectionOverlayWindow]) {
        weakOverlays = overlays.map(WeakOverlay.init)
    }

    func showCopyConfirmation(on screen: NSScreen?) {
        copyConfirmationCount += 1
    }
}

private enum TestFailure: Error {
    case writerFailed
}

@MainActor
private final class WeakOverlay {
    weak var window: SelectionOverlayWindow?

    init(_ window: SelectionOverlayWindow) {
        self.window = window
    }
}

@MainActor
private func displayCaptures() throws -> [CGDirectDisplayID: NSImage] {
    let pairs: [(CGDirectDisplayID, NSImage)] = NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return (displayID, NSImage(size: screen.frame.size))
    }
    let captures = Dictionary(uniqueKeysWithValues: pairs)
    #expect(!captures.isEmpty)
    return captures
}

private func makeSettingsStore() -> SettingsStore {
    let suiteName = "ShotMarkTests.CaptureCoordinator.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return SettingsStore(defaults: defaults)
}

private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ShotMarkTests-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func makeBitmapImage() -> NSImage {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.setColor(.systemRed, atX: 0, y: 0)
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.addRepresentation(bitmap)
    return image
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
