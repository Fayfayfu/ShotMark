import AppKit

@MainActor
private final class PendingAnnotationTextField: NSTextField {
    var doubleClickHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        doubleClickHandler?()
    }
}

@MainActor
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    enum Tool: Int, CaseIterable {
        case selection
        case rectangle
        case ellipse
        case line
        case arrow
        case brush
        case text
        case mosaic

        var title: String {
            switch self {
            case .selection: "选区"
            case .rectangle: "矩形"
            case .ellipse: "椭圆"
            case .line: "直线"
            case .arrow: "箭头"
            case .brush: "画笔"
            case .text: "文字"
            case .mosaic: "马赛克"
            }
        }

        var isStrokeTool: Bool {
            switch self {
            case .rectangle, .ellipse, .line, .arrow, .brush: true
            case .selection, .text, .mosaic: false
            }
        }
    }

    var commitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var ocrHandler: (() -> Void)?
    var controlSurfaceDidResize: (() -> Void)?
    var selectionModeChanged: ((Bool) -> Void)?

    let annotationControlSurface = NSVisualEffectView()

    private static let gestureDragThreshold: CGFloat = 4

    private var baseImage: NSImage
    private var history = UndoHistory<[Annotation]>([])
    private var activeTool: Tool = .selection
    private var strokeStyles: [Tool: StrokeStyle] = [:]
    private var textStyle = TextStyle(color: .systemRed, pointSize: 18, weight: .regular)
    private var gestureStart: CGPoint?
    private var gestureCurrent: CGPoint?
    private var gestureCrossedDragThreshold = false
    private var brushPoints: [CGPoint] = []
    private weak var pendingTextEditor: PendingAnnotationTextField?
    private var pendingTextPoint: CGPoint?
    private var pendingTextStyle: TextStyle?

    private struct PaletteColor {
        let identifier: String
        let accessibilityLabel: String
        let color: NSColor
    }

    private static let paletteColors: [PaletteColor] = [
        PaletteColor(identifier: "red", accessibilityLabel: "红色", color: .systemRed),
        PaletteColor(identifier: "orange", accessibilityLabel: "橙色", color: .systemOrange),
        PaletteColor(identifier: "yellow", accessibilityLabel: "黄色", color: .systemYellow),
        PaletteColor(identifier: "green", accessibilityLabel: "绿色", color: .systemGreen),
        PaletteColor(identifier: "blue", accessibilityLabel: "蓝色", color: .systemBlue),
        PaletteColor(identifier: "purple", accessibilityLabel: "紫色", color: .systemPurple),
        PaletteColor(
            identifier: "pink",
            accessibilityLabel: "粉色",
            color: NSColor(srgbRed: 1, green: 0.35, blue: 0.64, alpha: 1)
        ),
        PaletteColor(identifier: "black", accessibilityLabel: "黑色", color: .black),
        PaletteColor(identifier: "white", accessibilityLabel: "白色", color: .white)
    ]

    private let colorButton = NSButton()
    private let colorPaletteRow = NSStackView()
    private var colorOptionButtons: [NSButton] = []
    private let widthPicker = NSPopUpButton()
    private let textSizePicker = NSPopUpButton()
    private let boldButton = NSButton(checkboxWithTitle: "粗体", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    private let redoButton = NSButton(title: "重做", target: nil, action: nil)
    private var toolButtons: [Tool: NSButton] = [:]

    init(frame frameRect: NSRect, image: NSImage) {
        baseImage = image
        super.init(frame: frameRect)
        initializeStyles()
        configureControlSurface()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, image: NSImage(size: frameRect.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    var hasPendingTextEditor: Bool { pendingTextEditor != nil }
    var isSelectionToolActive: Bool { activeTool == .selection }

    func setImage(_ image: NSImage) {
        discardPendingText()
        clearGesture()
        baseImage = image
        history = UndoHistory([])
        updateHistoryControls()
        needsDisplay = true
    }

    func updateImagePreservingAnnotations(_ image: NSImage) {
        finalizePendingText()
        clearGesture()
        baseImage = image
        needsDisplay = true
    }

    func translateAnnotations(by offset: CGPoint) {
        guard offset != .zero else { return }
        finalizePendingText()
        history.mapValues { annotations in
            annotations.map { $0.translated(by: offset) }
        }
        updateHistoryControls()
        needsDisplay = true
    }

    func composePNGImage() -> NSImage {
        finalizePendingText()
        return AnnotationRenderer.render(baseImage: baseImage, annotations: history.current)
    }

    func composeImageForOCR() -> NSImage {
        var annotations = history.current
        if let editor = pendingTextEditor,
           let point = pendingTextPoint,
           let style = pendingTextStyle,
           !editor.stringValue.isEmpty {
            annotations.append(.text(editor.stringValue, point, style))
        }
        return AnnotationRenderer.render(baseImage: baseImage, annotations: annotations)
    }

    func undo() {
        finalizePendingText()
        history.undo()
        updateHistoryControls()
        needsDisplay = true
    }

    func redo() {
        finalizePendingText()
        history.redo()
        updateHistoryControls()
        needsDisplay = true
    }

    func requestCommit() {
        finalizePendingText()
        clearGesture()
        commitHandler?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let annotations = currentPreview().map { history.current + [$0] } ?? history.current
        AnnotationRenderer.render(baseImage: baseImage, annotations: annotations).draw(
            in: bounds,
            from: CGRect(origin: .zero, size: baseImage.size),
            operation: .copy,
            fraction: 1
        )
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

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? PendingAnnotationTextField,
              editor === pendingTextEditor
        else { return }
        finalizePendingText()
    }

    private func processPointerDown(at rawPoint: CGPoint, clickCount: Int) {
        let point = constrainedPoint(rawPoint)
        guard bounds.contains(point) else { return }

        guard activeTool != .selection else { return }

        if clickCount == 2 {
            requestCommit()
            return
        }
        guard clickCount == 1 else { return }

        if activeTool == .text {
            beginTextEntry(at: point)
            return
        }

        finalizePendingText()
        gestureStart = point
        gestureCurrent = point
        gestureCrossedDragThreshold = false
        brushPoints = activeTool == .brush ? [point] : []
        needsDisplay = true
    }

    private func processPointerDragged(to rawPoint: CGPoint) {
        guard let start = gestureStart else { return }
        let point = constrainedPoint(rawPoint)
        gestureCurrent = point
        if hypot(point.x - start.x, point.y - start.y) >= Self.gestureDragThreshold {
            gestureCrossedDragThreshold = true
        }
        if activeTool == .brush, gestureCrossedDragThreshold {
            brushPoints.append(point)
        }
        needsDisplay = true
    }

    private func processPointerUp(at rawPoint: CGPoint, clickCount: Int) {
        guard gestureStart != nil else { return }
        guard clickCount < 2 else {
            clearGesture()
            return
        }

        let point = constrainedPoint(rawPoint)
        gestureCurrent = point
        if let start = gestureStart,
           hypot(point.x - start.x, point.y - start.y) >= Self.gestureDragThreshold {
            gestureCrossedDragThreshold = true
        }
        if activeTool == .brush, gestureCrossedDragThreshold, brushPoints.last != point {
            brushPoints.append(point)
        }
        if gestureCrossedDragThreshold, let annotation = currentPreview() {
            history.apply(history.current + [annotation])
            updateHistoryControls()
        }
        clearGesture()
    }

    private func clearGesture() {
        gestureStart = nil
        gestureCurrent = nil
        gestureCrossedDragThreshold = false
        brushPoints.removeAll()
        needsDisplay = true
    }

    private func initializeStyles() {
        for tool in Tool.allCases where tool.isStrokeTool {
            strokeStyles[tool] = StrokeStyle(color: .systemRed, width: 2)
        }
    }

    private func configureControlSurface() {
        annotationControlSurface.material = .hudWindow
        annotationControlSurface.blendingMode = .withinWindow
        annotationControlSurface.state = .active
        annotationControlSurface.wantsLayer = true
        annotationControlSurface.layer?.cornerRadius = 8

        let toolRow = NSStackView()
        toolRow.orientation = .horizontal
        toolRow.spacing = 4
        toolRow.alignment = .centerY
        for tool in Tool.allCases {
            let button = NSButton(title: tool.title, target: self, action: #selector(selectToolFromButton(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.toggle)
            button.tag = tool.rawValue
            toolButtons[tool] = button
            toolRow.addArrangedSubview(button)
        }

        colorButton.identifier = NSUserInterfaceItemIdentifier("color-picker")
        colorButton.title = ""
        colorButton.bezelStyle = .texturedRounded
        colorButton.imagePosition = .imageOnly
        colorButton.target = self
        colorButton.action = #selector(toggleColorPalette)
        colorButton.toolTip = "选择颜色"
        colorButton.setAccessibilityLabel("选择颜色")
        NSLayoutConstraint.activate([
            colorButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            colorButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])

        colorPaletteRow.orientation = .horizontal
        colorPaletteRow.spacing = 4
        colorPaletteRow.alignment = .centerY
        colorPaletteRow.isHidden = true
        for (index, paletteColor) in Self.paletteColors.enumerated() {
            let button = NSButton()
            button.identifier = NSUserInterfaceItemIdentifier("color-option-\(paletteColor.identifier)")
            button.title = ""
            button.tag = index
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(selectPaletteColor(_:))
            button.toolTip = paletteColor.accessibilityLabel
            button.setAccessibilityLabel(paletteColor.accessibilityLabel)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
            ])
            colorOptionButtons.append(button)
            colorPaletteRow.addArrangedSubview(button)
        }

        widthPicker.addItems(withTitles: ["2 px", "4 px", "6 px", "8 px"])
        widthPicker.target = self
        widthPicker.action = #selector(changeWidth(_:))
        widthPicker.toolTip = "线宽"

        textSizePicker.addItems(withTitles: ["14", "18", "24", "32"])
        textSizePicker.selectItem(withTitle: "18")
        textSizePicker.target = self
        textSizePicker.action = #selector(changeTextSize(_:))
        textSizePicker.toolTip = "字号"
        textSizePicker.isHidden = true

        boldButton.target = self
        boldButton.action = #selector(toggleBold(_:))
        boldButton.isHidden = true

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 4
        actionRow.alignment = .centerY
        [colorButton, widthPicker, textSizePicker, boldButton].forEach(actionRow.addArrangedSubview)
        undoButton.target = self
        undoButton.action = #selector(performUndo)
        undoButton.bezelStyle = .texturedRounded
        redoButton.target = self
        redoButton.action = #selector(performRedo)
        redoButton.bezelStyle = .texturedRounded
        actionRow.addArrangedSubview(undoButton)
        actionRow.addArrangedSubview(redoButton)

        actionRow.addArrangedSubview(toolbarButton("OCR", action: #selector(startOCR)))

        let copyButton = toolbarButton("复制图片", action: nil)
        copyButton.isEnabled = false
        copyButton.toolTip = "将在后续任务中接入"
        actionRow.addArrangedSubview(copyButton)
        actionRow.addArrangedSubview(toolbarButton("取消", action: #selector(cancelEditing)))
        actionRow.addArrangedSubview(toolbarButton("完成", action: #selector(commitEditing)))

        let rows = NSStackView(views: [toolRow, actionRow, colorPaletteRow])
        rows.orientation = .vertical
        rows.spacing = 4
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        annotationControlSurface.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: annotationControlSurface.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: annotationControlSurface.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: annotationControlSurface.topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: annotationControlSurface.bottomAnchor, constant: -6)
        ])
        annotationControlSurface.frame.size = paddedControlSurfaceSize(for: rows)
        annotationControlSurface.layoutSubtreeIfNeeded()

        // Detached canvases still expose functional controls. SelectionOverlayView reparents this surface.
        annotationControlSurface.frame.origin = CGPoint(x: 0, y: bounds.maxY + 8)
        addSubview(annotationControlSurface)
        updateToolbarForActiveTool()
        updateHistoryControls()
    }

    private func toolbarButton(_ title: String, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: action == nil ? nil : self, action: action)
        button.bezelStyle = .texturedRounded
        return button
    }

    @objc private func selectToolFromButton(_ sender: NSButton) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        if activeTool == .text, tool != .text {
            finalizePendingText()
        }
        activeTool = tool
        updateToolbarForActiveTool()
        selectionModeChanged?(tool == .selection)
    }

    @objc private func toggleColorPalette() {
        colorPaletteRow.isHidden.toggle()
        updateColorControls()
        resizeControlSurfaceToFit()
    }

    @objc private func selectPaletteColor(_ sender: NSButton) {
        guard Self.paletteColors.indices.contains(sender.tag) else { return }
        let color = Self.paletteColors[sender.tag].color
        if activeTool.isStrokeTool {
            let oldStyle = strokeStyle(for: activeTool)
            strokeStyles[activeTool] = StrokeStyle(color: color, width: oldStyle.width)
        } else if activeTool == .text {
            textStyle = TextStyle(color: color, pointSize: textStyle.pointSize, weight: textStyle.weight)
        }
        colorPaletteRow.isHidden = true
        updateColorControls()
        resizeControlSurfaceToFit()
    }

    @objc private func changeWidth(_ sender: NSPopUpButton) {
        guard activeTool.isStrokeTool,
              let title = sender.selectedItem?.title,
              let width = Double(title.split(separator: " ").first ?? "")
        else { return }
        let oldStyle = strokeStyle(for: activeTool)
        strokeStyles[activeTool] = StrokeStyle(color: oldStyle.color, width: CGFloat(width))
    }

    @objc private func changeTextSize(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, let size = Double(title) else { return }
        textStyle = TextStyle(color: textStyle.color, pointSize: CGFloat(size), weight: textStyle.weight)
    }

    @objc private func toggleBold(_ sender: NSButton) {
        let weight: NSFont.Weight = sender.state == .on ? .bold : .regular
        textStyle = TextStyle(color: textStyle.color, pointSize: textStyle.pointSize, weight: weight)
    }

    @objc private func performUndo() {
        undo()
    }

    @objc private func performRedo() {
        redo()
    }

    @objc private func cancelEditing() {
        cancelHandler?()
    }

    @objc private func startOCR() {
        ocrHandler?()
    }

    @objc private func commitEditing() {
        requestCommit()
    }

    private func updateToolbarForActiveTool() {
        for (tool, button) in toolButtons {
            button.state = tool == activeTool ? .on : .off
        }
        colorButton.isHidden = activeTool == .selection || activeTool == .mosaic
        if colorButton.isHidden {
            colorPaletteRow.isHidden = true
        }
        widthPicker.isHidden = !activeTool.isStrokeTool
        textSizePicker.isHidden = activeTool != .text
        boldButton.isHidden = activeTool != .text
        if activeTool.isStrokeTool {
            let style = strokeStyle(for: activeTool)
            widthPicker.selectItem(withTitle: "\(Int(style.width)) px")
        } else if activeTool == .text {
            textSizePicker.selectItem(withTitle: "\(Int(textStyle.pointSize))")
            boldButton.state = textStyle.weight == .bold ? .on : .off
        }
        updateColorControls()
        resizeControlSurfaceToFit()
    }

    private func updateColorControls() {
        let selectedColor: NSColor
        if activeTool.isStrokeTool {
            selectedColor = strokeStyle(for: activeTool).color
        } else {
            selectedColor = textStyle.color
        }
        colorButton.image = Self.swatchImage(color: selectedColor, selected: false)
        for (index, button) in colorOptionButtons.enumerated() {
            let paletteColor = Self.paletteColors[index].color
            let selected = paletteColor.isEqual(selectedColor)
            button.image = Self.swatchImage(color: paletteColor, selected: selected)
            button.state = selected ? .on : .off
        }
    }

    private func updateHistoryControls() {
        undoButton.isEnabled = history.canUndo
        redoButton.isEnabled = history.canRedo
    }

    private static func swatchImage(color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let outerRect = rect.insetBy(dx: 1, dy: 1)
            let outer = NSBezierPath(ovalIn: outerRect)
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            outer.lineWidth = selected ? 2.5 : 1
            outer.stroke()

            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
    }

    private func resizeControlSurfaceToFit() {
        guard let rows = annotationControlSurface.subviews.first as? NSStackView else { return }
        let oldSize = annotationControlSurface.frame.size
        let newSize = paddedControlSurfaceSize(for: rows)
        annotationControlSurface.frame.size = newSize
        annotationControlSurface.needsLayout = true
        annotationControlSurface.layoutSubtreeIfNeeded()
        if oldSize != newSize {
            controlSurfaceDidResize?()
        }
    }

    private func strokeStyle(for tool: Tool) -> StrokeStyle {
        strokeStyles[tool] ?? StrokeStyle(color: .systemRed, width: 2)
    }

    private func currentPreview() -> Annotation? {
        guard gestureCrossedDragThreshold, let start = gestureStart, let end = gestureCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        switch activeTool {
        case .selection:
            return nil
        case .rectangle:
            return .rectangle(rect, strokeStyle(for: activeTool))
        case .ellipse:
            return .ellipse(rect, strokeStyle(for: activeTool))
        case .line:
            return .line(start, end, strokeStyle(for: activeTool))
        case .arrow:
            return .arrow(start, end, strokeStyle(for: activeTool))
        case .brush:
            return .brush(brushPoints.isEmpty ? [start, end] : brushPoints, strokeStyle(for: activeTool))
        case .mosaic:
            return .mosaic(rect, 12)
        case .text:
            return nil
        }
    }

    private func paddedControlSurfaceSize(for rows: NSStackView) -> NSSize {
        NSSize(width: rows.fittingSize.width + 12, height: rows.fittingSize.height + 12)
    }

    private func beginTextEntry(at point: CGPoint) {
        finalizePendingText()
        let editorWidth = max(1, min(180, bounds.width))
        let editorHeight = max(1, min(textStyle.pointSize + 12, bounds.height))
        let origin = CGPoint(
            x: min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX - editorWidth)),
            y: min(max(point.y, bounds.minY), max(bounds.minY, bounds.maxY - editorHeight))
        )
        let editor = PendingAnnotationTextField(frame: CGRect(origin: origin, size: NSSize(width: editorWidth, height: editorHeight)))
        editor.placeholderString = "输入文字"
        editor.font = .systemFont(ofSize: textStyle.pointSize, weight: textStyle.weight)
        editor.textColor = textStyle.color
        editor.delegate = self
        editor.doubleClickHandler = { [weak self] in self?.requestCommit() }
        pendingTextEditor = editor
        pendingTextPoint = point
        pendingTextStyle = textStyle
        addSubview(editor)
        window?.makeFirstResponder(editor)
    }

    private func finalizePendingText() {
        guard let editor = pendingTextEditor else { return }
        let point = pendingTextPoint
        let style = pendingTextStyle
        let string = editor.stringValue
        pendingTextEditor = nil
        pendingTextPoint = nil
        pendingTextStyle = nil
        editor.delegate = nil
        editor.doubleClickHandler = nil
        editor.removeFromSuperview()

        if let point, let style, !string.isEmpty {
            history.apply(history.current + [.text(string, point, style)])
            updateHistoryControls()
            needsDisplay = true
        }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    private func discardPendingText() {
        guard let editor = pendingTextEditor else { return }
        pendingTextEditor = nil
        pendingTextPoint = nil
        pendingTextStyle = nil
        editor.delegate = nil
        editor.doubleClickHandler = nil
        editor.removeFromSuperview()
    }

    private func constrainedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private extension Annotation {
    func translated(by offset: CGPoint) -> Annotation {
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: value.x + offset.x, y: value.y + offset.y)
        }

        switch self {
        case let .rectangle(rect, style):
            return .rectangle(rect.offsetBy(dx: offset.x, dy: offset.y), style)
        case let .ellipse(rect, style):
            return .ellipse(rect.offsetBy(dx: offset.x, dy: offset.y), style)
        case let .line(start, end, style):
            return .line(point(start), point(end), style)
        case let .arrow(start, end, style):
            return .arrow(point(start), point(end), style)
        case let .brush(points, style):
            return .brush(points.map(point), style)
        case let .text(text, origin, style):
            return .text(text, point(origin), style)
        case let .mosaic(rect, blockSize):
            return .mosaic(rect.offsetBy(dx: offset.x, dy: offset.y), blockSize)
        }
    }
}
