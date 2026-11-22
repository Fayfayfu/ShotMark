import AppKit

enum SelectionResizeHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

@MainActor
private final class SelectionChromeView: NSView {
    var selectionRect: CGRect?
    var handleRects: [SelectionResizeHandle: CGRect] = [:]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let selectionRect else { return }

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 1.5
        border.stroke()

        for rect in handleRects.values {
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let handle = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            handle.lineWidth = 1
            handle.fill()
            handle.stroke()
        }
    }
}

@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    func overlayDidCancel()
    func overlayDidCommit(image: NSImage)
    func overlayDidCopyOCRText(on screen: NSScreen?)
}

@MainActor
final class SelectionOverlayView: NSView {
    weak var delegate: (any SelectionOverlayDelegate)?
    var selectionDidBegin: (() -> Void)?
    var selectedRect: CGRect? {
        didSet {
            if !isApplyingDefaultFullScreenSelection {
                isDefaultFullScreenSelection = false
            }
            needsDisplay = true
            updateSelectionChrome()
            if !isSelecting, !isApplyingSelectionAdjustment {
                if selectedRect == nil {
                    detachAnnotationCanvas()
                } else {
                    attachAnnotationCanvasIfPossible()
                }
            }
        }
    }

    var captureBackingScale: CGFloat = 1

    private static let selectionDragThreshold: CGFloat = 4
    static let minimumSelectionSize: CGFloat = 24

    private enum SelectionInteraction {
        case new(start: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(handle: SelectionResizeHandle, start: CGPoint, original: CGRect)
    }

    private var screenshot: NSImage?
    private var selectionInteraction: SelectionInteraction?
    private var candidateRect: CGRect?
    private var isSelecting = false
    private var selectionModeEnabled = true
    private var isApplyingSelectionAdjustment = false
    private var isApplyingDefaultFullScreenSelection = false
    private var isDefaultFullScreenSelection = false
    private var annotationCanvas: AnnotationCanvasView?
    private let selectionChrome = SelectionChromeView()
    private let ocrService: any OCRServicing
    private let ocrPasteboard: any StringPasteboard
    private var ocrRequestGeneration: UInt64 = 0
    private var ocrTask: Task<Void, Never>?
    private var ocrErrorLabel: NSTextField?
    private(set) var presentedOCRPanel: OCRResultPanel?
    private(set) var ocrErrorMessage: String?

    override init(frame frameRect: NSRect) {
        ocrService = VisionOCRService()
        ocrPasteboard = SystemStringPasteboard()
        super.init(frame: frameRect)
        configureSelectionChrome()
    }

    init(
        frame frameRect: NSRect,
        ocrService: any OCRServicing,
        ocrPasteboard: any StringPasteboard = SystemStringPasteboard()
    ) {
        self.ocrService = ocrService
        self.ocrPasteboard = ocrPasteboard
        super.init(frame: frameRect)
        configureSelectionChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var selectionHandleRects: [SelectionResizeHandle: CGRect] {
        guard let selectedRect, !isDefaultFullScreenSelection else { return [:] }
        return handleRects(for: selectedRect)
    }

    func setScreenshot(_ image: NSImage) {
        screenshot = image
        attachAnnotationCanvasIfPossible()
        needsDisplay = true
    }

    func setSelectionModeEnabled(_ enabled: Bool) {
        selectionModeEnabled = enabled
    }

    func selectAllAsDefault() {
        isApplyingDefaultFullScreenSelection = true
        selectedRect = bounds
        isApplyingDefaultFullScreenSelection = false
        isDefaultFullScreenSelection = true
        updateSelectionChrome()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let underlying = super.hitTest(point)
        if let underlying, isOverlayControlHit(underlying) {
            return underlying
        }
        if resizeHandle(at: point) != nil {
            return self
        }
        if selectionModeEnabled, selectedRect?.contains(point) == true {
            return self
        }
        return underlying
    }

    func handleMouseDown(at point: CGPoint, clickCount: Int) {
        if clickCount == 2, shouldSubmitOCRTextDoubleClick(at: point) {
            cancelSelection()
            return
        }
        guard clickCount == 2, let selectedRect, selectedRect.contains(point) else { return }
        commitSelection()
    }

    override func layout() {
        super.layout()
        selectionChrome.frame = bounds
        positionControlSurface()
        positionOCRPresentation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        screenshot?.draw(
            in: bounds,
            from: CGRect(origin: .zero, size: screenshot?.size ?? .zero),
            operation: .copy,
            fraction: 1
        )

        NSColor.black.withAlphaComponent(0.52).setFill()
        let dimPath = NSBezierPath(rect: bounds)
        let displayedSelectionRect = candidateRect ?? selectedRect
        if let displayedSelectionRect {
            dimPath.appendRect(displayedSelectionRect.intersection(bounds))
            dimPath.windingRule = .evenOdd
        }
        dimPath.fill()

        guard let displayedSelectionRect else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: displayedSelectionRect)
        border.lineWidth = 1
        border.stroke()
        drawDimensions(for: displayedSelectionRect)
    }

    override func mouseDown(with event: NSEvent) {
        processPointerDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        processPointerDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        processPointerUp(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyEquivalent(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) {
            return
        }
        super.keyDown(with: event)
    }

    func handleKeyEquivalent(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if keyCode == 53 {
            cancelSelection()
            return true
        }
        if modifiers.intersection(.deviceIndependentFlagsMask).contains(.command),
           charactersIgnoringModifiers?.lowercased() == "z",
           let annotationCanvas,
           !annotationCanvas.hasPendingTextEditor {
            if modifiers.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                annotationCanvas.redo()
            } else {
                annotationCanvas.undo()
            }
            return true
        }
        if modifiers.intersection(.deviceIndependentFlagsMask).contains(.command),
           charactersIgnoringModifiers?.lowercased() == "c" {
            commitSelection()
            return true
        }
        return false
    }

    func commitSelection() {
        guard let selectedRect else { return }
        invalidateOCRRequest()
        if let annotationCanvas {
            delegate?.overlayDidCommit(image: annotationCanvas.composePNGImage())
        } else if let croppedImage = croppedScreenshot(to: selectedRect) {
            delegate?.overlayDidCommit(image: croppedImage)
        }
    }

    func cancelSelection() {
        invalidateOCRRequest()
        delegate?.overlayDidCancel()
    }

    func startOCR() {
        guard let sourceCanvas = annotationCanvas else { return }
        invalidateOCRRequest()
        let generation = ocrRequestGeneration
        let image = sourceCanvas.composeImageForOCR()
        let service = ocrService

        ocrTask = Task { @MainActor [weak self, weak sourceCanvas] in
            do {
                let result = try await service.recognize(image: image)
                guard let self,
                      let sourceCanvas,
                      !Task.isCancelled,
                      self.isCurrentOCRRequest(generation, sourceCanvas: sourceCanvas)
                else { return }
                self.presentOCRResult(result)
                self.ocrTask = nil
            } catch {
                guard let self,
                      let sourceCanvas,
                      !Task.isCancelled,
                      self.isCurrentOCRRequest(generation, sourceCanvas: sourceCanvas)
                else { return }
                self.presentOCRError(error.localizedDescription)
                self.ocrTask = nil
            }
        }
    }

    func shouldCommitDoubleClick(at point: CGPoint) -> Bool {
        guard selectedRect?.contains(point) == true,
              let annotationCanvas,
              let hitView = hitTest(point)
        else { return false }

        if resizeHandle(at: point) != nil || isOverlayControlHit(hitView) {
            return false
        }
        if selectionModeEnabled {
            return true
        }

        if hitView === annotationCanvas || hitView.isDescendant(of: annotationCanvas) {
            return true
        }
        if annotationCanvas.hasPendingTextEditor,
           let fieldEditor = window?.firstResponder as? NSTextView,
           hitView === fieldEditor {
            return true
        }
        return false
    }

    func shouldSubmitOCRTextDoubleClick(at point: CGPoint) -> Bool {
        guard let panel = presentedOCRPanel, panel.canSubmitCopiedText else { return false }
        return panel.frame.contains(point)
    }

    private func processPointerDown(at rawPoint: CGPoint, clickCount: Int) {
        let point = constrainedPoint(rawPoint)
        if clickCount == 2 {
            resetSelectionInteraction(restoringEditingState: true)
            if shouldCommitDoubleClick(at: point) {
                handleMouseDown(at: point, clickCount: clickCount)
            }
            return
        }
        guard clickCount == 1 else { return }
        beginSelectionInteraction(at: point)
    }

    private func processPointerDragged(to rawPoint: CGPoint) {
        updateSelectionInteraction(to: rawPoint)
    }

    private func processPointerUp(at rawPoint: CGPoint, clickCount: Int) {
        guard clickCount < 2 else {
            resetSelectionInteraction(restoringEditingState: true)
            return
        }
        endSelectionInteraction(at: rawPoint)
    }

    func beginSelectionInteraction(at rawPoint: CGPoint) {
        let point = constrainedPoint(rawPoint)
        candidateRect = nil
        isSelecting = false

        if selectionModeEnabled, isDefaultFullScreenSelection {
            selectionInteraction = .new(start: point)
        } else if let selectedRect, let handle = resizeHandle(at: point) {
            selectionInteraction = .resize(handle: handle, start: point, original: selectedRect)
        } else if selectionModeEnabled, let selectedRect, selectedRect.contains(point) {
            selectionInteraction = .move(start: point, original: selectedRect)
        } else if selectionModeEnabled {
            selectionInteraction = .new(start: point)
        } else {
            selectionInteraction = nil
        }
    }

    func updateSelectionInteraction(to rawPoint: CGPoint) {
        guard let selectionInteraction else { return }
        let point = constrainedPoint(rawPoint)
        let start: CGPoint
        switch selectionInteraction {
        case let .new(interactionStart), let .move(interactionStart, _), let .resize(_, interactionStart, _):
            start = interactionStart
        }
        guard isSelecting || hypot(point.x - start.x, point.y - start.y) >= Self.selectionDragThreshold else {
            return
        }

        if !isSelecting {
            isSelecting = true
            invalidateOCRRequest()
            if case .new = selectionInteraction {
                selectionDidBegin?()
            }
            setExistingEditingStateHidden(true)
        }

        switch selectionInteraction {
        case let .new(start):
            candidateRect = newSelectionRect(from: start, to: point)
        case let .move(start, original):
            candidateRect = movedRect(original, from: start, to: point)
        case let .resize(handle, _, original):
            candidateRect = resizedRect(original, using: handle, to: point)
        }
        needsDisplay = true
    }

    func endSelectionInteraction(at rawPoint: CGPoint) {
        guard let interaction = selectionInteraction else { return }
        updateSelectionInteraction(to: rawPoint)
        let finalRect = candidateRect
        let shouldPreserveAnnotations: Bool
        let annotationTranslation: CGPoint
        switch interaction {
        case .new:
            shouldPreserveAnnotations = false
            annotationTranslation = .zero
        case .move:
            shouldPreserveAnnotations = true
            annotationTranslation = .zero
        case let .resize(_, _, original):
            shouldPreserveAnnotations = true
            annotationTranslation = CGPoint(
                x: original.minX - (finalRect?.minX ?? original.minX),
                y: original.minY - (finalRect?.minY ?? original.minY)
            )
        }

        selectionInteraction = nil
        candidateRect = nil
        guard isSelecting, let finalRect,
              finalRect.width >= Self.selectionDragThreshold,
              finalRect.height >= Self.selectionDragThreshold
        else {
            isSelecting = false
            setExistingEditingStateHidden(false)
            needsDisplay = true
            return
        }

        isSelecting = false
        applySelection(
            finalRect,
            preservingAnnotations: shouldPreserveAnnotations,
            annotationTranslation: annotationTranslation
        )
    }

    private func attachAnnotationCanvasIfPossible() {
        guard !isSelecting,
              let selectedRect,
              selectedRect.width >= 2,
              selectedRect.height >= 2,
              let croppedImage = croppedScreenshot(to: selectedRect)
        else { return }

        detachAnnotationCanvas()
        let canvas = AnnotationCanvasView(frame: selectedRect, image: croppedImage)
        canvas.autoresizingMask = []
        canvas.commitHandler = { [weak self] in self?.commitSelection() }
        canvas.cancelHandler = { [weak self] in self?.cancelSelection() }
        canvas.ocrHandler = { [weak self] in self?.startOCR() }
        canvas.controlSurfaceDidResize = { [weak self] in self?.positionControlSurface() }
        canvas.selectionModeChanged = { [weak self] enabled in self?.setSelectionModeEnabled(enabled) }
        addSubview(canvas)
        addSubview(selectionChrome, positioned: .above, relativeTo: canvas)
        addSubview(canvas.annotationControlSurface)
        annotationCanvas = canvas
        setSelectionModeEnabled(canvas.isSelectionToolActive)
        setExistingEditingStateHidden(false)
        positionControlSurface()
    }

    private func detachAnnotationCanvas() {
        invalidateOCRRequest()
        annotationCanvas?.annotationControlSurface.removeFromSuperview()
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil
    }

    private func setExistingEditingStateHidden(_ hidden: Bool) {
        annotationCanvas?.isHidden = hidden
        annotationCanvas?.annotationControlSurface.isHidden = hidden
        selectionChrome.isHidden = hidden
    }

    private func positionControlSurface() {
        guard let selectedRect, let surface = annotationCanvas?.annotationControlSurface else { return }
        surface.layoutSubtreeIfNeeded()
        let size = surface.frame.size
        let spacing: CGFloat = 8
        let proposedY: CGFloat
        if selectedRect.maxY + spacing + size.height <= bounds.maxY {
            proposedY = selectedRect.maxY + spacing
        } else if selectedRect.minY - spacing - size.height >= bounds.minY {
            proposedY = selectedRect.minY - spacing - size.height
        } else {
            proposedY = min(max(selectedRect.minY + 12, bounds.minY), bounds.maxY - size.height)
        }
        surface.frame.origin = CGPoint(
            x: min(max(selectedRect.minX, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(proposedY, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        )
    }

    private func invalidateOCRRequest() {
        ocrTask?.cancel()
        ocrTask = nil
        ocrRequestGeneration += 1
        clearOCRPresentation()
    }

    private func isCurrentOCRRequest(
        _ generation: UInt64,
        sourceCanvas: AnnotationCanvasView
    ) -> Bool {
        ocrRequestGeneration == generation && annotationCanvas === sourceCanvas
    }

    private func presentOCRResult(_ result: OCRResult) {
        let panel = OCRResultPanel(result: result, pasteboard: ocrPasteboard)
        panel.onCopySucceeded = { [weak self] in
            guard let self else { return }
            delegate?.overlayDidCopyOCRText(on: window?.screen)
        }
        panel.frame.size = NSSize(
            width: min(520, max(1, bounds.width - 24)),
            height: min(360, max(1, bounds.height - 24))
        )
        addSubview(panel, positioned: .above, relativeTo: nil)
        presentedOCRPanel = panel
        positionOCRPresentation()
    }

    private func clearOCRPresentation() {
        presentedOCRPanel?.removeFromSuperview()
        presentedOCRPanel = nil
        ocrErrorLabel?.removeFromSuperview()
        ocrErrorLabel = nil
        ocrErrorMessage = nil
    }

    private func presentOCRError(_ message: String) {
        ocrErrorMessage = message
        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92)
        label.drawsBackground = true
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.sizeToFit()
        label.frame.size.width = min(max(label.frame.width + 24, 180), max(1, bounds.width - 24))
        label.frame.size.height = max(label.frame.height + 12, 32)
        addSubview(label, positioned: .above, relativeTo: nil)
        ocrErrorLabel = label
        positionOCRPresentation()
    }

    private func positionOCRPresentation() {
        if let panel = presentedOCRPanel {
            panel.frame.origin = CGPoint(
                x: bounds.midX - panel.frame.width / 2,
                y: bounds.midY - panel.frame.height / 2
            )
        }
        if let label = ocrErrorLabel {
            label.frame.origin = CGPoint(
                x: bounds.midX - label.frame.width / 2,
                y: max(bounds.minY + 12, bounds.maxY - label.frame.height - 12)
            )
        }
    }

    private func croppedScreenshot(to rect: CGRect) -> NSImage? {
        guard let screenshot else { return nil }
        let imagePointSize = screenshot.size
        guard imagePointSize.width > 0, imagePointSize.height > 0 else { return nil }

        let viewToImageX = imagePointSize.width / max(bounds.width, 1)
        let viewToImageY = imagePointSize.height / max(bounds.height, 1)
        let imagePointRect = CGRect(
            x: rect.minX * viewToImageX,
            y: rect.minY * viewToImageY,
            width: rect.width * viewToImageX,
            height: rect.height * viewToImageY
        )
        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSImage(size: rect.size, flipped: false) { destinationRect in
                screenshot.draw(in: destinationRect, from: imagePointRect, operation: .copy, fraction: 1)
                return true
            }
        }

        let pixelScaleX = CGFloat(cgImage.width) / imagePointSize.width
        let pixelScaleY = CGFloat(cgImage.height) / imagePointSize.height
        let screenScale = max(1, captureBackingScale)
        let scaleX = abs(pixelScaleX - screenScale) < 0.01 ? screenScale : pixelScaleX
        let scaleY = abs(pixelScaleY - screenScale) < 0.01 ? screenScale : pixelScaleY
        let imageRect = CGRect(
            x: imagePointRect.minX * scaleX,
            y: (imagePointSize.height - imagePointRect.maxY) * scaleY,
            width: imagePointRect.width * scaleX,
            height: imagePointRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard !imageRect.isNull,
              !imageRect.isEmpty,
              let crop = cgImage.cropping(to: imageRect)
        else { return nil }
        return NSImage(cgImage: crop, size: rect.size)
    }

    private func drawDimensions(for rect: CGRect) {
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let size = label.size(withAttributes: attributes)
        let y = rect.minY >= size.height + 6 ? rect.minY - size.height - 4 : rect.maxY + 4
        label.draw(at: CGPoint(x: rect.minX, y: min(y, bounds.maxY - size.height)), withAttributes: attributes)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func newSelectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        var rect = normalizedRect(from: start, to: end).intersection(bounds)
        let minimumWidth = min(Self.minimumSelectionSize, bounds.width)
        let minimumHeight = min(Self.minimumSelectionSize, bounds.height)

        if rect.width < minimumWidth {
            if end.x >= start.x {
                rect.origin.x = min(start.x, bounds.maxX - minimumWidth)
            } else {
                rect.origin.x = max(bounds.minX, start.x - minimumWidth)
            }
            rect.size.width = minimumWidth
        }
        if rect.height < minimumHeight {
            if end.y >= start.y {
                rect.origin.y = min(start.y, bounds.maxY - minimumHeight)
            } else {
                rect.origin.y = max(bounds.minY, start.y - minimumHeight)
            }
            rect.size.height = minimumHeight
        }
        return rect.intersection(bounds)
    }

    private func configureSelectionChrome() {
        selectionChrome.frame = bounds
        selectionChrome.autoresizingMask = [.width, .height]
        addSubview(selectionChrome)
        updateSelectionChrome()
    }

    private func updateSelectionChrome() {
        selectionChrome.selectionRect = selectedRect
        selectionChrome.handleRects = selectionHandleRects
        selectionChrome.needsDisplay = true
    }

    private func handleRects(for rect: CGRect) -> [SelectionResizeHandle: CGRect] {
        let size: CGFloat = 10
        func handleRect(center: CGPoint) -> CGRect {
            CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        }
        return [
            .topLeft: handleRect(center: CGPoint(x: rect.minX, y: rect.maxY)),
            .top: handleRect(center: CGPoint(x: rect.midX, y: rect.maxY)),
            .topRight: handleRect(center: CGPoint(x: rect.maxX, y: rect.maxY)),
            .right: handleRect(center: CGPoint(x: rect.maxX, y: rect.midY)),
            .bottomRight: handleRect(center: CGPoint(x: rect.maxX, y: rect.minY)),
            .bottom: handleRect(center: CGPoint(x: rect.midX, y: rect.minY)),
            .bottomLeft: handleRect(center: CGPoint(x: rect.minX, y: rect.minY)),
            .left: handleRect(center: CGPoint(x: rect.minX, y: rect.midY))
        ]
    }

    private func resizeHandle(at point: CGPoint) -> SelectionResizeHandle? {
        let hitSlop: CGFloat = 4
        let priority: [SelectionResizeHandle] = [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
            .top, .right, .bottom, .left
        ]
        return priority.first {
            selectionHandleRects[$0]?.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) == true
        }
    }

    private func movedRect(_ rect: CGRect, from start: CGPoint, to point: CGPoint) -> CGRect {
        let maxX = max(bounds.minX, bounds.maxX - rect.width)
        let maxY = max(bounds.minY, bounds.maxY - rect.height)
        return CGRect(
            x: min(max(rect.minX + point.x - start.x, bounds.minX), maxX),
            y: min(max(rect.minY + point.y - start.y, bounds.minY), maxY),
            width: rect.width,
            height: rect.height
        )
    }

    private func resizedRect(
        _ rect: CGRect,
        using handle: SelectionResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        let minimumWidth = min(Self.minimumSelectionSize, bounds.width)
        let minimumHeight = min(Self.minimumSelectionSize, bounds.height)

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(point.x, maxX - minimumWidth)
        case .topRight, .right, .bottomRight:
            maxX = max(point.x, minX + minimumWidth)
        case .top, .bottom:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            maxY = max(point.y, minY + minimumHeight)
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(point.y, maxY - minimumHeight)
        case .left, .right:
            break
        }

        minX = max(bounds.minX, minX)
        maxX = min(bounds.maxX, maxX)
        minY = max(bounds.minY, minY)
        maxY = min(bounds.maxY, maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func applySelection(
        _ rect: CGRect,
        preservingAnnotations: Bool,
        annotationTranslation: CGPoint
    ) {
        let existingCanvas = preservingAnnotations ? annotationCanvas : nil
        if !preservingAnnotations {
            detachAnnotationCanvas()
        }

        isApplyingSelectionAdjustment = true
        selectedRect = rect
        isApplyingSelectionAdjustment = false

        if let existingCanvas, let image = croppedScreenshot(to: rect) {
            existingCanvas.frame = rect
            existingCanvas.translateAnnotations(by: annotationTranslation)
            existingCanvas.updateImagePreservingAnnotations(image)
            setExistingEditingStateHidden(false)
            positionControlSurface()
        } else {
            attachAnnotationCanvasIfPossible()
        }
        updateSelectionChrome()
    }

    private func isOverlayControlHit(_ view: NSView) -> Bool {
        if let surface = annotationCanvas?.annotationControlSurface,
           view === surface || view.isDescendant(of: surface) {
            return true
        }
        if let panel = presentedOCRPanel,
           view === panel || view.isDescendant(of: panel) {
            return true
        }
        return false
    }

    private func resetSelectionInteraction(restoringEditingState: Bool) {
        selectionInteraction = nil
        candidateRect = nil
        isSelecting = false
        if restoringEditingState {
            setExistingEditingStateHidden(false)
        }
        needsDisplay = true
    }

    private func constrainedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
