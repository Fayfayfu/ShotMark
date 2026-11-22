import AppKit
import Carbon

enum CaptureHotKeyRegistrationState {
    static func menuTitle(for error: GlobalHotKeyError) -> String {
        guard case let .registrationFailed(status) = error,
              status == eventHotKeyExistsErr else {
            return "开始截图（⌘⇧A 注册失败）"
        }

        return "开始截图（⌘⇧A 已被占用）"
    }
}

enum CaptureMenuTitle {
    static func menuTitle(
        for state: CaptureCoordinator.State,
        hotKeyRegistrationDiagnostic: String?
    ) -> String {
        guard state != .capturing else { return "正在准备截图…" }
        return hotKeyRegistrationDiagnostic ?? "开始截图"
    }
}

@main
@MainActor
struct ShotMarkApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let globalHotKey: GlobalHotKeyRegistering = GlobalHotKey()
    private let captureCoordinator: CaptureCoordinator
    private var captureMenuItem: NSMenuItem?
    private var hotKeyRegistrationDiagnostic: String?

    override convenience init() {
        self.init(
            captureCoordinator: CaptureCoordinator(
                imageProvider: ScreenImageProvider(),
                presenter: AppCapturePresenter(),
                settingsStore: SettingsStore()
            )
        )
    }

    init(captureCoordinator: CaptureCoordinator) {
        self.captureCoordinator = captureCoordinator
        super.init()
        captureCoordinator.onStateChange = { [weak self] state in
            self?.updateCaptureMenuTitle(for: state)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerCaptureHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey.unregister()
    }

    @objc func startCapture() {
        Task { await captureCoordinator.startCapture() }
    }

    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "设置尚不可用"
        alert.informativeText = "设置界面将在后续任务中接入。"
        alert.runModal()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "ShotMark"

        let menu = NSMenu()
        let captureItem = NSMenuItem(
            title: CaptureMenuTitle.menuTitle(
                for: captureCoordinator.state,
                hotKeyRegistrationDiagnostic: hotKeyRegistrationDiagnostic
            ),
            action: #selector(startCapture),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        captureMenuItem = captureItem

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 ShotMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func updateCaptureMenuTitle(for state: CaptureCoordinator.State) {
        captureMenuItem?.title = CaptureMenuTitle.menuTitle(
            for: state,
            hotKeyRegistrationDiagnostic: hotKeyRegistrationDiagnostic
        )
    }

    private func registerCaptureHotKey() {
        do {
            try globalHotKey.register(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(cmdKey | shiftKey),
                handler: { [weak self] in self?.startCapture() }
            )
        } catch let error as GlobalHotKeyError {
            hotKeyRegistrationDiagnostic = CaptureHotKeyRegistrationState.menuTitle(for: error)
            updateCaptureMenuTitle(for: captureCoordinator.state)
        } catch {
            hotKeyRegistrationDiagnostic = "开始截图（⌘⇧A 注册失败）"
            updateCaptureMenuTitle(for: captureCoordinator.state)
        }
    }
}
