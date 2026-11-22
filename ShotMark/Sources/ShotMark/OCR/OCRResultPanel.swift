import AppKit

@MainActor
final class OCRResultPanel: NSView, NSTextViewDelegate {
    private let pasteboard: any StringPasteboard
    private let scrollView = NSTextView.scrollableTextView()
    private let copySelectionButton = NSButton()
    private let confidenceLabel = NSTextField(labelWithString: "")

    private(set) var canSubmitCopiedText = false
    var onCopySucceeded: (() -> Void)?

    private var textView: NSTextView {
        scrollView.documentView as! NSTextView
    }

    var recognizedText: String {
        get { textView.string }
        set {
            textView.string = newValue
            canSubmitCopiedText = false
            selectedRange = textView.selectedRange()
            updateCopySelectionAvailability()
        }
    }

    var selectedRange: NSRange = NSRange(location: NSNotFound, length: 0) {
        didSet {
            if isValidRange(selectedRange), textView.selectedRange() != selectedRange {
                textView.setSelectedRange(selectedRange)
            }
            updateCopySelectionAvailability()
        }
    }

    var canCopySelection: Bool {
        isValidRange(selectedRange) && selectedRange.length > 0
    }

    init(pasteboard: any StringPasteboard = SystemStringPasteboard()) {
        self.pasteboard = pasteboard
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        configureViews()
    }

    convenience init(result: OCRResult, pasteboard: any StringPasteboard = SystemStringPasteboard()) {
        self.init(pasteboard: pasteboard)
        recognizedText = result.text
        confidenceLabel.stringValue = "平均置信度：\(Int((result.averageConfidence * 100).rounded()))%"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func copyAll() {
        canSubmitCopiedText = pasteboard.write(textView.string)
        if canSubmitCopiedText {
            onCopySucceeded?()
        }
    }

    func copySelection() {
        guard canCopySelection else { return }
        canSubmitCopiedText = pasteboard.write(
            (textView.string as NSString).substring(with: selectedRange)
        )
        if canSubmitCopiedText {
            onCopySucceeded?()
        }
    }

    func textDidChange(_ notification: Notification) {
        canSubmitCopiedText = false
        selectedRange = textView.selectedRange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectedRange = textView.selectedRange()
    }

    private func configureViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        let titleLabel = NSTextField(labelWithString: "OCR 识别结果")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.delegate = self

        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let copyAllButton = NSButton(title: "复制全部", target: self, action: #selector(copyAllFromButton))
        copyAllButton.bezelStyle = .rounded
        copySelectionButton.title = "复制选中"
        copySelectionButton.target = self
        copySelectionButton.action = #selector(copySelectionFromButton)
        copySelectionButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [confidenceLabel, copyAllButton, copySelectionButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas

        let stack = NSStackView(views: [titleLabel, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        updateCopySelectionAvailability()
    }

    private func isValidRange(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0
        else { return false }
        let textLength = (textView.string as NSString).length
        return range.location <= textLength && range.length <= textLength - range.location
    }

    private func updateCopySelectionAvailability() {
        copySelectionButton.isEnabled = canCopySelection
    }

    @objc private func copyAllFromButton() {
        copyAll()
    }

    @objc private func copySelectionFromButton() {
        copySelection()
    }
}
