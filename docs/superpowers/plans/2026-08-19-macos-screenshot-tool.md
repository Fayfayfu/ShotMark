# macOS Screenshot Tool Implementation Plan

> Historical implementation plan, not a completion report. Current behavior and known gaps are documented in the repository [README](../../../README.md). Unchecked steps below have not been reconciled with the current implementation.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local macOS menu-bar app that captures a selected screen region, annotates it, performs offline OCR, and copies image or text to the clipboard.

**Architecture:** An AppKit app owns a menu-bar controller and a capture coordinator. The coordinator presents one transparent overlay window per display and sends a selected image plus vector annotation operations to an annotation canvas; the canvas renders the final PNG. OCR is a separate Vision-backed service, with an opt-in network adapter behind the same protocol.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, ScreenCaptureKit, Carbon, Vision, Core Graphics, Core Image, XCTest, Keychain Services.

**Spec:** `docs/superpowers/specs/2026-08-19-macos-screenshot-tool-design.md`

## Global Constraints

- macOS only; minimum deployment target macOS 15.0.
- Build a native AppKit application named `ShotMark`; use no third-party dependencies or complete Xcode installation.
- Register the default global shortcut exactly as `Command + Shift + A` with Carbon `RegisterEventHotKey`.
- Request Screen Recording permission only when a user starts capture; include `NSScreenCaptureUsageDescription` in the target Info plist.
- Default OCR uses Apple Vision locally. Do not make network requests unless the user explicitly enables and configures a cloud provider.
- Do not persist screenshot bytes, annotation history, or OCR text. Saving a PNG copy is opt-in and disabled by default.
- Rectangles, circles, lines, arrows, and brush strokes support colors and 2/4/6/8 px widths. Text supports color, 14/18/24/32 px size, and regular/bold weight.
- `Esc` cancels. `Command + C`, the toolbar completion control, and a double click inside the selected region all copy the composed PNG and end the session.

---

## File structure

```
ShotMark/
  Package.swift
  Scripts/build-app.sh                 # turns release executable into ShotMark.app
  Sources/ShotMark/
    AppDelegate.swift                 # app lifecycle and menu bar setup
    Capture/CaptureCoordinator.swift  # capture session state machine
    Capture/GlobalHotKey.swift        # Carbon hotkey lifecycle
    Capture/ScreenImageProvider.swift # ScreenCaptureKit boundary
    Overlay/SelectionOverlayWindow.swift
    Overlay/SelectionOverlayView.swift
    Annotation/Annotation.swift       # annotation value types
    Annotation/AnnotationCanvasView.swift
    Annotation/AnnotationRenderer.swift
    Annotation/UndoHistory.swift
    OCR/OCRService.swift
    OCR/VisionOCRService.swift
    OCR/OCRResultPanel.swift
    Settings/SettingsStore.swift
    Settings/KeychainStore.swift
    Settings/SettingsWindowController.swift
    Resources/Info.plist
  Tests/ShotMarkTests/
    AnnotationRendererTests.swift
    UndoHistoryTests.swift
    OCRResultStateTests.swift
    SettingsStoreTests.swift
    CaptureCoordinatorTests.swift
```

### Task 1: Create a buildable native-app shell without Xcode

**Files:**
- Create: `ShotMark/Package.swift`
- Create: `ShotMark/Sources/ShotMark/AppDelegate.swift`
- Create: `ShotMark/Sources/ShotMark/Resources/Info.plist`
- Create: `ShotMark/Scripts/build-app.sh`
- Create: `ShotMark/Tests/ShotMarkTests/ShotMarkTests.swift`

**Interfaces:**
- Produces: `@main final class AppDelegate: NSObject, NSApplicationDelegate`.
- Produces: a `ShotMarkTests` XCTest target linked against `ShotMark`.

- [ ] **Step 1: Verify the existing Swift toolchain**

Run:

```zsh
swift --version
swift package --version
```

Expected: both commands report versions. Stop here if the command-line tools are absent; `swift build` cannot create the executable.

- [ ] **Step 2: Create a Swift package with executable and test targets**

Create `Package.swift` with executable target `ShotMark`, test target `ShotMarkTests`, macOS 15.0 platform, and no dependencies. Set the executable target path to `Sources/ShotMark` and the test target path to `Tests/ShotMarkTests`.

- [ ] **Step 3: Write the failing smoke test**

```swift
import XCTest
@testable import ShotMark

final class ShotMarkTests: XCTestCase {
    func testApplicationDelegateCanBeCreated() {
        XCTAssertNotNil(AppDelegate())
    }
}
```

- [ ] **Step 4: Implement the minimal app delegate and privacy description**

```swift
import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

Add `NSScreenCaptureUsageDescription` to `Info.plist` with value `ShotMark needs screen access to capture the region you select.`

- [ ] **Step 5: Build and run the smoke test**

Run:

```zsh
cd ShotMark && swift build && swift test
```

Expected: both commands exit 0. Add `Scripts/build-app.sh`, which runs `swift build -c release`, copies `.build/release/ShotMark` to `ShotMark.app/Contents/MacOS/ShotMark`, copies `Resources/Info.plist` to `Contents/Info.plist`, then uses `codesign --force --sign - ShotMark.app`.

- [ ] **Step 6: Commit**

```zsh
git add ShotMark
git commit -m "chore: scaffold ShotMark macOS app"
```

### Task 2: Add menu-bar entry, settings persistence, and global shortcut registration

**Files:**
- Create: `ShotMark/Sources/ShotMark/Capture/GlobalHotKey.swift`
- Create: `ShotMark/Sources/ShotMark/Settings/SettingsStore.swift`
- Modify: `ShotMark/Sources/ShotMark/AppDelegate.swift`
- Create: `ShotMark/Tests/ShotMarkTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `protocol GlobalHotKeyRegistering { func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws; func unregister() }`.
- Produces: `final class SettingsStore` with `var saveCopies: Bool` and `var saveDirectoryURL: URL`.
- Consumes later: `AppDelegate.startCapture()` callable from the menu item and hotkey handler.

- [ ] **Step 1: Write failing settings tests**

```swift
func testSaveCopiesDefaultsToFalse() {
    let suite = UserDefaults(suiteName: UUID().uuidString)!
    let store = SettingsStore(defaults: suite)
    XCTAssertFalse(store.saveCopies)
}

func testSaveDirectoryRoundTrips() {
    let suite = UserDefaults(suiteName: UUID().uuidString)!
    let store = SettingsStore(defaults: suite)
    let url = URL(fileURLWithPath: "/tmp/shotmark-test")
    store.saveDirectoryURL = url
    XCTAssertEqual(store.saveDirectoryURL, url)
}
```

- [ ] **Step 2: Run the new tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because `SettingsStore` does not exist.

- [ ] **Step 3: Implement UserDefaults-backed settings and Carbon hotkey wrapper**

```swift
final class SettingsStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var saveCopies: Bool {
        get { defaults.bool(forKey: "saveCopies") }
        set { defaults.set(newValue, forKey: "saveCopies") }
    }
    var saveDirectoryURL: URL {
        get { defaults.url(forKey: "saveDirectoryURL") ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0] }
        set { defaults.set(newValue, forKey: "saveDirectoryURL") }
    }
}
```

Implement `GlobalHotKey` with `RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey), ...)`, retain its `EventHotKeyRef`, call the supplied handler on the main queue, and throw a typed `GlobalHotKeyError.registrationFailed(OSStatus)` if registration returns nonzero.

- [ ] **Step 4: Add menu bar and conflict fallback**

Create an `NSStatusItem` containing `开始截图`, `设置…`, and `退出 ShotMark`. Have both the menu item and hotkey call `startCapture()`. If hotkey registration throws, change the menu title to `开始截图（⌘⇧A 已被占用）`; do not prevent menu-based capture.

- [ ] **Step 5: Run tests and manually verify the menu**

Run the test command from Step 2, then launch the Debug app. Expected: status bar icon appears; `开始截图` is clickable; the selected UserDefaults values survive relaunch.

- [ ] **Step 6: Commit**

```zsh
git add ShotMark
git commit -m "feat: add menu bar and global capture shortcut"
```

### Task 3: Model annotations, render them, and implement undo/redo

**Files:**
- Create: `ShotMark/Sources/ShotMark/Annotation/Annotation.swift`
- Create: `ShotMark/Sources/ShotMark/Annotation/AnnotationRenderer.swift`
- Create: `ShotMark/Sources/ShotMark/Annotation/UndoHistory.swift`
- Create: `ShotMark/Tests/ShotMarkTests/AnnotationRendererTests.swift`
- Create: `ShotMark/Tests/ShotMarkTests/UndoHistoryTests.swift`

**Interfaces:**
- Produces: `enum Annotation { case rectangle(CGRect, StrokeStyle); case ellipse(CGRect, StrokeStyle); case line(CGPoint, CGPoint, StrokeStyle); case arrow(CGPoint, CGPoint, StrokeStyle); case brush([CGPoint], StrokeStyle); case text(String, CGPoint, TextStyle); case mosaic(CGRect, Int) }`.
- Produces: `struct StrokeStyle { let color: NSColor; let width: CGFloat }`, `struct TextStyle { let color: NSColor; let pointSize: CGFloat; let weight: NSFont.Weight }`.
- Produces: `final class UndoHistory<Value>` with `apply(_:)`, `undo()`, `redo()`, and `current`.
- Consumes later: `AnnotationRenderer.render(baseImage:annotations:) -> NSImage`.

- [ ] **Step 1: Write failing renderer and history tests**

```swift
func testUndoRestoresPreviousAnnotationList() {
    let history = UndoHistory<[Int]>(initial: [])
    history.apply([1])
    history.apply([1, 2])
    XCTAssertEqual(history.undo(), [1])
    XCTAssertEqual(history.redo(), [1, 2])
}

func testLineRendererChangesTransparentCanvas() {
    let image = NSImage(size: NSSize(width: 40, height: 40))
    let result = AnnotationRenderer().render(baseImage: image, annotations: [.line(.zero, CGPoint(x: 39, y: 39), StrokeStyle(color: .red, width: 4))])
    XCTAssertEqual(result.size, image.size)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because annotation types are absent.

- [ ] **Step 3: Implement value types and history**

Use `Equatable` on all annotation value types. `UndoHistory` stores `past`, `current`, and `future`; `apply` clears `future`; `undo` and `redo` return the unchanged current value when no movement is available.

- [ ] **Step 4: Implement deterministic renderer**

Draw into a new `NSImage` using `lockFocus()`. Use `NSBezierPath` for rectangle, ellipse, line, arrow head, and brush path; draw text with an `NSFont` from `TextStyle`; apply mosaic by cropping the base CGImage, scaling down then scaling back up with interpolation `.none`. Draw annotations in array order.

- [ ] **Step 5: Run tests and inspect a rendered fixture**

Run the test command. Add assertions that a rendered red line has a nontransparent pixel near its midpoint and that `undo()` followed by `redo()` restores the identical array.

- [ ] **Step 6: Commit**

```zsh
git add ShotMark
git commit -m "feat: add annotation renderer and undo history"
```

### Task 4: Implement selected-region editing and commit gestures

**Files:**
- Create: `ShotMark/Sources/ShotMark/Annotation/AnnotationCanvasView.swift`
- Create: `ShotMark/Sources/ShotMark/Overlay/SelectionOverlayView.swift`
- Create: `ShotMark/Sources/ShotMark/Overlay/SelectionOverlayWindow.swift`
- Create: `ShotMark/Tests/ShotMarkTests/OverlayGestureTests.swift`

**Interfaces:**
- Produces: `protocol SelectionOverlayDelegate: AnyObject { func overlayDidCancel(); func overlayDidCommit(image: NSImage) }`.
- Produces: `final class SelectionOverlayView: NSView` with `weak var delegate: SelectionOverlayDelegate?`, `var selectedRect: CGRect?`, `func setScreenshot(_ image: NSImage)`, and `func handleMouseDown(at: CGPoint, clickCount: Int)`.
- Consumes: `AnnotationCanvasView.composePNGImage() -> NSImage` and `UndoHistory<[Annotation]>`.

- [ ] **Step 1: Write failing gesture tests**

```swift
final class OverlayDelegateSpy: SelectionOverlayDelegate {
    var didRequestCommit = false
    func overlayDidCancel() {}
    func overlayDidCommit(image: NSImage) { didRequestCommit = true }
}

func testDoubleClickInsideSelectionRequestsCommit() {
    let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    view.selectedRect = CGRect(x: 50, y: 50, width: 100, height: 80)
    let delegate = OverlayDelegateSpy()
    view.delegate = delegate
    view.handleMouseDown(at: CGPoint(x: 90, y: 90), clickCount: 2)
    XCTAssertTrue(delegate.didRequestCommit)
}

func testDoubleClickOutsideSelectionDoesNotCommit() {
    let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    view.selectedRect = CGRect(x: 50, y: 50, width: 100, height: 80)
    let delegate = OverlayDelegateSpy()
    view.delegate = delegate
    view.handleMouseDown(at: CGPoint(x: 20, y: 20), clickCount: 2)
    XCTAssertFalse(delegate.didRequestCommit)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because the overlay view and delegate do not exist.

- [ ] **Step 3: Implement overlay selection and editing lifecycle**

Create borderless, transparent, screen-sized `NSPanel` instances at `.screenSaver` level, one per `NSScreen`. The overlay draws a dim layer outside `selectedRect`, uses mouse down/drag/up to create the selection, then attaches `AnnotationCanvasView` in the selected area. Coordinate conversion must use each screen’s backing scale factor when cropping the screenshot.

- [ ] **Step 4: Implement tools and parameter controls**

Add toolbar controls for rectangle, ellipse, line, arrow, brush, text, mosaic, undo, redo, OCR, image copy, cancel, and completion. For the five stroke tools expose `NSColorWell` and `NSSegmentedControl` widths `[2, 4, 6, 8]`. For text expose `NSColorWell`, size `[14, 18, 24, 32]`, and regular/bold selection. Save each tool's last parameters in the overlay session.

- [ ] **Step 5: Implement the three commit gestures and cancel**

`keyDown` maps Escape to `overlayDidCancel` and Command-C to `overlayDidCommit(composePNGImage())`. In `mouseDown`, only call commit when `event.clickCount == 2` and `selectedRect.contains(convert(event.locationInWindow, from: nil))`. Route toolbar completion to the identical delegate method.

- [ ] **Step 6: Run tests and manual gesture validation**

Run all XCTest cases. Manually draw a selection, add a colored 6 px arrow and text, double-click inside the selected content, then paste into Preview. Expected: exactly the selected image with annotations is present.

- [ ] **Step 7: Commit**

```zsh
git add ShotMark
git commit -m "feat: add editable selection overlay"
```

### Task 5: Capture display images and manage the end-to-end session

**Files:**
- Create: `ShotMark/Sources/ShotMark/Capture/ScreenImageProvider.swift`
- Create: `ShotMark/Sources/ShotMark/Capture/CaptureCoordinator.swift`
- Modify: `ShotMark/Sources/ShotMark/AppDelegate.swift`
- Create: `ShotMark/Tests/ShotMarkTests/CaptureCoordinatorTests.swift`

**Interfaces:**
- Produces: `protocol ScreenImageProviding { func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] }`.
- Produces: `protocol CapturePresenting { func show(message: String); func show(overlays: [SelectionOverlayWindow]) }` and `final class CaptureCoordinator` with `func startCapture() async` and `func finish(image: NSImage)`.
- Consumes: `SelectionOverlayWindow`, `ScreenImageProviding`, `SettingsStore`.

- [ ] **Step 1: Write coordinator failure-path tests with a fake provider**

```swift
final class ScreenImageProviderStub: ScreenImageProviding {
    let result: Result<[CGDirectDisplayID: NSImage], Error>
    init(result: Result<[CGDirectDisplayID: NSImage], Error>) { self.result = result }
    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] { try result.get() }
}

final class CapturePresenterSpy: CapturePresenting {
    var messages: [String] = []
    func show(message: String) { messages.append(message) }
    func show(overlays: [SelectionOverlayWindow]) {}
}

func testCaptureFailurePresentsPermissionOrCaptureError() async {
    let provider = ScreenImageProviderStub(result: .failure(CaptureError.permissionDenied))
    let presenterSpy = CapturePresenterSpy()
    let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let coordinator = CaptureCoordinator(imageProvider: provider, presenter: presenterSpy, settings: settings)
    await coordinator.startCapture()
    XCTAssertEqual(presenterSpy.messages, ["请在系统设置中允许 ShotMark 录制屏幕。"])
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because the coordinator protocol and errors are absent.

- [ ] **Step 3: Implement ScreenCaptureKit provider**

Request permission only inside `captureDisplays()`. Get `SCShareableContent`, construct a display filter for each `SCDisplay`, capture a single frame with `SCScreenshotManager.captureImage(contentFilter:configuration:)`, and wrap each `CGImage` in `NSImage`. Map `.userDeclined` to `CaptureError.permissionDenied`; map no available display and stream errors to distinct `CaptureError` values.

- [ ] **Step 4: Implement coordinator state machine**

Use states `.idle`, `.capturing`, `.editing`. Ignore a new start request unless state is `.idle`; return to `.idle` on every error, cancel, and completion. Pass captured images to overlays. On completion write `image.tiffRepresentation` as `.png` data to `NSPasteboard.general`; only save to the configured directory when `settings.saveCopies` is true, using a timestamped `ShotMark-YYYYMMdd-HHmmss.png` filename.

- [ ] **Step 5: Run all tests and exercise permissions**

Run XCTest. Launch the app with Screen Recording revoked, choose `开始截图`, and verify the user-visible remediation. Grant it, relaunch if macOS requires, capture, paste into Preview, and confirm no image file appears in Pictures while `saveCopies == false`.

- [ ] **Step 6: Commit**

```zsh
git add ShotMark
git commit -m "feat: capture screens and copy completed images"
```

### Task 6: Add offline OCR and selective text copying

**Files:**
- Create: `ShotMark/Sources/ShotMark/OCR/OCRService.swift`
- Create: `ShotMark/Sources/ShotMark/OCR/VisionOCRService.swift`
- Create: `ShotMark/Sources/ShotMark/OCR/OCRResultPanel.swift`
- Create: `ShotMark/Tests/ShotMarkTests/OCRResultStateTests.swift`

**Interfaces:**
- Produces: `protocol OCRServicing { func recognize(image: NSImage) async throws -> OCRResult }`.
- Produces: `struct OCRResult { let text: String; let averageConfidence: Float }`.
- Produces: `protocol StringPasteboard { func write(_ string: String) }` and `final class OCRResultPanel: NSView` with `var recognizedText: String`, `var selectedRange: NSRange`, `var canCopySelection: Bool`, `func copyAll()`, and `func copySelection()`.

- [ ] **Step 1: Write failing OCR panel tests**

```swift
final class PasteboardSpy: StringPasteboard {
    var string: String?
    func write(_ string: String) { self.string = string }
}

func testCopySelectionIsDisabledWithoutRange() {
    let panel = OCRResultPanel()
    panel.recognizedText = "明朝 OCR 文本"
    panel.selectedRange = NSRange(location: NSNotFound, length: 0)
    XCTAssertFalse(panel.canCopySelection)
}

func testCopySelectionWritesSelectedSubstring() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "明朝 OCR 文本"
    panel.selectedRange = NSRange(location: 3, length: 3)
    panel.copySelection()
    XCTAssertEqual(pasteboard.string, "OCR")
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because OCR types do not exist.

- [ ] **Step 3: Implement local Vision OCR**

Create `VNRecognizeTextRequest` with `.accurate`, `usesLanguageCorrection = true`, and `recognitionLanguages = ["zh-Hans", "en-US"]`. Run it in a background task over the selected/composed CGImage. Sort observations by descending normalized y then ascending x. Join top candidates with newline and calculate average confidence. Return `OCRError.noText` for an empty result.

- [ ] **Step 4: Implement the editable result panel**

Use `NSTextView` inside an `NSScrollView`; bind text edits to `recognizedText` and selection changes to `selectedRange`. “复制全部” always copies the text view’s full string. “复制选中” is disabled for `NSNotFound` or zero length; otherwise copies exactly `substring(with: selectedRange)`. Put strings on `NSPasteboard.general` with type `.string`.

- [ ] **Step 5: Wire OCR to the overlay and test offline mode**

The OCR toolbar action invokes `VisionOCRService` with the current composed selection image and presents `OCRResultPanel` without ending the image editing session. If Vision reports an error, retain the canvas and show an error label. Disconnect the network, run OCR on a fixture containing Chinese and English, and verify text still appears.

- [ ] **Step 6: Run tests and commit**

Run all XCTest cases, then:

```zsh
git add ShotMark
git commit -m "feat: add offline OCR and selective text copy"
```

### Task 7: Add opt-in cloud OCR configuration and final settings UI

**Files:**
- Create: `ShotMark/Sources/ShotMark/Settings/KeychainStore.swift`
- Create: `ShotMark/Sources/ShotMark/Settings/SettingsWindowController.swift`
- Modify: `ShotMark/Sources/ShotMark/OCR/OCRService.swift`
- Modify: `ShotMark/Sources/ShotMark/OCR/OCRResultPanel.swift`
- Modify: `ShotMark/Sources/ShotMark/AppDelegate.swift`
- Modify: `ShotMark/Tests/ShotMarkTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `protocol CloudOCRServicing: OCRServicing { var isConfigured: Bool { get } }`.
- Produces: `protocol KeychainStoring { func set(_ value: Data, account: String) throws; func data(account: String) throws -> Data?; func remove(account: String) throws }`.
- Consumes: `SettingsStore.cloudEndpoint`, `KeychainStore` account `ShotMark.cloudOCR.apiKey`.

- [ ] **Step 1: Write failing cloud preference tests**

```swift
func testCloudOCRIsDisabledByDefault() {
    let store = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    XCTAssertFalse(store.cloudOCREnabled)
    XCTAssertNil(store.cloudEndpoint)
}

func testCloudEndpointAcceptsOnlyHTTPS() {
    let store = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    XCTAssertThrowsError(try store.setCloudEndpoint(URL(string: "http://example.test")!))
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `cd ShotMark && swift test`

Expected: compile failure because cloud properties are missing.

- [ ] **Step 3: Implement settings and Keychain boundary**

Add `cloudOCREnabled` defaulting false and optional `cloudEndpoint` to `SettingsStore`. `setCloudEndpoint` rejects non-HTTPS URLs and endpoints without a host. Implement Keychain read/write/delete using `kSecClassGenericPassword`, service `local.shotmark.app`, and the fixed account key. Never store an API key in UserDefaults or logs.

- [ ] **Step 4: Build the Settings window**

Add controls for saving copies, choose-directory, cloud OCR enable checkbox, HTTPS endpoint field, API key secure text field, and save button. Keep cloud fields disabled until the user turns the checkbox on. The OCR result panel exposes a `使用云端备用识别` action only when both `cloudOCREnabled` and `CloudOCRServicing.isConfigured` are true.

- [ ] **Step 5: Implement a generic cloud request adapter without automatic fallback**

POST PNG bytes only after the explicit backup action to the configured HTTPS endpoint with `Authorization: Bearer <key>` and `Content-Type: image/png`. Decode `{ "text": String }`. Convert non-2xx, invalid JSON, and transport errors to distinct user-visible errors. Do not retry; do not write the request body to disk; never call this adapter after local OCR failure without the explicit action.

- [ ] **Step 6: Run tests and manual privacy verification**

Run XCTest. With cloud OCR disabled, exercise local OCR while observing the process in a network monitor; expected: no connections. Enable cloud OCR with an invalid endpoint and click backup; expected: a clear error with the current image/editor still intact.

- [ ] **Step 7: Commit**

```zsh
git add ShotMark
git commit -m "feat: add opt-in cloud OCR settings"
```

### Task 8: Verify release behavior and package the local app

**Files:**
- Modify: `ShotMark/Sources/ShotMark/Resources/Info.plist`
- Create: `ShotMark/README.md`

**Interfaces:**
- Produces: an ad-hoc signed `ShotMark.app` in the package root, launchable locally without network access for all default functionality.

- [ ] **Step 1: Add manual acceptance checklist to README**

Document exact checks: Screen Recording remediation; hotkey conflict fallback; single and multiple displays; all annotation tools with required color/width or text parameters; undo/redo; cancel; `Command-C`; toolbar complete; double-click inside/outside selection; copy/paste PNG; offline Chinese/English OCR; full/selected text copy; disabled cloud OCR network check; cloud error behavior; save-copy toggle.

- [ ] **Step 2: Run the complete test suite from a clean build directory**

Run:

```zsh
cd ShotMark && swift package clean && swift test
```

Expected: zero failing tests.

- [ ] **Step 3: Build the app and run it from Finder**

Run:

```zsh
cd ShotMark && ./Scripts/build-app.sh
open "$(pwd)/ShotMark.app"
```

Expected: `ShotMark.app` launches, creates a menu-bar icon, and completes the README checklist under the applicable permission states.

- [ ] **Step 4: Commit**

```zsh
git add ShotMark
git commit -m "docs: add local app verification checklist"
```

## Plan self-review

| Spec requirement | Implementing task |
| --- | --- |
| macOS native menu-bar app and `Command + Shift + A` | Tasks 1–2 |
| Screen capture permissions, multi-display selection and failure states | Task 5 |
| all requested annotation types, colors, widths, text styling, undo/redo | Tasks 3–4 |
| completion by toolbar, Command-C, and selection-area double-click | Task 4 |
| clipboard PNG and opt-in local disk copy | Task 5 |
| offline Vision OCR and full/selected text copies | Task 6 |
| user-configured cloud OCR only, Keychain storage, and no automatic upload | Task 7 |
| build, manual acceptance, and local `.app` validation | Task 8 |

The red-flag scan found no deferred implementation markers. Types exposed by one task are named in the interfaces of tasks that consume them.
