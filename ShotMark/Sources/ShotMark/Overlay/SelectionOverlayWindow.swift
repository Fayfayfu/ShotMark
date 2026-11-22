import AppKit

@MainActor
final class SelectionOverlayWindow: NSPanel {
    let overlayView: SelectionOverlayView

    weak var overlayDelegate: (any SelectionOverlayDelegate)? {
        didSet { overlayView.delegate = overlayDelegate }
    }

    init(screen: NSScreen) {
        overlayView = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        overlayView.captureBackingScale = screen.backingScaleFactor

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
        makeFirstResponder(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2 {
            let point = overlayView.convert(event.locationInWindow, from: nil)
            if overlayView.shouldSubmitOCRTextDoubleClick(at: point)
                || overlayView.shouldCommitDoubleClick(at: point) {
                overlayView.handleMouseDown(at: point, clickCount: event.clickCount)
                return
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if overlayView.handleKeyEquivalent(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        overlayView.cancelSelection()
    }

    func setScreenshot(_ image: NSImage) {
        overlayView.setScreenshot(image)
    }
}
