import AppKit
import ApplicationServices
import QuartzCore

enum ScreenshotTransitions {
    static let hideDuration: CFTimeInterval = 1.7
    private static let closeDuration: CFTimeInterval = 0.45
    private static var activeOverlays: Set<NSWindow> = []

    static func trackOverlay(_ window: NSWindow) {
        activeOverlays.insert(window)
    }

    static func finishOverlay(_ window: NSWindow) {
        window.orderOut(nil)
        activeOverlays.remove(window)
    }

    static func hideOverlays() {
        activeOverlays.forEach { $0.orderOut(nil) }
        activeOverlays.removeAll()
    }

    static func shrink(_ window: NSWindow, completion: @escaping () -> Void) {
        animate(window, completion: completion) { image, frame, _, canvas in
            let layer = CALayer()
            layer.frame = frame
            layer.contents = image
            layer.opacity = 0
            canvas.addSublayer(layer)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 0.04
            scale.duration = closeDuration
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.62, 1]
            fade.duration = closeDuration
            let animation = CAAnimationGroup()
            animation.animations = [scale, fade]
            animation.duration = closeDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.25, 1)
            layer.add(animation, forKey: "close")
        }
    }

    static func sendToTrash(_ window: NSWindow, completion: @escaping () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let target = trashTarget() else {
            shrink(window, completion: completion)
            return
        }
        let duration: CFTimeInterval = 0.68
        animate(window, toward: target.point, completion: completion) { image, frame, destination, canvas in
            guard let destination else { return }
            let count = 24
            let length = target.vertical ? image.height : image.width
            for index in 0..<count {
                let start = index * length / count
                let end = (index + 1) * length / count
                let slice = target.vertical
                    ? CGRect(x: 0, y: start, width: image.width, height: end - start)
                    : CGRect(x: start, y: 0, width: end - start, height: image.height)
                guard let piece = image.cropping(to: slice) else { continue }
                let lower = CGFloat(start) / CGFloat(length)
                let upper = CGFloat(end) / CGFloat(length)
                let original = target.vertical
                    ? CGRect(x: frame.minX, y: frame.maxY - upper * frame.height,
                             width: frame.width, height: (upper - lower) * frame.height)
                    : CGRect(x: frame.minX + lower * frame.width, y: frame.minY,
                             width: (upper - lower) * frame.width, height: frame.height)
                let layer = CALayer()
                layer.contents = piece
                layer.frame = original
                layer.opacity = 0
                canvas.addSublayer(layer)

                let positions = CAKeyframeAnimation(keyPath: "position")
                let scales = CAKeyframeAnimation(keyPath: "transform")
                var points: [NSValue] = []
                var transforms: [NSValue] = []
                let reverse = target.vertical ? destination.y < frame.midY : destination.x > frame.midX
                for sample in 0...36 {
                    let t = CGFloat(sample) / 36
                    func progress(_ edge: CGFloat) -> CGFloat {
                        let delay = (reverse ? 1 - edge : edge) * 0.32
                        let p = min(1, max(0, (t - delay) / (1 - delay)))
                        return p * p * (3 - 2 * p)
                    }
                    let p1 = progress(lower), p2 = progress(upper)
                    let p = (p1 + p2) / 2
                    let initialA = target.vertical ? original.maxY : original.minX
                    let initialB = target.vertical ? original.minY : original.maxX
                    let targetAxis = target.vertical ? destination.y : destination.x
                    let a = initialA + (targetAxis - initialA) * p1
                    let b = initialB + (targetAxis - initialB) * p2
                    let initialCross = target.vertical ? original.midX : original.midY
                    let targetCross = target.vertical ? destination.x : destination.y
                    let cross = initialCross + (targetCross - initialCross) * p
                    let axialScale = max(0.01, (abs(a - b) + 0.4) / (target.vertical ? original.height : original.width))
                    let taper = max(0.015, (1 - p) * (1 - p))
                    let axis = (a + b) / 2
                    points.append(NSValue(point: target.vertical ? CGPoint(x: cross, y: axis) : CGPoint(x: axis, y: cross)))
                    transforms.append(NSValue(caTransform3D: CATransform3DMakeScale(
                        target.vertical ? taper : axialScale,
                        target.vertical ? axialScale : taper, 1)))
                }
                positions.values = points
                scales.values = transforms
                positions.duration = duration
                scales.duration = duration
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 1, 0]
                fade.keyTimes = [0, 0.8, 1]
                fade.duration = duration
                let animation = CAAnimationGroup()
                animation.animations = [positions, scales, fade]
                animation.duration = duration
                layer.add(animation, forKey: "trash")
            }
        }
    }

    private static func animate(_ window: NSWindow, toward point: CGPoint? = nil,
                                completion: @escaping () -> Void,
                                draw: (CGImage, CGRect, CGPoint?, CALayer) -> Void) {
        guard window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            window.orderOut(nil)
            completion()
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else {
            window.orderOut(nil)
            completion()
            return
        }
        let original = window.frame
        let bounds = point.map { original.union(CGRect(x: $0.x - 8, y: $0.y - 8, width: 16, height: 16)) }
            ?? original
        let overlay = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.sharingType = .readOnly
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let canvas = NSView(frame: CGRect(origin: .zero, size: bounds.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        guard let layer = canvas.layer else {
            window.orderOut(nil)
            completion()
            return
        }
        trackOverlay(overlay)
        overlay.orderFrontRegardless()
        window.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            finishOverlay(overlay)
            completion()
        }
        draw(image, original.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
             point.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }, layer)
        CATransaction.commit()
    }

    private static func trashTarget() -> (point: CGPoint, vertical: Bool)? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let primary = NSScreen.screens.first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for list in children where attribute(list, kAXRoleAttribute) as? String == kAXListRole {
            let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? []
            // The Trash is the last Dock item; the subrole is independent of the system language.
            guard let item = items.last,
                  attribute(item, kAXSubroleAttribute) as? String == "AXTrashDockItem",
                  let value = attribute(item, kAXPositionAttribute),
                  CFGetTypeID(value) == AXValueGetTypeID(),
                  let sizeValue = attribute(item, kAXSizeAttribute),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(value as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  size.width > 0, size.height > 0 else { continue }
            let point = CGPoint(x: position.x + size.width / 2,
                                y: primary.frame.maxY - position.y - size.height / 2)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { continue }
            let sideDistance = min(point.x - screen.frame.minX, screen.frame.maxX - point.x)
            return (point, point.y - screen.frame.minY <= sideDistance)
        }
        return nil
    }
}
