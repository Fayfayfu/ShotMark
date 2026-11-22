import Testing
@testable import ShotMark

@Test
func undoAndRedoRestoreArraySnapshotsAndStopAtHistoryLimits() {
    let history = UndoHistory([1])

    history.apply([1, 2])
    history.apply([1, 2, 3])
    #expect(history.current == [1, 2, 3])

    history.undo()
    #expect(history.current == [1, 2])
    history.undo()
    #expect(history.current == [1])
    history.undo()
    #expect(history.current == [1])

    history.redo()
    #expect(history.current == [1, 2])
    history.redo()
    #expect(history.current == [1, 2, 3])
    history.redo()
    #expect(history.current == [1, 2, 3])
}

@Test
func applyingAfterUndoDiscardsTheRedoSnapshot() {
    let history = UndoHistory([1])

    history.apply([1, 2])
    history.apply([1, 2, 3])
    history.undo()
    history.apply([1, 2, 4])
    history.redo()

    #expect(history.current == [1, 2, 4])
}
