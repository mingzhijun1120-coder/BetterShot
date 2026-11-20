import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 标注模型

enum AnnotationTool: Int, CaseIterable {
    case rectangle, ellipse, line, arrow, pen, text, mosaic, strokeEraser, areaEraser, redact

    var symbolName: String {
        switch self {
        case .redact: return "rectangle.fill"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        case .strokeEraser: return "eraser"
        case .areaEraser: return "eraser.fill"
        }
    }

    var label: String {
        switch self {
        case .redact: return "纯色遮挡"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .strokeEraser: return "笔画橡皮（点一下删掉整笔）"
        case .areaEraser: return "直接橡皮（擦掉擦过的部分）"
        }
    }
}

/// A single mark drawn over the screenshot. Every coordinate and width is stored
/// in image pixels, so baking is the same drawing pass again at scale 1.
final class Annotation {
    let tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var textSize: CGFloat = 20
    var textScale: CGFloat = 1

    private func makeTextLayout() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: Self.textAttributes(size: textSize, color: color))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: Self.textContainerSize)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    static let textContainerSize = NSSize(width: 1_000_000, height: 1_000_000)
    private var mosaicCache: CGImage?
    private var mosaicCacheRect: CGRect = .null

    init(tool: AnnotationTool, start: CGPoint, color: NSColor, lineWidth: CGFloat) {
        self.tool = tool
        self.points = [start]
        self.color = color
        self.lineWidth = lineWidth
    }

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: 绘制

    func draw(base: CGImage, reuseMosaic: Bool = false) {
        switch tool {
        case .redact:
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
        case .rectangle:
            stroke(NSBezierPath(rect: rect))
        case .ellipse:
            stroke(NSBezierPath(ovalIn: rect))
        case .line, .arrow:
            guard points.count >= 2, let first = points.first, let last = points.last else { return }
            let path = NSBezierPath()
            path.move(to: first)
            path.line(to: last)
            stroke(path)
            if tool == .arrow { strokeArrowHead(from: first, to: last) }
        case .pen:
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            stroke(path)
        case .text:
            guard !text.isEmpty, let origin = points.first,
                  let graphics = NSGraphicsContext.current else { return }
            let (storage, layout, container) = makeTextLayout()
            let context = graphics.cgContext
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            // TextKit measures from the top left. Use the editor's point size
            // before scaling to image pixels so line metrics stay the same.
            context.scaleBy(x: 1 / textScale, y: -1 / textScale)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            withExtendedLifetime(storage) {
                layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
            }
            NSGraphicsContext.current = graphics
            context.restoreGState()
        case .mosaic:
            guard let image = (reuseMosaic ? mosaicCache : mosaicImage(base: base)),
                  let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            context.restoreGState()
        case .areaEraser:
            // Erases only the annotation layer under the stroke, so the
            // screenshot itself stays intact.
            guard points.count >= 2,
                  let context = NSGraphicsContext.current?.cgContext else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            context.saveGState()
            context.setBlendMode(.destinationOut)
            NSColor.black.setStroke()
            path.stroke()
            context.restoreGState()
        case .strokeEraser:
            return
        }
    }

    static func textAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = max(1, size * 0.12)
        return [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    func dragHits(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .rectangle, .ellipse, .mosaic, .redact: return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text: return hits(point, tolerance: tolerance)
        case .line, .arrow: return distanceToPolyline(point) <= max(8, lineWidth)
        case .pen, .strokeEraser, .areaEraser: return false
        }
    }

    func copyForDrag() -> Annotation {
        let copy = Annotation(tool: tool, start: points[0], color: color, lineWidth: lineWidth)
        copy.points = points
        copy.text = text
        copy.textSize = textSize
        copy.textScale = textScale
        copy.mosaicCache = mosaicCache
        copy.mosaicCacheRect = mosaicCacheRect
        return copy
    }

    // MARK: 命中测试（笔画橡皮用）

    func hits(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .strokeEraser:
            return false
        case .areaEraser, .line, .arrow, .pen:
            return distanceToPolyline(point) <= max(tolerance, lineWidth / 2)
        case .text:
            guard let origin = points.first else { return false }
            let (storage, layout, container) = makeTextLayout()
            let local = CGPoint(x: (point.x - origin.x) * textScale,
                                y: (origin.y - point.y) * textScale)
            return withExtendedLifetime(storage) {
                var hit = false
                let pad = tolerance * textScale
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) {
                    _, used, _, _, stop in
                    if !used.isEmpty && used.insetBy(dx: -pad, dy: -pad).contains(local) {
                        hit = true
                        stop.pointee = true
                    }
                }
                return hit
            }
        case .mosaic, .redact:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle:
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(point) && !inner.contains(point)
        case .ellipse:
            let box = rect
            guard box.width > 1, box.height > 1 else {
                return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
            let radiusX = box.width / 2
            let radiusY = box.height / 2
            let normalizedX = (point.x - box.midX) / radiusX
            let normalizedY = (point.y - box.midY) / radiusY
            let radial = sqrt(normalizedX * normalizedX + normalizedY * normalizedY)
            return abs(radial - 1) * min(radiusX, radiusY) <= tolerance
        }
    }

    private func distanceToPolyline(_ point: CGPoint) -> CGFloat {
        guard points.count >= 2 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            best = min(best, Annotation.distance(from: point,
                                                 toSegment: points[index - 1],
                                                 points[index]))
        }
        return best
    }

    private static func distance(from point: CGPoint,
                                 toSegment start: CGPoint,
                                 _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        var t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private func stroke(_ path: NSBezierPath) {
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func strokeArrowHead(from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(lineWidth * 3.5, 10)
        let spread = CGFloat.pi / 7
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - length * cos(angle - spread),
                              y: end.y - length * sin(angle - spread)))
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - length * cos(angle + spread),
                              y: end.y - length * sin(angle + spread)))
        stroke(path)
    }

    /// The pixels underneath are averaged into blocks. `CGImage.cropping(to:)`
    /// counts rows from the top while this canvas counts them from the bottom,
    /// so the crop rect is flipped before sampling.
    func mosaicImage(base: CGImage) -> CGImage? {
        let key = rect.integral
        if let mosaicCache, mosaicCacheRect == key { return mosaicCache }
        let bounds = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: base.width, height: base.height)
        )
        guard bounds.width >= 2, bounds.height >= 2 else { return nil }
        let cropRect = CGRect(x: bounds.minX,
                              y: CGFloat(base.height) - bounds.maxY,
                              width: bounds.width,
                              height: bounds.height)
        guard let crop = base.cropping(to: cropRect) else { return nil }
        let shortSide = min(bounds.width, bounds.height)
        let block = min(40, max(8, shortSide / 24))
        let smallWidth = max(1, Int((bounds.width / block).rounded()))
        let smallHeight = max(1, Int((bounds.height / block).rounded()))
        guard let small = Annotation.rasterize(crop, width: smallWidth, height: smallHeight),
              let large = Annotation.rasterize(small,
                                               width: max(1, Int(bounds.width.rounded())),
                                               height: max(1, Int(bounds.height.rounded()))) else {
            return nil
        }
        mosaicCache = large
        mosaicCacheRect = key
        return large
    }

    private static func rasterize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - 画布

protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidChange()
    func canvasDidCommit()
    func canvasDidCancel()
}

final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let url: URL
    let baseImage: CGImage
    let displayScale: CGFloat
    let displaySize: NSSize

    var annotations: [Annotation] = []
    var isEditingText: Bool { textView != nil }
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var current: Annotation?
    private var textView: NSTextView?
    private var textOrigin: CGPoint = .zero
    private var editingAnnotation: Annotation?
    private var layerCache: CGImage?
    private var isErasing = false
    private var dragTimer: Timer?
    private var pendingDrag: (index: Int, point: CGPoint)?
    private var activeDrag: (index: Int, origin: CGPoint, points: [CGPoint], bounds: CGRect, recorded: Bool)?

    var tool: AnnotationTool = .rectangle
    var color: NSColor = .systemRed
    var lineWidthPoints: CGFloat = 4

    weak var delegate: AnnotationCanvasDelegate?

    init(url: URL, baseImage: CGImage, displayScale: CGFloat) {
        self.url = url
        self.baseImage = baseImage
        self.displayScale = displayScale
        self.displaySize = NSSize(width: (CGFloat(baseImage.width) * displayScale).rounded(),
                                  height: (CGFloat(baseImage.height) * displayScale).rounded())
        super.init(frame: NSRect(origin: .zero, size: displaySize))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var pixelLineWidth: CGFloat {
        max(1, (lineWidthPoints / displayScale).rounded())
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(origin: .zero, size: displaySize))
        context.restoreGState()

        if let layer = displayLayer() {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(layer, in: CGRect(origin: .zero, size: displaySize))
            context.restoreGState()
        }
    }

    /// Marks live on their own transparent layer so the direct eraser can cut
    /// holes in them, and so the screenshot underneath is never touched before
    /// 完成 writes the result back.
    private func renderLayer(width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        for (index, annotation) in annotations.enumerated() where annotation !== editingAnnotation {
            annotation.draw(base: baseImage, reuseMosaic: activeDrag?.index == index && annotation.tool == .mosaic)
        }
        if let current, current.tool == .mosaic {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: current.rect).fill()
        } else {
            current?.draw(base: baseImage)
        }
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    private func displayLayer() -> CGImage? {
        guard current == nil else { return renderDisplayLayer() }
        if let layerCache { return layerCache }
        let layer = renderDisplayLayer()
        layerCache = layer
        return layer
    }

    private func renderDisplayLayer() -> CGImage? {
        let factor = window?.backingScaleFactor ?? 2
        return renderLayer(width: Int((displaySize.width * factor).rounded()),
                           height: Int((displaySize.height * factor).rounded()),
                           scale: displayScale * factor)
    }

    func invalidateLayer() {
        layerCache = nil
        needsDisplay = true
    }

    /// Combine the original pixels and every mark into a new full-resolution
    /// image. The pinned file is then replaced in place, so the pin — and any
    /// drag out of it — keeps working on the annotated version.
    func renderFinalImage() -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else { return nil }
        var space = CGColorSpaceCreateDeviceRGB()
        if let original = baseImage.colorSpace, original.model == .rgb { space = original }
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let layer = renderLayer(width: width, height: height, scale: 1) {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(layer, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }
        return context.makeImage()
    }

    // MARK: 鼠标

    private func pixelPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x / displayScale, 0), CGFloat(baseImage.width)),
                       y: min(max(point.y / displayScale, 0), CGFloat(baseImage.height)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextIfNeeded()
        let point = pixelPoint(for: event)
        if tool != .pen && tool != .strokeEraser && tool != .areaEraser && event.clickCount == 1,
           let index = annotations.lastIndex(where: { $0.dragHits(point, tolerance: 4 / displayScale) }) {
            pendingDrag = (index, point)
            let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                guard let self, let pending = self.pendingDrag, pending.index < self.annotations.count else { return }
                let old = self.annotations[pending.index]
                self.pendingDrag = nil
                self.dragTimer = nil
                let box = old.tool == .text ? CGRect(x: old.points[0].x, y: old.points[0].y - old.textSize / old.textScale, width: max(1, old.textSize / old.textScale), height: max(1, old.textSize / old.textScale)) : old.rect
                self.activeDrag = (pending.index, pending.point, old.points, box, false)
                NSCursor.closedHand.push()
            }
            dragTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        beginDrawing(at: point, clickCount: event.clickCount)
    }

    private func beginDrawing(at point: CGPoint, clickCount: Int) {
        if tool != .strokeEraser, tool != .areaEraser,
           let text = annotations.last(where: { $0.tool == .text && $0.hits(point, tolerance: 4 / displayScale) }),
           let origin = text.points.first {
            if clickCount == 2 {
                beginText(at: origin, editing: text)
                return
            }
            // Leave the first click on existing text for the double click.
            if tool == .text { return }
        }
        switch tool {
        case .text:
            beginText(at: point)
            return
        case .strokeEraser:
            isErasing = true
            eraseStroke(at: point)
            return
        case .areaEraser:
            current = Annotation(tool: .areaEraser,
                                 start: point,
                                 color: color,
                                 lineWidth: max(12, pixelLineWidth * 3))
        default:
            current = Annotation(tool: tool,
                                 start: point,
                                 color: color,
                                 lineWidth: pixelLineWidth)
        }
        invalidateLayer()
    }

    override func mouseDragged(with event: NSEvent) {
        if let drag = activeDrag, drag.index < annotations.count {
            let position = convert(event.locationInWindow, from: nil)
            var dx = position.x / displayScale - drag.origin.x
            var dy = position.y / displayScale - drag.origin.y
            let visible = 4 / displayScale
            dx = min(max(dx, -drag.bounds.maxX + visible), CGFloat(baseImage.width) - drag.bounds.minX - visible)
            dy = min(max(dy, -drag.bounds.maxY + visible), CGFloat(baseImage.height) - drag.bounds.minY - visible)
            if !drag.recorded && (dx != 0 || dy != 0) {
                recordChange()
                annotations[drag.index] = annotations[drag.index].copyForDrag()
                activeDrag?.recorded = true
            }
            annotations[drag.index].points = drag.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            invalidateLayer()
            return
        }
        if let pending = pendingDrag {
            let p = convert(event.locationInWindow, from: nil)
            if hypot(p.x - pending.point.x * displayScale, p.y - pending.point.y * displayScale) <= 4 { return }
            dragTimer?.invalidate(); dragTimer = nil; pendingDrag = nil
            beginDrawing(at: pending.point, clickCount: 1)
        }
        if isErasing {
            eraseStroke(at: pixelPoint(for: event))
            return
        }
        guard let annotation = current else { return }
        let point = pixelPoint(for: event)
        if annotation.tool == .pen || annotation.tool == .areaEraser {
            annotation.points.append(point)
        } else {
            annotation.points = [annotation.points[0], point]
        }
        invalidateLayer()
    }

    override func mouseUp(with event: NSEvent) {
        if activeDrag != nil {
            activeDrag = nil
            NSCursor.pop()
            invalidateLayer()
            delegate?.canvasDidChange()
            return
        }
        if let pending = pendingDrag {
            dragTimer?.invalidate(); dragTimer = nil; pendingDrag = nil
            beginDrawing(at: pending.point, clickCount: 1)
        }
        if isErasing {
            isErasing = false
            return
        }
        guard let annotation = current else { return }
        current = nil
        if annotation.tool != .pen && annotation.tool != .areaEraser {
            annotation.points = [annotation.points[0], pixelPoint(for: event)]
        }
        let bounds = annotation.rect
        let freehand = annotation.tool == .pen || annotation.tool == .areaEraser
        let degenerate = freehand
            ? annotation.points.count < 2
            : (bounds.width < 2 && bounds.height < 2)
        invalidateLayer()
        guard !degenerate else { return }
        push(annotation)
    }

    /// 笔画橡皮: the topmost mark under the pointer disappears whole.
    private func eraseStroke(at point: CGPoint) {
        let tolerance = max(8, 6 / displayScale)
        guard let victim = annotations.last(where: { $0.hits(point, tolerance: tolerance) }) else {
            return
        }
        recordChange()
        annotations.removeAll { $0 === victim }
        invalidateLayer()
        delegate?.canvasDidChange()
    }

    private func recordChange() {
        undoStack.append(annotations)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func push(_ annotation: Annotation) {
        recordChange()
        annotations.append(annotation)
        invalidateLayer()
        delegate?.canvasDidChange()
    }

    // MARK: 文字

    private func beginText(at point: CGPoint, editing annotation: Annotation? = nil) {
        let size = annotation.map { $0.textSize * displayScale / $0.textScale } ?? max(13, lineWidthPoints * 3)
        let originX = point.x * displayScale
        let lineHeight = ceil(NSFont.systemFont(ofSize: size, weight: .semibold).boundingRectForFont.height)
        textOrigin = point
        editingAnnotation = annotation

        let view = NSTextView(frame: NSRect(x: originX,
                                            y: point.y * displayScale - lineHeight,
                                            width: 120,
                                            height: lineHeight + 4))
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = Annotation.textContainerSize
        view.font = .systemFont(ofSize: size, weight: .semibold)
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes = Annotation.textAttributes(size: size, color: color)
        if let annotation {
            view.textColor = annotation.color
            view.insertionPointColor = annotation.color
            view.typingAttributes = Annotation.textAttributes(size: size, color: annotation.color)
            view.textStorage?.setAttributedString(
                NSAttributedString(string: annotation.text,
                                   attributes: Annotation.textAttributes(size: size, color: annotation.color)))
        }
        view.delegate = self
        addSubview(view)
        textView = view
        resizeTextEditor(view)
        if annotation != nil { invalidateLayer() }
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        window?.makeFirstResponder(view)
    }

    func commitTextIfNeeded() {
        commitTextView()
    }

    private func commitTextView() {
        guard let view = textView else { return }
        textView = nil
        let string = view.string
        let viewColor = view.textColor ?? color
        let pointSize = view.font?.pointSize ?? 20
        let previousAnnotation = editingAnnotation
        editingAnnotation = nil
        view.delegate = nil
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateLayer()
            return
        }
        let annotation = Annotation(tool: .text,
                                    start: textOrigin,
                                    color: viewColor,
                                    lineWidth: previousAnnotation?.lineWidth ?? pixelLineWidth)
        annotation.text = string
        annotation.textSize = pointSize
        annotation.textScale = displayScale
        if let previousAnnotation,
           let index = annotations.firstIndex(where: { $0 === previousAnnotation }) {
            invalidateLayer()
            guard string != previousAnnotation.text else { return }
            recordChange()
            annotations[index] = annotation
            delegate?.canvasDidChange()
        } else {
            push(annotation)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = textView, notification.object as? NSTextView === view else { return }
        resizeTextEditor(view)
    }

    private func resizeTextEditor(_ view: NSTextView) {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let lineHeight = ceil(view.font?.boundingRectForFont.height ?? 18)
        let width = max(24, ceil(used.width) + 8)
        let height = ceil(max(lineHeight, used.maxY, layoutManager.extraLineFragmentRect.maxY)) + 4
        view.frame = NSRect(x: textOrigin.x * displayScale,
                            y: textOrigin.y * displayScale - height,
                            width: width,
                            height: height)
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextView()
    }

    // MARK: 撤销

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        invalidateLayer()
        delegate?.canvasDidChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        invalidateLayer()
        delegate?.canvasDidChange()
    }

    // MARK: 键盘

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        case "s":
            delegate?.canvasDidCommit()
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            delegate?.canvasDidCancel()
        case 51, 117:
            undo()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - 写回原图

private enum ImageWriter {
    static func write(_ image: CGImage, to url: URL) throws {
        let extensionName = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: extensionName) else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".shotpin-\(UUID().uuidString)")
            .appendingPathExtension(extensionName)

        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let value = original[key] { properties[key] = value }
            }
        }
        if type.conforms(to: .jpeg) {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }

        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                type.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? Foundation.FileManager().removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            // An atomic write publishes the new bytes at the original path, so
            // the pin's file reference and future drags keep pointing at the
            // annotated screenshot instead of a stale inode.
            try data.write(to: url, options: .atomic)
            try? Foundation.FileManager().removeItem(at: temporary)
        } catch {
            try? Foundation.FileManager().removeItem(at: temporary)
            throw error
        }
    }
}

// MARK: - 标注窗口

final class AnnotationController: NSObject, AnnotationCanvasDelegate, NSWindowDelegate {
    static let shared = AnnotationController()

    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var colorButtons: [NSButton] = []
    private var targetURL: URL?
    private static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemMint, .systemCyan, .systemBlue, .systemIndigo,
        .systemPurple, .systemPink, .black, .white
    ]

    func present(url: URL) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            presentUnsupportedAlert()
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            presentUnsupportedAlert()
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let toolbarHeight: CGFloat = 48
        let maxWidth = visible.width * 0.78
        let maxHeight = visible.height * 0.78 - toolbarHeight
        let scale = min(1,
                        maxWidth / CGFloat(image.width),
                        maxHeight / CGFloat(image.height))
        guard scale > 0 else { return }

        let canvas = AnnotationCanvasView(url: url, baseImage: image, displayScale: scale)
        canvas.delegate = self

        let contentSize = NSSize(width: canvas.displaySize.width,
                                 height: canvas.displaySize.height + toolbarHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "标注 \(url.lastPathComponent)"
        // Keep the annotation UI consistently light even when macOS is in Dark Mode.
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        canvas.frame = NSRect(x: 0, y: 0,
                              width: canvas.displaySize.width,
                              height: canvas.displaySize.height)
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)

        let toolbar = buildToolbar(width: contentSize.width, height: toolbarHeight)
        toolbar.frame = NSRect(x: 0, y: canvas.displaySize.height,
                               width: contentSize.width,
                               height: toolbarHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(toolbar)
        window.contentView = container
        window.center()

        self.window = window
        self.canvas = canvas
        self.targetURL = url
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        updateUndoState()
    }

    private func presentUnsupportedAlert() {
        let alert = NSAlert()
        alert.messageText = "这张截图无法标注"
        alert.informativeText = "BetterShot 只能标注 PNG、JPEG、HEIC 和 TIFF 图片。"
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 工具栏

    private func buildToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.appearance = NSAppearance(named: .aqua)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        let tools = NSSegmentedControl(images: AnnotationTool.allCases.map { tool in
            if tool == .mosaic {
                if let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.label) { return image }
                if let image = NSImage(systemSymbolName: "aqi.medium", accessibilityDescription: tool.label) { return image }
                NSLog("BetterShot: mosaic symbols unavailable; using grid fallback")
                return NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: tool.label) ?? NSImage()
            }
            return NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.label) ?? NSImage()
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.segmentStyle = .texturedRounded
        tools.selectedSegment = AnnotationTool.rectangle.rawValue
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            tools.setToolTip(tool.label, forSegment: index)
        }
        stack.addArrangedSubview(tools)

        let widths = NSSegmentedControl(images: [2, 4, 8].map(Self.dotImage(diameter:)),
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(widthChanged(_:)))
        widths.segmentStyle = .texturedRounded
        widths.selectedSegment = 1
        widths.setToolTip("细", forSegment: 0)
        widths.setToolTip("中", forSegment: 1)
        widths.setToolTip("粗", forSegment: 2)
        stack.addArrangedSubview(widths)

        for (index, color) in Self.palette.enumerated() {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            button.title = ""
            button.isBordered = false
            button.wantsLayer = true
            button.tag = index
            button.target = self
            button.action = #selector(colorChanged(_:))
            button.toolTip = "颜色"
            button.layer?.backgroundColor = color.usingColorSpace(.deviceRGB)?.cgColor
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }
        updateColorSelection()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward",
                                           accessibilityDescription: "撤销") ?? NSImage(),
                            target: self,
                            action: #selector(undoTapped))
        undo.bezelStyle = .texturedRounded
        undo.toolTip = "撤销（⌘Z）"
        stack.addArrangedSubview(undo)
        undoButton = undo

        let redo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.forward",
                                           accessibilityDescription: "重做") ?? NSImage(),
                            target: self,
                            action: #selector(redoTapped))
        redo.bezelStyle = .texturedRounded
        redo.toolTip = "重做（⇧⌘Z）"
        stack.addArrangedSubview(redo)
        redoButton = redo

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(cancel)

        let done = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done)

        return bar
    }

    private static func dotImage(diameter: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let inset = (size.width - diameter) / 2
            let path = NSBezierPath(ovalIn: NSRect(x: inset, y: inset,
                                                   width: diameter, height: diameter))
            NSColor.labelColor.setFill()
            path.fill()
            return true
        }
    }

    private func updateColorSelection() {
        for (index, button) in colorButtons.enumerated() {
            let selected = canvas?.color == Self.palette[index]
            button.layer?.borderWidth = selected ? 3 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
        }
    }

    private func updateUndoState() {
        undoButton?.isEnabled = canvas?.canUndo ?? false
        redoButton?.isEnabled = canvas?.canRedo ?? false
    }

    // MARK: 操作

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        guard let tool = AnnotationTool(rawValue: sender.selectedSegment) else { return }
        canvas?.commitTextIfNeeded()
        canvas?.tool = tool
        window?.makeFirstResponder(canvas)
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        let widths: [CGFloat] = [2, 4, 8]
        guard sender.selectedSegment >= 0, sender.selectedSegment < widths.count else { return }
        canvas?.lineWidthPoints = widths[sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.palette.count else { return }
        canvas?.color = Self.palette[sender.tag]
        updateColorSelection()
        window?.makeFirstResponder(canvas)
    }

    @objc private func undoTapped() {
        canvas?.undo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func redoTapped() {
        canvas?.redo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func cancelTapped() { close() }

    @objc private func doneTapped() { commitAndClose() }

    // MARK: 画布回调

    func canvasDidChange() {
        updateUndoState()
    }

    func canvasDidCommit() {
        commitAndClose()
    }

    func canvasDidCancel() {
        close()
    }

    // MARK: 写回

    private func commitAndClose() {
        guard let canvas, let url = targetURL else {
            close()
            return
        }
        canvas.commitTextIfNeeded()
        guard !canvas.annotations.isEmpty else {
            close()
            return
        }
        guard let image = canvas.renderFinalImage() else {
            presentWriteError("无法生成标注后的图片。")
            return
        }
        do {
            try ImageWriter.write(image, to: url)
            EventSuppressor.shared.suppress(url, for: 10)
            PinManager.shared.reload(url: url)
            close()
        } catch {
            presentWriteError(error.localizedDescription)
        }
    }

    private func presentWriteError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法保存标注"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        canvas = nil
        targetURL = nil
        colorButtons.removeAll()
        undoButton = nil
        redoButton = nil
    }
}
