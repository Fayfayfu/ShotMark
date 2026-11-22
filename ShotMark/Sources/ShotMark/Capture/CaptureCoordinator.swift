import AppKit

@MainActor
protocol CapturePresenting {
    func show(message: String)
    func show(overlays: [SelectionOverlayWindow])
    func showCopyConfirmation(on screen: NSScreen?)
}

@MainActor
final class AppCapturePresenter: CapturePresenting {
    private let activate: () -> Void
    private let messagePresenter: (String) -> Void
    private let copyConfirmationPresenter: (NSScreen?) -> Void

    init(
        activate: @escaping () -> Void = { NSApp.activate() },
        messagePresenter: @escaping (String) -> Void = { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        },
        copyConfirmationPresenter: @escaping (NSScreen?) -> Void = { screen in
            CopyConfirmationHUD.shared.show(on: screen)
        }
    ) {
        self.activate = activate
        self.messagePresenter = messagePresenter
        self.copyConfirmationPresenter = copyConfirmationPresenter
    }

    func show(message: String) {
        activate()
        messagePresenter(message)
    }

    func show(overlays: [SelectionOverlayWindow]) {
        activate()
        overlays.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    func showCopyConfirmation(on screen: NSScreen?) {
        copyConfirmationPresenter(screen)
    }
}

@MainActor
final class CaptureCoordinator {
    enum State: Equatable {
        case idle
        case capturing
        case editing
    }

    enum SaveCopyOutcome {
        case notRequested
        case succeeded
        case failed
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private let imageProvider: any ScreenImageProviding
    private let presenter: any CapturePresenting
    private let settingsStore: SettingsStore
    private let pasteboardWriter: (Data) -> Bool
    private let timestampProvider: () -> String
    private let saveCopyWriter: (Data, URL) throws -> Void
    private let captureRecoveryTimeout: Duration
    private var overlays: [SelectionOverlayWindow] = []
    private var captureGeneration: UInt64 = 0
    private var captureWatchdog: Task<Void, Never>?

    init(
        imageProvider: any ScreenImageProviding,
        presenter: any CapturePresenting,
        settingsStore: SettingsStore,
        pasteboard: NSPasteboard = .general,
        pasteboardWriter: ((Data) -> Bool)? = nil,
        timestampProvider: @escaping () -> String = CaptureCoordinator.currentTimestamp,
        saveCopyWriter: @escaping (Data, URL) throws -> Void = CaptureCoordinator.writeSaveCopy,
        captureRecoveryTimeout: Duration = .seconds(12),
        onStateChange: ((State) -> Void)? = nil
    ) {
        self.imageProvider = imageProvider
        self.presenter = presenter
        self.settingsStore = settingsStore
        self.pasteboardWriter = pasteboardWriter ?? { data in
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: .png)
        }
        self.timestampProvider = timestampProvider
        self.saveCopyWriter = saveCopyWriter
        self.captureRecoveryTimeout = captureRecoveryTimeout
        self.onStateChange = onStateChange
    }

    func startCapture() async {
        guard state == .idle else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        transition(to: .capturing)
        scheduleCaptureWatchdog(for: generation)

        do {
            let images = try await imageProvider.captureDisplays()
            guard isCurrentCapture(generation) else { return }
            cancelCaptureWatchdog()
            let newOverlays = try makeOverlays(for: images)

            overlays = newOverlays
            transition(to: .editing)
            presenter.show(overlays: newOverlays)
        } catch {
            guard isCurrentCapture(generation) else { return }
            cancelCaptureWatchdog()
            transition(to: .idle)
            presenter.show(message: message(for: error))
        }
    }

    func finish(image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            endEditing()
            presenter.show(message: "无法生成 PNG 截图。")
            return
        }

        endEditing()

        let copied = pasteboardWriter(pngData)
        let saveOutcome: SaveCopyOutcome

        if settingsStore.saveCopies {
            do {
                try FileManager.default.createDirectory(
                    at: settingsStore.saveDirectoryURL,
                    withIntermediateDirectories: true
                )
                let saveURL = availableSaveURL(
                    in: settingsStore.saveDirectoryURL,
                    timestamp: timestampProvider()
                )
                try saveCopyWriter(pngData, saveURL)
                saveOutcome = .succeeded
            } catch {
                saveOutcome = .failed
            }
        } else {
            saveOutcome = .notRequested
        }

        if let message = Self.completionMessage(copied: copied, saveOutcome: saveOutcome) {
            presenter.show(message: message)
        }
    }

    private func makeOverlays(for images: [CGDirectDisplayID: NSImage]) throws -> [SelectionOverlayWindow] {
        let screens: [(CGDirectDisplayID, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(screenNumber.uint32Value), screen)
        }
        try Self.validateDisplayTopology(
            capturedDisplayIDs: Set(images.keys),
            activeDisplayIDs: Set(screens.map(\.0))
        )

        let newOverlays = screens.map { displayID, screen in
            let image = images[displayID]!
            let overlay = SelectionOverlayWindow(screen: screen)
            overlay.overlayDelegate = self
            overlay.setScreenshot(image)
            return overlay
        }

        for overlay in newOverlays {
            overlay.overlayView.selectionDidBegin = { [weak self, weak overlay] in
                guard let self, let activeOverlay = overlay else { return }
                self.activateSelection(on: activeOverlay)
            }
        }

        let initialIndex = Self.initialSelectionIndex(
            screenFrames: screens.map(\.1.frame),
            mouseLocation: NSEvent.mouseLocation
        )
        if let initialIndex {
            newOverlays[initialIndex].overlayView.selectAllAsDefault()
        }
        return newOverlays
    }

    private func activateSelection(on activeOverlay: SelectionOverlayWindow) {
        Self.activateSelection(
            on: activeOverlay.overlayView,
            among: overlays.map(\.overlayView)
        )
    }

    private func message(for error: any Error) -> String {
        switch error {
        case CaptureError.permissionDenied:
            return "请在系统设置中允许 ShotMark 录制屏幕。"
        case CaptureError.noDisplays:
            return "未找到可截图的显示器。"
        case CaptureError.displayTopologyChanged:
            return "显示器配置已变化，请重新截图。"
        case CaptureError.captureTimedOut:
            return "截图启动超时，请重试。"
        default:
            return "截图失败，请重试。"
        }
    }

    private func endEditing() {
        cancelCaptureWatchdog()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        transition(to: .idle)
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func scheduleCaptureWatchdog(for generation: UInt64) {
        cancelCaptureWatchdog()
        let timeout = captureRecoveryTimeout
        captureWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.recoverHungCapture(generation: generation)
        }
    }

    private func cancelCaptureWatchdog() {
        captureWatchdog?.cancel()
        captureWatchdog = nil
    }

    private func recoverHungCapture(generation: UInt64) {
        guard isCurrentCapture(generation) else { return }
        captureWatchdog = nil
        captureGeneration &+= 1
        transition(to: .idle)
        presenter.show(message: message(for: CaptureError.captureTimedOut))
    }

    private func isCurrentCapture(_ generation: UInt64) -> Bool {
        state == .capturing && captureGeneration == generation
    }

    nonisolated private static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    nonisolated static func validateDisplayTopology(
        capturedDisplayIDs: Set<CGDirectDisplayID>,
        activeDisplayIDs: Set<CGDirectDisplayID>
    ) throws {
        guard !capturedDisplayIDs.isEmpty, !activeDisplayIDs.isEmpty else {
            throw CaptureError.noDisplays
        }
        guard capturedDisplayIDs == activeDisplayIDs else {
            throw CaptureError.displayTopologyChanged
        }
    }

    nonisolated static func initialSelectionIndex(
        screenFrames: [CGRect],
        mouseLocation: CGPoint
    ) -> Int? {
        screenFrames.firstIndex { $0.contains(mouseLocation) }
            ?? screenFrames.indices.first
    }

    static func activateSelection(
        on activeOverlay: SelectionOverlayView,
        among overlays: [SelectionOverlayView]
    ) {
        for overlay in overlays where overlay !== activeOverlay {
            overlay.selectedRect = nil
        }
    }

    nonisolated static func menuTitle(for state: State) -> String {
        state == .capturing ? "正在准备截图…" : "开始截图"
    }

    nonisolated static func completionMessage(
        copied: Bool,
        saveOutcome: SaveCopyOutcome
    ) -> String? {
        switch (copied, saveOutcome) {
        case (true, .notRequested), (true, .succeeded):
            return nil
        case (false, .notRequested):
            return "无法将截图复制到剪贴板。"
        case (false, .succeeded):
            return "截图副本已保存，但无法复制到剪贴板。"
        case (true, .failed):
            return "截图已复制，但保存副本失败。"
        case (false, .failed):
            return "无法复制截图，且保存副本失败。"
        }
    }

    private func availableSaveURL(in directory: URL, timestamp: String) -> URL {
        let basename = "ShotMark-\(timestamp)"
        var candidate = directory.appendingPathComponent("\(basename).png")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(basename)-\(suffix).png")
            suffix += 1
        }
        return candidate
    }

    nonisolated static func writeSaveCopy(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
    }
}

extension CaptureCoordinator: SelectionOverlayDelegate {
    func overlayDidCancel() {
        endEditing()
    }

    func overlayDidCommit(image: NSImage) {
        finish(image: image)
    }

    func overlayDidCopyOCRText(on screen: NSScreen?) {
        endEditing()
        presenter.showCopyConfirmation(on: screen)
    }
}
