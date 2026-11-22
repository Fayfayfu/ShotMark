import AppKit

@MainActor
final class CopyConfirmationHUD {
    static let shared = CopyConfirmationHUD()

    private var panel: NSPanel?
    private var dismissalTask: Task<Void, Never>?

    func show(on requestedScreen: NSScreen?) {
        dismissalTask?.cancel()
        panel?.orderOut(nil)

        guard let screen = requestedScreen ?? screenContainingMouse() ?? NSScreen.main else { return }
        let panel = makePanel()
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 48
        ))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1
        }

        dismissalTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }

            await NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            })

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, self.panel === panel else { return }
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 82, height: 34)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "已复制")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
        return panel
    }

    private func screenContainingMouse() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}
