import AppKit
import Testing
import Vision
@testable import ShotMark

@MainActor
private final class PasteboardSpy: StringPasteboard {
    private(set) var strings: [String] = []
    var acceptsWrites = true

    func write(_ string: String) -> Bool {
        guard acceptsWrites else { return false }
        strings.append(string)
        return true
    }
}

@MainActor
@Test
func copySelectionIsDisabledWithoutRange() {
    let panel = OCRResultPanel()
    panel.recognizedText = "明朝 OCR 文本"
    panel.selectedRange = NSRange(location: NSNotFound, length: 0)

    #expect(!panel.canCopySelection)
}

@MainActor
@Test
func copySelectionIsDisabledForEmptyRange() {
    let panel = OCRResultPanel()
    panel.recognizedText = "明朝 OCR 文本"
    panel.selectedRange = NSRange(location: 3, length: 0)

    #expect(!panel.canCopySelection)
}

@MainActor
@Test
func copySelectionWritesExactSelectedSubstring() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "明朝 OCR 文本"
    panel.selectedRange = NSRange(location: 3, length: 3)

    panel.copySelection()

    #expect(pasteboard.strings == ["OCR"])
}

@MainActor
@Test
func copyAllPreservesRecognizedTextExactly() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "  明朝\nOCR 文本  \n"

    panel.copyAll()

    #expect(pasteboard.strings == ["  明朝\nOCR 文本  \n"])
}

@MainActor
@Test
func rejectedClipboardWriteDoesNotCompleteOCRWorkflow() {
    let pasteboard = PasteboardSpy()
    pasteboard.acceptsWrites = false
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "不能丢失的 OCR 文字"
    var completionCount = 0
    panel.onCopySucceeded = { completionCount += 1 }

    panel.copyAll()

    #expect(completionCount == 0)
    #expect(pasteboard.strings.isEmpty)
}

@MainActor
@Test
func copyingAllArmsOCRTextSubmission() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "可粘贴文字"

    #expect(!panel.canSubmitCopiedText)

    panel.copyAll()

    #expect(panel.canSubmitCopiedText)
    #expect(pasteboard.strings == ["可粘贴文字"])
}

@MainActor
@Test
func invalidCopySelectionDoesNotArmOCRTextSubmission() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "OCR"
    panel.selectedRange = NSRange(location: 2, length: 2)

    panel.copySelection()

    #expect(!panel.canSubmitCopiedText)
    #expect(pasteboard.strings.isEmpty)
}

@MainActor
@Test
func copySelectionIgnoresRangeOutsideEditableText() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "OCR"
    panel.selectedRange = NSRange(location: 2, length: 2)

    #expect(!panel.canCopySelection)
    panel.copySelection()

    #expect(pasteboard.strings.isEmpty)
}

@MainActor
@Test
func copySelectionRejectsNegativeLocation() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "OCR"
    panel.selectedRange = NSRange(location: -1, length: 1)

    #expect(!panel.canCopySelection)
    panel.copySelection()

    #expect(pasteboard.strings.isEmpty)
}

@MainActor
@Test
func copySelectionRejectsNegativeLength() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "OCR"
    panel.selectedRange = NSRange(location: 0, length: -1)

    #expect(!panel.canCopySelection)
    panel.copySelection()

    #expect(pasteboard.strings.isEmpty)
}

@MainActor
@Test
func copySelectionUsesUTF16RangeForEmoji() {
    let pasteboard = PasteboardSpy()
    let panel = OCRResultPanel(pasteboard: pasteboard)
    panel.recognizedText = "A😀B"
    panel.selectedRange = NSRange(location: 1, length: 2)

    panel.copySelection()

    #expect(pasteboard.strings == ["😀"])
}

@Test
func visionRequestUsesRequiredOfflineRecognitionConfiguration() {
    let request = VisionOCRService.makeRequest()

    #expect(request.recognitionLevel == .accurate)
    #expect(request.usesLanguageCorrection)
    #expect(request.recognitionLanguages == ["zh-Hans", "en-US"])
}

@Test
func recognizedLinesSortTopToBottomThenLeftToRight() throws {
    let result = try VisionOCRService.result(from: [
        OCRLine(text: "右上", confidence: 0.9, bounds: CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.1)),
        OCRLine(text: "底部", confidence: 0.3, bounds: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)),
        OCRLine(text: "左上", confidence: 0.6, bounds: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1))
    ])

    #expect(result.text == "左上\n右上\n底部")
    #expect(abs(result.averageConfidence - 0.6) < 0.0001)
}

@Test
func recognizedLinesGroupSmallVerticalJitterBeforeHorizontalSort() throws {
    let result = try VisionOCRService.result(from: [
        OCRLine(text: "右侧", confidence: 0.8, bounds: CGRect(x: 0.62, y: 0.804, width: 0.2, height: 0.08)),
        OCRLine(text: "下一行", confidence: 0.7, bounds: CGRect(x: 0.1, y: 0.62, width: 0.3, height: 0.08)),
        OCRLine(text: "左侧", confidence: 0.9, bounds: CGRect(x: 0.08, y: 0.8, width: 0.2, height: 0.08))
    ])

    #expect(result.text == "左侧\n右侧\n下一行")
}

@Test
func emptyRecognizedLinesReturnNoTextError() {
    #expect(throws: OCRError.noText) {
        try VisionOCRService.result(from: [])
    }
}

@MainActor
@Test
func overlayOCRUsesComposedImageAndKeepsEditingSession() async throws {
    let service = OCRServiceStub(result: .success(OCRResult(text: "明朝 OCR", averageConfidence: 0.9)))
    let overlay = SelectionOverlayView(
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        ocrService: service
    )
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 160, height: 100)
    overlay.setScreenshot(ocrPixelImage(size: NSSize(width: 300, height: 200)))
    let canvas = try #require(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first)
    canvas.mouseDown(with: ocrMouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30)))
    canvas.mouseDragged(with: ocrMouseEvent(.leftMouseDragged, at: CGPoint(x: 90, y: 65)))
    canvas.mouseUp(with: ocrMouseEvent(.leftMouseUp, at: CGPoint(x: 90, y: 65)))

    overlay.startOCR()
    try await waitForOCRPanelText("明朝 OCR", overlay: overlay)

    let sentImage = try #require(service.images.first)
    #expect(ocrImageContainsOpaquePixel(sentImage))
    #expect(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first === canvas)
    #expect(overlay.presentedOCRPanel?.recognizedText == "明朝 OCR")
}

@MainActor
@Test
func overlayOCRErrorPreservesCanvasAndShowsError() async throws {
    let service = OCRServiceStub(result: .failure(OCRError.noText))
    let overlay = SelectionOverlayView(
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        ocrService: service
    )
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 160, height: 100)
    overlay.setScreenshot(ocrPixelImage(size: NSSize(width: 300, height: 200)))
    let canvas = try #require(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first)

    overlay.startOCR()
    try await waitForOCRError("未识别到文字。", overlay: overlay)

    #expect(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first === canvas)
    #expect(overlay.presentedOCRPanel == nil)
    #expect(overlay.ocrErrorMessage == "未识别到文字。")
}

@MainActor
@Test
func newerOCRRequestWinsWhenOlderRequestCompletesLast() async throws {
    let service = ControlledOCRService()
    let overlay = makeOCROverlay(service: service)
    let canvas = try #require(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first)
    let pendingEditor = try beginPendingOCRText("未提交文字", in: canvas)

    overlay.startOCR()
    try await waitForOCRRequestCount(1, service: service)
    overlay.startOCR()
    try await waitForOCRRequestCount(2, service: service)

    service.complete(request: 1, with: .success(OCRResult(text: "请求 B", averageConfidence: 0.9)))
    try await waitForOCRPanelText("请求 B", overlay: overlay)
    service.complete(request: 0, with: .success(OCRResult(text: "过期请求 A", averageConfidence: 0.2)))
    await yieldForOCRPropagation()

    #expect(overlay.presentedOCRPanel?.recognizedText == "请求 B")
    #expect(overlay.ocrErrorMessage == nil)
    #expect(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first === canvas)
    #expect(ocrPendingTextEditors(in: canvas).first === pendingEditor)
    #expect(pendingEditor.stringValue == "未提交文字")
}

@MainActor
@Test
func replacingSelectionInvalidatesInFlightOCRWithoutTouchingNewEditor() async throws {
    let service = ControlledOCRService()
    let overlay = makeOCROverlay(service: service)

    overlay.startOCR()
    try await waitForOCRRequestCount(1, service: service)
    overlay.selectedRect = CGRect(x: 80, y: 55, width: 140, height: 90)
    let replacementCanvas = try #require(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first)
    let pendingEditor = try beginPendingOCRText("新选区文字", in: replacementCanvas)

    service.complete(request: 0, with: .failure(OCRError.noText))
    await yieldForOCRPropagation()

    #expect(overlay.presentedOCRPanel == nil)
    #expect(overlay.ocrErrorMessage == nil)
    #expect(ocrDescendants(of: overlay, as: AnnotationCanvasView.self).first === replacementCanvas)
    #expect(ocrPendingTextEditors(in: replacementCanvas).first === pendingEditor)
    #expect(pendingEditor.stringValue == "新选区文字")
}

@MainActor
@Test
func ocrPanelRemainsInteractiveInDefaultSelectionMode() async throws {
    let service = OCRServiceStub(result: .success(OCRResult(text: "可复制文字", averageConfidence: 0.9)))
    let overlay = makeOCROverlay(service: service)
    overlay.selectedRect = overlay.bounds

    overlay.startOCR()
    try await waitForOCRPanelText("可复制文字", overlay: overlay)
    let panel = try #require(overlay.presentedOCRPanel)
    let copyAllButton = try ocrButton(titled: "复制全部", in: panel)
    let point = copyAllButton.superview?.convert(copyAllButton.frame.center, to: overlay) ?? .zero
    let hitView = try #require(overlay.hitTest(point))

    #expect(hitView === copyAllButton || hitView.isDescendant(of: copyAllButton))
}

@MainActor
@Test
func copyingAllImmediatelyCompletesOCRWorkflowWithoutCommittingImage() async throws {
    let pasteboard = PasteboardSpy()
    let service = OCRServiceStub(result: .success(OCRResult(text: "立即去粘贴", averageConfidence: 0.9)))
    let overlay = SelectionOverlayView(
        frame: CGRect(x: 0, y: 0, width: 600, height: 450),
        ocrService: service,
        ocrPasteboard: pasteboard
    )
    let delegate = OCRSubmissionDelegateSpy()
    overlay.delegate = delegate
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 560, height: 410)
    overlay.setScreenshot(ocrPixelImage(size: NSSize(width: 600, height: 450)))

    overlay.startOCR()
    try await waitForOCRPanelText("立即去粘贴", overlay: overlay)
    let panel = try #require(overlay.presentedOCRPanel)
    panel.copyAll()

    #expect(delegate.ocrCopyCompletionCount == 1)
    #expect(delegate.cancelCount == 0)
    #expect(delegate.committedImages.isEmpty)
    #expect(pasteboard.strings == ["立即去粘贴"])
}

@MainActor
@Test
func copyingSelectionImmediatelyCompletesOCRWorkflowWithExactText() async throws {
    let pasteboard = PasteboardSpy()
    let service = OCRServiceStub(result: .success(OCRResult(text: "明朝 OCR 文本", averageConfidence: 0.9)))
    let overlay = SelectionOverlayView(
        frame: CGRect(x: 0, y: 0, width: 600, height: 450),
        ocrService: service,
        ocrPasteboard: pasteboard
    )
    let delegate = OCRSubmissionDelegateSpy()
    overlay.delegate = delegate
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 560, height: 410)
    overlay.setScreenshot(ocrPixelImage(size: NSSize(width: 600, height: 450)))

    overlay.startOCR()
    try await waitForOCRPanelText("明朝 OCR 文本", overlay: overlay)
    let panel = try #require(overlay.presentedOCRPanel)
    panel.selectedRange = NSRange(location: 3, length: 3)

    panel.copySelection()

    #expect(delegate.ocrCopyCompletionCount == 1)
    #expect(delegate.cancelCount == 0)
    #expect(delegate.committedImages.isEmpty)
    #expect(pasteboard.strings == ["OCR"])
}

@MainActor
@Test
func movingSelectionInvalidatesInFlightOCR() async throws {
    let service = ControlledOCRService()
    let overlay = makeOCROverlay(service: service)

    overlay.startOCR()
    try await waitForOCRRequestCount(1, service: service)
    overlay.beginSelectionInteraction(at: CGPoint(x: 60, y: 60))
    overlay.updateSelectionInteraction(to: CGPoint(x: 90, y: 80))
    overlay.endSelectionInteraction(at: CGPoint(x: 90, y: 80))

    service.complete(request: 0, with: .success(OCRResult(text: "旧选区结果", averageConfidence: 0.9)))
    await yieldForOCRPropagation()

    #expect(overlay.presentedOCRPanel == nil)
    #expect(overlay.ocrErrorMessage == nil)
}

@MainActor
private final class OCRServiceStub: OCRServicing {
    let result: Result<OCRResult, any Error>
    private(set) var images: [NSImage] = []

    init(result: Result<OCRResult, any Error>) {
        self.result = result
    }

    func recognize(image: NSImage) async throws -> OCRResult {
        images.append(image)
        return try result.get()
    }
}

@MainActor
private final class OCRSubmissionDelegateSpy: SelectionOverlayDelegate {
    private(set) var cancelCount = 0
    private(set) var ocrCopyCompletionCount = 0
    private(set) var committedImages: [NSImage] = []

    func overlayDidCancel() {
        cancelCount += 1
    }

    func overlayDidCommit(image: NSImage) {
        committedImages.append(image)
    }

    func overlayDidCopyOCRText(on screen: NSScreen?) {
        ocrCopyCompletionCount += 1
    }
}

@MainActor
private final class ControlledOCRService: OCRServicing {
    private(set) var images: [NSImage] = []
    private var continuations: [Int: CheckedContinuation<OCRResult, any Error>] = [:]

    func recognize(image: NSImage) async throws -> OCRResult {
        let request = images.count
        images.append(image)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func complete(request: Int, with result: Result<OCRResult, any Error>) {
        continuations.removeValue(forKey: request)?.resume(with: result)
    }
}

@MainActor
private func makeOCROverlay(service: any OCRServicing) -> SelectionOverlayView {
    let overlay = SelectionOverlayView(
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        ocrService: service
    )
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 160, height: 100)
    overlay.setScreenshot(ocrPixelImage(size: NSSize(width: 300, height: 200)))
    return overlay
}

@MainActor
private func beginPendingOCRText(_ text: String, in canvas: AnnotationCanvasView) throws -> NSTextField {
    try ocrButton(titled: "文字", in: canvas).performClick(nil)
    canvas.mouseDown(with: ocrMouseEvent(.leftMouseDown, at: CGPoint(x: 45, y: 40)))
    let editor = try #require(ocrPendingTextEditors(in: canvas).first)
    editor.stringValue = text
    return editor
}

@MainActor
private func ocrButton(titled title: String, in view: NSView) throws -> NSButton {
    try #require(ocrDescendants(of: view, as: NSButton.self).first { $0.title == title })
}

@MainActor
private func ocrPendingTextEditors(in view: NSView) -> [NSTextField] {
    ocrDescendants(of: view, as: NSTextField.self).filter { $0.placeholderString == "输入文字" }
}

@MainActor
private func waitForOCRRequestCount(
    _ expectedCount: Int,
    service: ControlledOCRService
) async throws {
    for _ in 0..<100 {
        if service.images.count == expectedCount { return }
        await Task.yield()
    }
    Issue.record("OCR request count did not reach \(expectedCount)")
}

@MainActor
private func waitForOCRPanelText(_ text: String, overlay: SelectionOverlayView) async throws {
    for _ in 0..<100 {
        if overlay.presentedOCRPanel?.recognizedText == text { return }
        await Task.yield()
    }
    Issue.record("OCR panel did not present expected text")
}

@MainActor
private func waitForOCRError(_ message: String, overlay: SelectionOverlayView) async throws {
    for _ in 0..<100 {
        if overlay.ocrErrorMessage == message { return }
        await Task.yield()
    }
    Issue.record("OCR error did not present expected message")
}

@MainActor
private func yieldForOCRPropagation() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
private func ocrDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = view.subviews.compactMap { $0 as? T }
    for subview in view.subviews {
        result.append(contentsOf: ocrDescendants(of: subview, as: type))
    }
    return result
}

private func ocrMouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}

private func ocrPixelImage(size: NSSize) -> NSImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: Int(size.width) * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.clear(CGRect(origin: .zero, size: size))
    return NSImage(cgImage: context.makeImage()!, size: size)
}

private func ocrImageContainsOpaquePixel(_ image: NSImage) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    for x in 0..<cgImage.width {
        for y in 0..<cgImage.height where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            return true
        }
    }
    return false
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
