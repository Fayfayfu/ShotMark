import AppKit
import Testing
@testable import ShotMark

@MainActor
@Test
func cursorScreenIsInitiallyFullySelected() {
    let frames = [
        CGRect(x: -800, y: 0, width: 800, height: 600),
        CGRect(x: 0, y: 0, width: 1200, height: 800),
        CGRect(x: 1200, y: 100, width: 900, height: 700)
    ]

    #expect(CaptureCoordinator.initialSelectionIndex(
        screenFrames: frames,
        mouseLocation: CGPoint(x: 1500, y: 300)
    ) == 2)
}

@MainActor
@Test
func draggingInsideDefaultFullScreenSelectionCreatesANewSelection() {
    let overlay = makeSelectionOverlay()
    overlay.selectAllAsDefault()

    overlay.beginSelectionInteraction(at: CGPoint(x: 60, y: 50))
    overlay.updateSelectionInteraction(to: CGPoint(x: 140, y: 110))
    overlay.endSelectionInteraction(at: CGPoint(x: 140, y: 110))

    #expect(overlay.selectedRect == CGRect(x: 60, y: 50, width: 80, height: 60))
}

@MainActor
@Test
func clickingDefaultFullScreenSelectionWithoutDraggingKeepsFullScreen() {
    let overlay = makeSelectionOverlay()
    overlay.selectAllAsDefault()

    overlay.beginSelectionInteraction(at: CGPoint(x: 60, y: 50))
    overlay.endSelectionInteraction(at: CGPoint(x: 60, y: 50))

    #expect(overlay.selectedRect == overlay.bounds)
}

@MainActor
@Test
func defaultFullScreenSelectionDoesNotShowResizeHandles() {
    let overlay = makeSelectionOverlay()
    overlay.selectAllAsDefault()

    #expect(overlay.selectionHandleRects.isEmpty)
}

@MainActor
@Test
func defaultFullScreenSelectionDoubleClickCommits() {
    let overlay = makeSelectionOverlay()
    let delegate = SelectionInteractionDelegateSpy()
    overlay.delegate = delegate
    overlay.selectAllAsDefault()

    overlay.handleMouseDown(at: CGPoint(x: 150, y: 100), clickCount: 2)

    #expect(delegate.commitCount == 1)
}

@MainActor
@Test
func annotationModeKeepsDefaultFullScreenSelectionDuringDrag() {
    let overlay = makeSelectionOverlay()
    overlay.selectAllAsDefault()
    overlay.setSelectionModeEnabled(false)

    overlay.beginSelectionInteraction(at: CGPoint(x: 60, y: 50))
    overlay.updateSelectionInteraction(to: CGPoint(x: 140, y: 110))
    overlay.endSelectionInteraction(at: CGPoint(x: 140, y: 110))

    #expect(overlay.selectedRect == overlay.bounds)
}

@MainActor
@Test
func customSelectionAfterDefaultFullScreenRestoresMoveAndAllHandles() {
    let overlay = makeSelectionOverlay()
    overlay.selectAllAsDefault()
    overlay.selectedRect = CGRect(x: 60, y: 50, width: 80, height: 60)

    #expect(overlay.selectionHandleRects.count == 8)
    overlay.beginSelectionInteraction(at: CGPoint(x: 90, y: 80))
    overlay.updateSelectionInteraction(to: CGPoint(x: 100, y: 90))
    overlay.endSelectionInteraction(at: CGPoint(x: 100, y: 90))

    #expect(overlay.selectedRect == CGRect(x: 70, y: 60, width: 80, height: 60))
}

@MainActor
@Test
func selectionModeMovesSelectionAndClampsToScreen() {
    let overlay = makeSelectionOverlay()
    overlay.selectedRect = CGRect(x: 40, y: 30, width: 120, height: 80)
    overlay.setSelectionModeEnabled(true)

    overlay.beginSelectionInteraction(at: CGPoint(x: 90, y: 70))
    overlay.updateSelectionInteraction(to: CGPoint(x: 290, y: 190))
    overlay.endSelectionInteraction(at: CGPoint(x: 290, y: 190))

    #expect(overlay.selectedRect == CGRect(x: 180, y: 120, width: 120, height: 80))
}

@MainActor
@Test
func cornerHandleResizesSelectionWithinBounds() throws {
    let overlay = makeSelectionOverlay()
    overlay.selectedRect = CGRect(x: 60, y: 50, width: 140, height: 100)
    let handle = try #require(overlay.selectionHandleRects[.topLeft])

    overlay.beginSelectionInteraction(at: handle.center)
    overlay.updateSelectionInteraction(to: CGPoint(x: -20, y: 220))
    overlay.endSelectionInteraction(at: CGPoint(x: -20, y: 220))

    #expect(overlay.selectedRect == CGRect(x: 0, y: 50, width: 200, height: 150))
}

@MainActor
@Test
func edgeHandleHonorsMinimumSelectionSize() throws {
    let overlay = makeSelectionOverlay()
    overlay.selectedRect = CGRect(x: 40, y: 40, width: 100, height: 80)
    let handle = try #require(overlay.selectionHandleRects[.left])

    overlay.beginSelectionInteraction(at: handle.center)
    overlay.updateSelectionInteraction(to: CGPoint(x: 135, y: 80))
    overlay.endSelectionInteraction(at: CGPoint(x: 135, y: 80))

    #expect(overlay.selectedRect?.width == SelectionOverlayView.minimumSelectionSize)
}

@MainActor
@Test
func annotationModeDoesNotMoveSelectionFromInteriorDrag() {
    let overlay = makeSelectionOverlay()
    let original = CGRect(x: 40, y: 30, width: 120, height: 80)
    overlay.selectedRect = original
    overlay.setSelectionModeEnabled(false)

    overlay.beginSelectionInteraction(at: CGPoint(x: 90, y: 70))
    overlay.updateSelectionInteraction(to: CGPoint(x: 140, y: 100))
    overlay.endSelectionInteraction(at: CGPoint(x: 140, y: 100))

    #expect(overlay.selectedRect == original)
}

@MainActor
@Test
func startingNewSelectionNotifiesCrossScreenCoordinator() {
    let overlay = makeSelectionOverlay()
    overlay.selectedRect = nil
    var notificationCount = 0
    overlay.selectionDidBegin = { notificationCount += 1 }

    overlay.beginSelectionInteraction(at: CGPoint(x: 20, y: 20))
    overlay.updateSelectionInteraction(to: CGPoint(x: 100, y: 90))
    overlay.endSelectionInteraction(at: CGPoint(x: 100, y: 90))

    #expect(notificationCount == 1)
    #expect(overlay.selectedRect == CGRect(x: 20, y: 20, width: 80, height: 70))
}

@MainActor
@Test
func newSelectionHonorsMinimumSize() {
    let overlay = makeSelectionOverlay()
    overlay.selectedRect = nil

    overlay.beginSelectionInteraction(at: CGPoint(x: 20, y: 20))
    overlay.updateSelectionInteraction(to: CGPoint(x: 25, y: 25))
    overlay.endSelectionInteraction(at: CGPoint(x: 25, y: 25))

    #expect(overlay.selectedRect == CGRect(
        x: 20,
        y: 20,
        width: SelectionOverlayView.minimumSelectionSize,
        height: SelectionOverlayView.minimumSelectionSize
    ))
}

@MainActor
@Test
func doubleClickOnResizeHandleDoesNotCommit() throws {
    let overlay = makeSelectionOverlay()
    let delegate = SelectionInteractionDelegateSpy()
    overlay.delegate = delegate
    overlay.selectedRect = CGRect(x: 40, y: 30, width: 120, height: 80)
    let handle = try #require(overlay.selectionHandleRects[.topLeft])

    #expect(!overlay.shouldCommitDoubleClick(at: handle.center))
    overlay.mouseDown(with: selectionMouseEvent(at: handle.center, clickCount: 2))
    #expect(delegate.commitCount == 0)
}

@MainActor
@Test
func activatingSelectionOnAnotherOverlayClearsTheOldSelection() {
    let first = makeSelectionOverlay()
    let second = makeSelectionOverlay()
    first.selectAllAsDefault()
    second.selectedRect = CGRect(x: 10, y: 10, width: 80, height: 60)

    CaptureCoordinator.activateSelection(on: second, among: [first, second])

    #expect(first.selectedRect == nil)
    #expect(second.selectedRect == CGRect(x: 10, y: 10, width: 80, height: 60))
}

@MainActor
private func makeSelectionOverlay() -> SelectionOverlayView {
    let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    let image = NSImage(size: overlay.bounds.size)
    overlay.setScreenshot(image)
    return overlay
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
private final class SelectionInteractionDelegateSpy: SelectionOverlayDelegate {
    private(set) var commitCount = 0

    func overlayDidCancel() {}

    func overlayDidCommit(image: NSImage) {
        commitCount += 1
    }

    func overlayDidCopyOCRText(on screen: NSScreen?) {}
}

private func selectionMouseEvent(at point: CGPoint, clickCount: Int) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )!
}
