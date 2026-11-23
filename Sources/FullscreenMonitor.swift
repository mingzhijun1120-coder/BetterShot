import AppKit
import CoreGraphics

/// Observe visible full-display windows, including browser video full screen.
/// Window bounds and level are available without Screen Recording access.
final class FullscreenMonitor {
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isFullscreen = false
    private var exitCandidate: TimeInterval?
    private var generation = 0
    private var scanInFlight = false
    private let scanQueue = DispatchQueue(label: "app.shotpin.fullscreen", qos: .userInitiated)
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
            }
            // Some video players replace their window without changing Spaces.
            let timer = Timer(timeInterval: 0.13, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 0.03
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            observers.removeAll()
            generation += 1
            scanInFlight = false
            exitCandidate = nil
            update(false)
        }
    }

    private func refresh() {
        guard timer != nil, !scanInFlight else { return }
        let displays = NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        let generation = self.generation
        scanInFlight = true
        scanQueue.async { [weak self] in
            let windows = Self.visibleWindowBounds()
            let fullscreen = windows.map { Self.coversDisplay(windows: $0, displays: displays) }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.scanInFlight = false
                if let fullscreen { self.applyReading(fullscreen) }
            }
        }
    }

    private static func visibleWindowBounds() -> [CGRect]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
    }

    private func applyReading(_ fullscreen: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if fullscreen {
            exitCandidate = nil
            update(true)
        } else if isFullscreen {
            if let exitCandidate {
                if now - exitCandidate >= 0.10 {
                    self.exitCandidate = nil
                    update(false)
                }
            } else {
                exitCandidate = now
            }
        }
    }

    static func coversDisplay(windows: [CGRect], displays: [CGRect]) -> Bool {
        displays.contains { display in
            guard let frontWindow = windows.first(where: { window in
                let overlap = window.intersection(display)
                return !overlap.isNull && overlap.width * overlap.height >= display.width * display.height * 0.25
            }) else { return false }
            // Compare against the full display, not the maximized work area.
            let tolerance: CGFloat = 3
            return abs(frontWindow.minX - display.minX) <= tolerance
                && abs(frontWindow.minY - display.minY) <= tolerance
                && abs(frontWindow.maxX - display.maxX) <= tolerance
                && abs(frontWindow.maxY - display.maxY) <= tolerance
        }
    }

    private func update(_ fullscreen: Bool) {
        guard fullscreen != isFullscreen else { return }
        isFullscreen = fullscreen
        onChange(fullscreen)
    }
}
