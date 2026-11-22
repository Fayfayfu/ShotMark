final class UndoHistory<Value> {
    private var past: [Value] = []
    private var future: [Value] = []

    private(set) var current: Value

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(_ initialValue: Value) {
        current = initialValue
    }

    func apply(_ value: Value) {
        past.append(current)
        current = value
        future.removeAll()
    }

    func undo() {
        guard let previous = past.popLast() else { return }

        future.append(current)
        current = previous
    }

    func redo() {
        guard let next = future.popLast() else { return }

        past.append(current)
        current = next
    }

    func mapValues(_ transform: (Value) -> Value) {
        past = past.map(transform)
        current = transform(current)
        future = future.map(transform)
    }
}
