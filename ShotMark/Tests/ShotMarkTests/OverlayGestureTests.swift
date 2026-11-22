import AppKit
import Testing
@testable import ShotMark

@MainActor
@Test
func nonKeyOverlayAcceptsFirstMouseForImmediateSelection() {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let firstClick = mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 50), clickCount: 1)

    #expect(overlay.acceptsFirstMouse(for: firstClick))
}

@MainActor
@Test
func realDoubleClickSequenceCommitsWithoutAppendingBrushMark() throws {
    for toolTitle in ["箭头", "画笔"] {
        let canvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: 80, height: 80),
            image: makePixelImage(size: NSSize(width: 80, height: 80), pixelsWide: 80, pixelsHigh: 80) { _, _ in .clear }
        )
        try clickButton(titled: toolTitle, in: canvas)
        var committedImage: NSImage?
        canvas.commitHandler = { committedImage = canvas.composePNGImage() }

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30), clickCount: 1))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 30, y: 30), clickCount: 1))
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30), clickCount: 2))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 30, y: 30), clickCount: 2))

        let image = try #require(committedImage)
        #expect(!imageContainsOpaquePixel(image))
    }
}

@MainActor
@Test
func beginningAnotherTextEditFinalizesTheFirstAndKeepsExactlyOneEditor() throws {
    let canvas = makeTransparentCanvas()
    try clickButton(titled: "文字", in: canvas)
    try chooseColor("red", in: canvas)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 40), clickCount: 1))
    let firstEditor = try #require(textEditors(in: canvas).first)
    firstEditor.stringValue = "First"

    try chooseColor("blue", in: canvas)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 80, y: 40), clickCount: 1))
    let secondEditor = try #require(textEditors(in: canvas).first)
    secondEditor.stringValue = "Second"

    #expect(textEditors(in: canvas).count == 1)
    let withBoth = canvas.composePNGImage()
    #expect(imageContainsColor(withBoth, .systemRed))
    #expect(imageContainsColor(withBoth, .systemBlue))

    canvas.undo()
    let afterUndo = canvas.composePNGImage()
    #expect(imageContainsColor(afterUndo, .systemRed))
    #expect(!imageContainsColor(afterUndo, .systemBlue))
}

@MainActor
@Test
func endingTextEditingFinalizesTextIntoHistory() throws {
    let canvas = makeTransparentCanvas()
    try clickButton(titled: "文字", in: canvas)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 40), clickCount: 1))
    let editor = try #require(textEditors(in: canvas).first)
    editor.stringValue = "Saved"

    let notification = Notification(name: NSControl.textDidEndEditingNotification, object: editor)
    editor.delegate?.controlTextDidEndEditing?(notification)

    #expect(textEditors(in: canvas).isEmpty)
    #expect(imageContainsOpaquePixel(canvas.composePNGImage()))
}

@MainActor
@Test
func textFieldDoubleClickFinalizesPendingTextBeforeCommit() throws {
    let canvas = makeTransparentCanvas()
    try clickButton(titled: "文字", in: canvas)
    var committedImage: NSImage?
    canvas.commitHandler = { committedImage = canvas.composePNGImage() }
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), clickCount: 1))
    let editor = try #require(textEditors(in: canvas).first)
    editor.stringValue = "Draft"

    editor.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), clickCount: 2))

    #expect(textEditors(in: canvas).isEmpty)
    #expect(committedImage.map(imageContainsOpaquePixel) == true)
}

@MainActor
@Test
func commandCFinalizesPendingTextAndCommits() throws {
    let (overlay, delegate) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "文字", in: overlay)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), clickCount: 1))
    let editor = try #require(textEditors(in: canvas).first)
    editor.stringValue = "Command"

    overlay.keyDown(with: keyEvent(characters: "c", keyCode: 8, modifiers: .command))

    #expect(delegate.committedImages.count == 1)
    #expect(delegate.committedImages.first.map(imageContainsOpaquePixel) == true)
    #expect(textEditors(in: canvas).isEmpty)
}

@MainActor
@Test
func toolbarCompletionFinalizesPendingTextAndCommits() throws {
    let (overlay, delegate) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "文字", in: overlay)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), clickCount: 1))
    let editor = try #require(textEditors(in: canvas).first)
    editor.stringValue = "Toolbar"

    try clickButton(titled: "完成", in: overlay)

    #expect(delegate.committedImages.count == 1)
    #expect(delegate.committedImages.first.map(imageContainsOpaquePixel) == true)
    #expect(textEditors(in: canvas).isEmpty)
}

@MainActor
@Test
func escapeRoutesToCancelWithoutCommit() {
    let (overlay, delegate) = makeOverlay()

    overlay.keyDown(with: keyEvent(characters: "\u{1b}", keyCode: 53, modifiers: []))

    #expect(delegate.cancelCount == 1)
    #expect(delegate.committedImages.isEmpty)
}

@MainActor
@Test
func simpleOutsideClickPreservesExistingSelection() {
    let (overlay, _) = makeOverlay()
    let originalRect = overlay.selectedRect

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 260, y: 180), clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 260, y: 180), clickCount: 1))

    #expect(overlay.selectedRect == originalRect)
    #expect(annotationCanvas(in: overlay) != nil)
}

@MainActor
@Test
func outsideDoubleClickRejectsCommitAndPreservesSelection() {
    let (overlay, delegate) = makeOverlay()
    let originalRect = overlay.selectedRect
    let point = CGPoint(x: 260, y: 180)

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: point, clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: point, clickCount: 1))
    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: point, clickCount: 2))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: point, clickCount: 2))

    #expect(delegate.committedImages.isEmpty)
    #expect(overlay.selectedRect == originalRect)
}

@MainActor
@Test
func onlyMovementPastDragThresholdReplacesSelection() {
    let (overlay, _) = makeOverlay()
    let originalRect = overlay.selectedRect

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 220, y: 150), clickCount: 1))
    overlay.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 222, y: 152), clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 222, y: 152), clickCount: 1))
    #expect(overlay.selectedRect == originalRect)

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 210, y: 140), clickCount: 1))
    overlay.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 250, y: 175), clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 250, y: 175), clickCount: 1))
    #expect(overlay.selectedRect == CGRect(x: 210, y: 140, width: 40, height: 35))
}

@MainActor
@Test
func invalidOneDimensionalDragRestoresExistingSelection() {
    let (overlay, _) = makeOverlay()
    let originalRect = overlay.selectedRect

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 220, y: 150), clickCount: 1))
    overlay.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 235, y: 151), clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 235, y: 151), clickCount: 1))

    #expect(overlay.selectedRect == originalRect)
    #expect(annotationCanvas(in: overlay) != nil)
}

@MainActor
@Test
func invalidDragPreservesExactCanvasHistoryStylesAndPendingText() throws {
    let (overlay, _) = makeOverlay()
    let originalRect = overlay.selectedRect
    let originalCanvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "箭头", in: overlay)
    let widthPicker = try #require(descendants(of: overlay, as: NSPopUpButton.self).first { $0.itemTitles.contains("6 px") })
    try chooseColor("blue", in: overlay)
    widthPicker.selectItem(withTitle: "6 px")
    _ = widthPicker.sendAction(widthPicker.action, to: widthPicker.target)
    originalCanvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 1))
    originalCanvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 135, y: 85), clickCount: 1))
    originalCanvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 135, y: 85), clickCount: 1))

    try clickButton(titled: "文字", in: overlay)
    originalCanvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 60, y: 60), clickCount: 1))
    let pendingEditor = try #require(textEditors(in: originalCanvas).first)
    pendingEditor.stringValue = "Pending"

    overlay.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 220, y: 150), clickCount: 1))
    overlay.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 235, y: 151), clickCount: 1))
    overlay.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 235, y: 151), clickCount: 1))

    let restoredCanvas = try #require(annotationCanvas(in: overlay))
    #expect(overlay.selectedRect == originalRect)
    #expect(restoredCanvas === originalCanvas)
    #expect(textEditors(in: restoredCanvas).first === pendingEditor)
    #expect(pendingEditor.stringValue == "Pending")

    let composed = restoredCanvas.composePNGImage()
    #expect(imageContainsColor(composed, .systemBlue))
    #expect(imageContainsColor(composed, .systemRed))
    restoredCanvas.undo()
    let afterTextUndo = restoredCanvas.composePNGImage()
    #expect(imageContainsColor(afterTextUndo, .systemBlue))
    #expect(!imageContainsColor(afterTextUndo, .systemRed))
    restoredCanvas.undo()
    #expect(!imageContainsOpaquePixel(restoredCanvas.composePNGImage()))

    try clickButton(titled: "箭头", in: overlay)
    #expect(try button(identifier: "color-option-blue", in: overlay).state == .on)
    #expect(widthPicker.selectedItem?.title == "6 px")
}

@MainActor
@Test
func windowDoubleClickInsideSelectedContentUsesSendEventWithoutAddingAnnotation() throws {
    let (window, delegate) = try makeOverlayWindow()
    defer { window.orderOut(nil) }
    let overlay = window.overlayView
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "画笔", in: overlay)
    let point = CGPoint(x: 150, y: 140)
    canvas.mouseDown(with: mouseEvent(
        .leftMouseDown,
        at: point,
        clickCount: 1,
        windowNumber: window.windowNumber
    ))
    canvas.mouseUp(with: mouseEvent(
        .leftMouseUp,
        at: point,
        clickCount: 1,
        windowNumber: window.windowNumber
    ))

    window.sendEvent(mouseEvent(
        .leftMouseDown,
        at: point,
        clickCount: 2,
        windowNumber: window.windowNumber
    ))

    let image = try #require(delegate.committedImages.first)
    #expect(delegate.committedImages.count == 1)
    #expect(!imageContainsOpaquePixel(image))
}

@MainActor
@Test
func commandCThroughWindowFinalizesTextWhileFieldEditorOwnsFocus() throws {
    let (window, delegate) = try makeOverlayWindow()
    defer { window.orderOut(nil) }
    let overlay = window.overlayView
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "文字", in: overlay)
    canvas.mouseDown(with: mouseEvent(
        .leftMouseDown,
        at: CGPoint(x: 150, y: 140),
        clickCount: 1,
        windowNumber: window.windowNumber
    ))
    let editor = try #require(textEditors(in: canvas).first)
    editor.stringValue = "Focused"
    let fieldEditor = try #require(window.fieldEditor(true, for: editor) as? NSTextView)
    #expect(window.makeFirstResponder(fieldEditor))
    #expect(window.firstResponder === fieldEditor)

    let handled = window.performKeyEquivalent(with: keyEvent(
        characters: "c",
        keyCode: 8,
        modifiers: .command,
        windowNumber: window.windowNumber
    ))

    #expect(handled)
    #expect(delegate.committedImages.count == 1)
    #expect(delegate.committedImages.first.map(imageContainsOpaquePixel) == true)
}

@MainActor
@Test
func overlappingToolbarDoubleClickDoesNotCommitAndButtonActionProceeds() throws {
    let (window, delegate) = try makeOverlayWindow()
    defer { window.orderOut(nil) }
    let overlay = window.overlayView
    let canvas = try #require(annotationCanvas(in: overlay))
    let surface = canvas.annotationControlSurface
    let textButton = try button(titled: "文字", in: overlay)
    let buttonRectInSurface = textButton.superview?.convert(textButton.frame, to: surface) ?? .zero
    let selectedCenter = try #require(overlay.selectedRect).center
    surface.frame.origin = CGPoint(
        x: selectedCenter.x - buttonRectInSurface.midX,
        y: selectedCenter.y - buttonRectInSurface.midY
    )
    #expect(surface.frame.contains(selectedCenter))
    #expect(overlay.hitTest(selectedCenter)?.isDescendant(of: surface) == true)

    let mouseUp = mouseEvent(
        .leftMouseUp,
        at: selectedCenter,
        clickCount: 2,
        windowNumber: window.windowNumber
    )
    NSApp.postEvent(mouseUp, atStart: true)
    window.sendEvent(mouseEvent(
        .leftMouseDown,
        at: selectedCenter,
        clickCount: 2,
        windowNumber: window.windowNumber
    ))

    #expect(delegate.committedImages.isEmpty)
    #expect(textButton.state == .on)
    canvas.mouseDown(with: mouseEvent(
        .leftMouseDown,
        at: CGPoint(x: 150, y: 140),
        clickCount: 1,
        windowNumber: window.windowNumber
    ))
    #expect(textEditors(in: canvas).count == 1)
}

@MainActor
@Test
func windowDoubleClickOnResizeHandleDoesNotCommit() throws {
    let (window, delegate) = try makeOverlayWindow()
    defer { window.orderOut(nil) }
    let handle = try #require(window.overlayView.selectionHandleRects[.topLeft])

    window.sendEvent(mouseEvent(
        .leftMouseDown,
        at: handle.center,
        clickCount: 2,
        windowNumber: window.windowNumber
    ))

    #expect(delegate.committedImages.isEmpty)
}

@MainActor
@Test
func resizingLeftEdgeKeepsAnnotationsOverOriginalPixelsAndPreservesUndoRedo() throws {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
    overlay.selectedRect = CGRect(x: 40, y: 40, width: 100, height: 80)
    overlay.setScreenshot(makePixelImage(
        size: NSSize(width: 200, height: 150),
        pixelsWide: 200,
        pixelsHigh: 150
    ) { _, _ in .clear })
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "画笔", in: overlay)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 60, y: 60), clickCount: 1))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 70, y: 60), clickCount: 1))
    canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 70, y: 60), clickCount: 1))
    try clickButton(titled: "选区", in: overlay)

    let leftHandle = try #require(overlay.selectionHandleRects[.left])
    overlay.beginSelectionInteraction(at: leftHandle.center)
    overlay.updateSelectionInteraction(to: CGPoint(x: 20, y: leftHandle.center.y))
    overlay.endSelectionInteraction(at: CGPoint(x: 20, y: leftHandle.center.y))

    let resizedCanvas = try #require(annotationCanvas(in: overlay))
    let resizedImage = resizedCanvas.composePNGImage()
    #expect(imageContainsColorInXRange(resizedImage, .systemRed, 36..<54))
    #expect(!imageContainsColorInXRange(resizedImage, .systemRed, 16..<34))

    resizedCanvas.undo()
    #expect(!imageContainsOpaquePixel(resizedCanvas.composePNGImage()))
    resizedCanvas.redo()
    #expect(imageContainsColorInXRange(resizedCanvas.composePNGImage(), .systemRed, 36..<54))
}

@MainActor
@Test
func floatingToolbarControlsRemainReachableForTinySelections() throws {
    for selection in [
        CGRect(x: 20, y: 20, width: 100, height: 60),
        CGRect(x: 1_000, y: 700, width: 36, height: 20)
    ] {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 1_280, height: 800))
        overlay.selectedRect = selection
        overlay.setScreenshot(makePixelImage(
            size: NSSize(width: 1_280, height: 800),
            pixelsWide: 1_280,
            pixelsHigh: 800
        ) { _, _ in .clear })
        overlay.layoutSubtreeIfNeeded()
        let canvas = try #require(annotationCanvas(in: overlay))
        let completion = try button(titled: "完成", in: overlay)

        #expect(!completion.isDescendant(of: canvas))
        for control in descendants(of: overlay, as: NSControl.self) where !control.isHidden {
            let frame = control.superview?.convert(control.frame, to: overlay) ?? .zero
            #expect(overlay.bounds.contains(frame))
        }

        try clickButton(titled: "文字", in: overlay)
        overlay.layoutSubtreeIfNeeded()
        for control in descendants(of: overlay, as: NSControl.self) where !control.isHidden {
            let frame = control.superview?.convert(control.frame, to: overlay) ?? .zero
            #expect(overlay.bounds.contains(frame))
        }
        for title in ["14", "18", "24", "32"] {
            let sizePicker = try #require(descendants(of: overlay, as: NSPopUpButton.self).first { $0.itemTitles.contains(title) })
            #expect(!sizePicker.isHidden)
            let frame = sizePicker.superview?.convert(sizePicker.frame, to: overlay) ?? .zero
            #expect(overlay.bounds.contains(frame))
        }
    }
}

@MainActor
@Test
func strokeToolsRememberTheirOwnColorAndWidth() throws {
    let (overlay, _) = makeOverlay()
    try clickButton(titled: "箭头", in: overlay)
    let widthPicker = try #require(descendants(of: overlay, as: NSPopUpButton.self).first { $0.itemTitles.contains("6 px") })
    try chooseColor("blue", in: overlay)
    widthPicker.selectItem(withTitle: "6 px")
    _ = widthPicker.sendAction(widthPicker.action, to: widthPicker.target)

    try clickButton(titled: "画笔", in: overlay)
    try chooseColor("red", in: overlay)
    widthPicker.selectItem(withTitle: "8 px")
    _ = widthPicker.sendAction(widthPicker.action, to: widthPicker.target)
    try clickButton(titled: "箭头", in: overlay)

    #expect(try button(identifier: "color-option-blue", in: overlay).state == .on)
    #expect(widthPicker.selectedItem?.title == "6 px")
}

@MainActor
@Test
func colorControlOpensInlineSwatchDrawerAndOrangeChangesTheStroke() throws {
    let (overlay, _) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "画笔", in: overlay)
    let colorButton = try button(identifier: "color-picker", in: overlay)
    let orangeButton = try button(identifier: "color-option-orange", in: overlay)

    #expect(colorButton.title.isEmpty)
    #expect(isEffectivelyHidden(orangeButton))

    colorButton.performClick(nil)

    #expect(!isEffectivelyHidden(orangeButton))
    #expect(orangeButton.title.isEmpty)

    orangeButton.performClick(nil)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 1))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 70), clickCount: 1))
    canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 70), clickCount: 1))

    #expect(isEffectivelyHidden(orangeButton))
    #expect(imageContainsColor(canvas.composePNGImage(), .systemOrange))
}

@MainActor
@Test
func colorSwatchesHaveComfortableTargetsAndPinkRendersDistinctly() throws {
    let (overlay, _) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "画笔", in: overlay)
    let colorButton = try button(identifier: "color-picker", in: overlay)
    let pinkButton = try button(identifier: "color-option-pink", in: overlay)

    colorButton.performClick(nil)
    overlay.layoutSubtreeIfNeeded()

    #expect(colorButton.frame.width >= 28)
    #expect(colorButton.frame.height >= 28)
    #expect(pinkButton.frame.width >= 28)
    #expect(pinkButton.frame.height >= 28)
    #expect((pinkButton.image?.size.width ?? 0) >= 24)

    pinkButton.performClick(nil)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 1))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 70), clickCount: 1))
    canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 70), clickCount: 1))

    let expectedPink = NSColor(srgbRed: 1, green: 0.35, blue: 0.64, alpha: 1)
    #expect(imageContainsColor(canvas.composePNGImage(), expectedPink))
    #expect(!imageContainsColor(canvas.composePNGImage(), .systemRed))
}

@MainActor
@Test
func undoAndRedoButtonsTrackHistoryAndRestoreTheRenderedStroke() throws {
    let (overlay, _) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    let undoButton = try button(titled: "撤销", in: overlay)
    let redoButton = try button(titled: "重做", in: overlay)

    #expect(!undoButton.isEnabled)
    #expect(!redoButton.isEnabled)

    try clickButton(titled: "画笔", in: overlay)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 1))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 70), clickCount: 1))
    canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 70), clickCount: 1))

    #expect(undoButton.isEnabled)
    undoButton.performClick(nil)
    #expect(!imageContainsOpaquePixel(canvas.composePNGImage()))
    #expect(redoButton.isEnabled)

    redoButton.performClick(nil)
    #expect(imageContainsOpaquePixel(canvas.composePNGImage()))
}

@MainActor
@Test
func commandZAndCommandShiftZRouteToCanvasUndoAndRedo() throws {
    let (overlay, _) = makeOverlay()
    let canvas = try #require(annotationCanvas(in: overlay))
    try clickButton(titled: "画笔", in: overlay)
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 1))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 70), clickCount: 1))
    canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 70), clickCount: 1))

    let handledUndo = overlay.handleKeyEquivalent(
        keyCode: 6,
        charactersIgnoringModifiers: "z",
        modifiers: .command
    )
    #expect(handledUndo)
    #expect(!imageContainsOpaquePixel(canvas.composePNGImage()))

    let handledRedo = overlay.handleKeyEquivalent(
        keyCode: 6,
        charactersIgnoringModifiers: "z",
        modifiers: [.command, .shift]
    )
    #expect(handledRedo)
    #expect(imageContainsOpaquePixel(canvas.composePNGImage()))
}

@MainActor
@Test
func ocrControlIsEnabledWhileImageCopyRemainsDisabled() throws {
    let (overlay, _) = makeOverlay()

    #expect(try button(titled: "OCR", in: overlay).isEnabled)
    #expect(try !button(titled: "复制图片", in: overlay).isEnabled)
}

@MainActor
@Test
func selectedCanvasPreservesScreenshotVerticalOrientation() throws {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
    overlay.selectedRect = CGRect(x: 1, y: 1, width: 2, height: 2)
    overlay.setScreenshot(makePixelImage(
        size: NSSize(width: 4, height: 4),
        pixelsWide: 4,
        pixelsHigh: 4
    ) { x, y in
        if x == 1, y == 1 { return .red }
        if x == 2, y == 2 { return .blue }
        return .clear
    })

    let canvas = try #require(annotationCanvas(in: overlay))
    let selectedImage = canvas.composePNGImage()

    #expect(colorsApproximatelyEqual(colorAt(selectedImage, x: 0, y: 0), .red))
    #expect(colorsApproximatelyEqual(colorAt(selectedImage, x: 1, y: 1), .blue))
}

@MainActor
@Test
func topSelectionCropsTopSourcePixels() throws {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 9, height: 9))
    let delegate = SelectionOverlayDelegateSpy()
    overlay.delegate = delegate
    overlay.selectedRect = CGRect(x: 2, y: 6, width: 3, height: 3)
    overlay.setScreenshot(makePixelImage(size: NSSize(width: 9, height: 9), pixelsWide: 9, pixelsHigh: 9) { _, y in
        switch y {
        case 6..<9: .red
        case 3..<6: .green
        default: .blue
        }
    })

    overlay.handleMouseDown(at: CGPoint(x: 3, y: 7), clickCount: 2)

    let image = try #require(delegate.committedImages.first)
    #expect(colorsApproximatelyEqual(colorAt(image, x: 0, y: 0), .red))
    #expect(colorsApproximatelyEqual(colorAt(image, x: 1, y: 1), .red))
    #expect(colorsApproximatelyEqual(colorAt(image, x: 2, y: 2), .red))
}

@MainActor
@Test
func asymmetricTwoTimesCropPreservesExactPixels() throws {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 8, height: 6))
    let delegate = SelectionOverlayDelegateSpy()
    overlay.delegate = delegate
    overlay.captureBackingScale = 2
    overlay.selectedRect = CGRect(x: 1, y: 2, width: 3, height: 2)
    overlay.setScreenshot(makePixelImage(size: NSSize(width: 8, height: 6), pixelsWide: 16, pixelsHigh: 12) { x, y in
        if x == 2, y == 4 { return .red }
        if x == 7, y == 7 { return .blue }
        return .clear
    })

    overlay.handleMouseDown(at: CGPoint(x: 2, y: 3), clickCount: 2)

    let image = try #require(delegate.committedImages.first)
    let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(image.size == NSSize(width: 3, height: 2))
    #expect(cgImage.width == 6)
    #expect(cgImage.height == 4)
    #expect(colorsApproximatelyEqual(colorAt(image, x: 0, y: 0), .red))
    #expect(colorsApproximatelyEqual(colorAt(image, x: 5, y: 3), .blue))
}

@MainActor
private final class SelectionOverlayDelegateSpy: SelectionOverlayDelegate {
    private(set) var cancelCount = 0
    private(set) var committedImages: [NSImage] = []

    func overlayDidCancel() {
        cancelCount += 1
    }

    func overlayDidCommit(image: NSImage) {
        committedImages.append(image)
    }

    func overlayDidCopyOCRText(on screen: NSScreen?) {}
}

@MainActor
private func makeOverlay() -> (SelectionOverlayView, SelectionOverlayDelegateSpy) {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let delegate = SelectionOverlayDelegateSpy()
    overlay.delegate = delegate
    overlay.selectedRect = CGRect(x: 20, y: 20, width: 160, height: 100)
    overlay.setScreenshot(makePixelImage(
        size: NSSize(width: 300, height: 200),
        pixelsWide: 300,
        pixelsHigh: 200
    ) { _, _ in .clear })
    overlay.layoutSubtreeIfNeeded()
    return (overlay, delegate)
}

@MainActor
private func makeOverlayWindow() throws -> (SelectionOverlayWindow, SelectionOverlayDelegateSpy) {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let window = SelectionOverlayWindow(screen: screen)
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    let delegate = SelectionOverlayDelegateSpy()
    window.overlayDelegate = delegate
    window.overlayView.selectedRect = CGRect(x: 100, y: 100, width: 240, height: 140)
    window.setScreenshot(NSImage(size: window.overlayView.bounds.size))
    window.overlayView.layoutSubtreeIfNeeded()
    return (window, delegate)
}

@MainActor
private func makeTransparentCanvas() -> AnnotationCanvasView {
    AnnotationCanvasView(
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        image: makePixelImage(size: NSSize(width: 200, height: 100), pixelsWide: 200, pixelsHigh: 100) { _, _ in .clear }
    )
}

@MainActor
private func annotationCanvas(in view: NSView) -> AnnotationCanvasView? {
    descendants(of: view, as: AnnotationCanvasView.self).first
}

@MainActor
private func textEditors(in view: NSView) -> [NSTextField] {
    descendants(of: view, as: NSTextField.self).filter { $0.placeholderString == "输入文字" }
}

@MainActor
private func clickButton(titled title: String, in view: NSView) throws {
    try button(titled: title, in: view).performClick(nil)
}

@MainActor
private func button(titled title: String, in view: NSView) throws -> NSButton {
    try #require(descendants(of: view, as: NSButton.self).first { $0.title == title })
}

@MainActor
private func button(identifier: String, in view: NSView) throws -> NSButton {
    try #require(descendants(of: view, as: NSButton.self).first { $0.identifier?.rawValue == identifier })
}

@MainActor
private func chooseColor(_ identifier: String, in view: NSView) throws {
    let option = try button(identifier: "color-option-\(identifier)", in: view)
    if isEffectivelyHidden(option) {
        try button(identifier: "color-picker", in: view).performClick(nil)
    }
    option.performClick(nil)
}

@MainActor
private func isEffectivelyHidden(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
}

@MainActor
private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = view.subviews.compactMap { $0 as? T }
    for subview in view.subviews {
        result.append(contentsOf: descendants(of: subview, as: type))
    }
    return result
}

private func mouseEvent(
    _ type: NSEvent.EventType,
    at point: CGPoint,
    clickCount: Int,
    windowNumber: Int = 0
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )!
}

private func keyEvent(
    characters: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    windowNumber: Int = 0
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

private func makePixelImage(
    size: NSSize,
    pixelsWide: Int,
    pixelsHigh: Int,
    colorAtPixel: (Int, Int) -> NSColor
) -> NSImage {
    let context = CGContext(
        data: nil,
        width: pixelsWide,
        height: pixelsHigh,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<pixelsWide {
        for y in 0..<pixelsHigh {
            context.setFillColor(colorAtPixel(x, y).cgColor)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return NSImage(cgImage: context.makeImage()!, size: size)
}

private func imageContainsOpaquePixel(_ image: NSImage) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    for x in 0..<cgImage.width {
        for y in 0..<cgImage.height where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            return true
        }
    }
    return false
}

private func imageContainsColor(_ image: NSImage, _ expectedColor: NSColor) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    for x in 0..<cgImage.width {
        for y in 0..<cgImage.height {
            guard let actual = bitmap.colorAt(x: x, y: y), actual.alphaComponent > 0.2 else { continue }
            if colorsApproximatelyEqual(actual, expectedColor) {
                return true
            }
        }
    }
    return false
}

private func colorAt(_ image: NSImage, x: Int, y: Int) -> NSColor {
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    return NSBitmapImageRep(cgImage: cgImage).colorAt(x: x, y: y)!
}

private func colorsApproximatelyEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
    let lhs = lhs.usingColorSpace(.deviceRGB)!
    let rhs = rhs.usingColorSpace(.deviceRGB)!
    return abs(lhs.redComponent - rhs.redComponent) < 0.05
        && abs(lhs.greenComponent - rhs.greenComponent) < 0.05
        && abs(lhs.blueComponent - rhs.blueComponent) < 0.05
        && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.05
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private func imageContainsColorInXRange(
    _ image: NSImage,
    _ color: NSColor,
    _ range: Range<Int>
) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let validRange = max(0, range.lowerBound)..<min(cgImage.width, range.upperBound)
    guard !validRange.isEmpty else { return false }
    for x in validRange {
        for y in 0..<cgImage.height where colorsApproximatelyEqual(colorAt(image, x: x, y: y), color) {
            return true
        }
    }
    return false
}
