import AppKit

private final class ComparisonScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {}
}

private final class ComparisonImageView: NSImageView {
    var onSelect: (() -> Void)?
    var onPan: ((NSPoint) -> Void)?
    private var lastPoint: NSPoint?
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        lastPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let lastPoint else { return }
        let point = event.locationInWindow
        onPan?(NSPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
        self.lastPoint = point
    }
    override func mouseUp(with event: NSEvent) {
        if lastPoint != nil { NSCursor.pop() }
        lastPoint = nil
    }
}

final class Comparison: NSObject {
    static let shared = Comparison()
    private var window: NSWindow?
    private var panes: [NSScrollView] = []
    private var selected = 0
    private var together = true
    private var toggle: NSButton?
    private var labels: [NSTextField] = []
    private var fitted: [CGFloat] = []
    private var displayedURLs: [URL] = []

    func show(_ urls: [URL]) {
        guard urls.count == 2 else { return }
        if displayedURLs == urls, let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        let images = urls.compactMap { NSImage(contentsOf: $0) }
        guard images.count == 2 else { NSSound.beep(); return }
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 570),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if self.window == nil { window.center() }
        self.window = window
        window.isReleasedWhenClosed = false
        window.title = "截图对照"
        selected = 0
        displayedURLs = urls
        labels = []
        fitted = []
        let root = NSView()
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        let toggle = NSButton(checkboxWithTitle: "同时调整", target: self, action: #selector(toggleTogether(_:)))
        toggle.state = together ? .on : .off
        self.toggle = toggle
        controls.addArrangedSubview(toggle)
        for (title, action) in [("放大", #selector(larger)), ("缩小", #selector(smaller)), ("复位", #selector(reset))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            controls.addArrangedSubview(button)
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        panes = images.enumerated().map { index, image in
            let scroll = ComparisonScrollView()
            scroll.drawsBackground = true
            scroll.backgroundColor = .controlBackgroundColor
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.02
            scroll.maxMagnification = 8
            let view = ComparisonImageView(frame: NSRect(origin: .zero, size: image.size))
            view.image = image
            view.onSelect = { [weak self] in self?.selected = index; self?.updateSelection() }
            view.onPan = { [weak self] delta in self?.pan(delta, source: index) }
            scroll.documentView = view
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 8
            scroll.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "100%")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            labels.append(label)
            let column = NSStackView(views: [scroll, label])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 5
            row.addArrangedSubview(column)
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            return scroll
        }
        root.addSubview(controls)
        root.addSubview(row)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            row.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()
        resetAll()
        updateSelection()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var targets: [NSScrollView] { together ? panes : Array(panes.dropFirst(selected).prefix(1)) }
    private func updateSelection() {
        for (index, pane) in panes.enumerated() {
            pane.layer?.borderWidth = !together && index == selected ? 2 : 0
            pane.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
    private func pan(_ delta: NSPoint, source: Int) {
        for pane in (together ? panes : [panes[source]]) {
            let clip = pane.contentView
            let scale = max(pane.magnification, 0.02)
            let point = NSPoint(x: clip.bounds.origin.x - delta.x / scale, y: clip.bounds.origin.y - delta.y / scale)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
            pane.reflectScrolledClipView(clip)
        }
    }
    private func fit(_ pane: NSScrollView) {
        guard let size = pane.documentView?.frame.size else { return }
        let zoom = min(1, pane.contentSize.width / max(1, size.width), pane.contentSize.height / max(1, size.height))
        pane.minMagnification = max(0.02, zoom)
        pane.magnification = pane.minMagnification
        if let index = panes.firstIndex(of: pane) {
            while fitted.count <= index { fitted.append(1) }
            fitted[index] = pane.minMagnification
        }
        pane.contentView.scroll(to: .zero)
        pane.reflectScrolledClipView(pane.contentView)
    }
    private func updatePercent() {
        for (index, pane) in panes.enumerated() where index < labels.count && index < fitted.count {
            labels[index].stringValue = "\(Int((pane.magnification / fitted[index] * 100).rounded()))%"
        }
    }
    private func resetAll() { panes.forEach(fit); updatePercent() }
    private func zoom(_ factor: CGFloat) {
        for pane in targets { pane.magnification = min(pane.maxMagnification, max(pane.minMagnification, pane.magnification * factor)) }
        updatePercent()
    }
    @objc private func toggleTogether(_ sender: NSButton) { together = sender.state == .on; updateSelection() }
    @objc private func larger() { zoom(1.25) }
    @objc private func smaller() { zoom(0.8) }
    @objc private func reset() { targets.forEach(fit); updatePercent() }
}
