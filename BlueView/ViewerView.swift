import AppKit
import SwiftUI

/// 單張看圖：依螢幕大小解碼（快），放大超過解碼解析度時再載入原圖
struct ViewerView: View {
    let model: AppModel
    @State private var decoded: DecodedImage?
    @State private var loadInfo = ""
    @State private var zoom = ZoomCommand.fit
    /// 目前縮放比例（1 = 100%，一個影像像素對一個螢幕像素）
    @State private var scale: CGFloat = 1
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            ZoomableImage(decoded: decoded, command: $zoom, onScale: { scale = $0 }) { needFull in
                guard needFull, let url = model.focused, decoded?.isFullResolution == false else { return }
                Task {
                    if let full = await ImagePipeline.shared.image(url, fullResolution: true), model.focused == url {
                        decoded = full
                        loadInfo = tr(String(format: "Full resolution %.0f ms", full.milliseconds), String(format: "原始解析度 %.0f ms", full.milliseconds))
                    }
                }
            }
            if let file = model.focusedFile, let index = model.focusedIndex {
                HStack(spacing: 10) {
                    FileNameLabel(url: file.url, iconSize: 16).fontWeight(.medium)
                    Text("\(index + 1) / \(model.files.count)").monospacedDigit()
                    if !loadInfo.isEmpty { Text(loadInfo).monospacedDigit() }
                    Spacer()
                    Text(tr("Scroll wheel / pinch to zoom · double-click fit ↔ 100%", "滾輪／捏合縮放・雙擊 符合 ↔ 100%"))
                        .foregroundStyle(.white.opacity(0.6))
                    zoomControls
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.55))
                .environment(\.colorScheme, .dark)
            }
        }
        .contextMenu {
            Button(tr("Rotate Left", "向左旋轉")) { model.rotate(.counterClockwise) }
            Button(tr("Rotate Right", "向右旋轉")) { model.rotate(.clockwise) }
            Divider()
            Button(tr("Show in Finder", "在 Finder 中顯示")) { model.revealInFinder() }
            Divider()
            Button(tr("Move to Trash", "丟到垃圾桶")) { model.moveToTrash() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .space, .escape, .return]) { press in
            switch press.key {
            case .leftArrow, .upArrow: model.move(by: -1)
            case .rightArrow, .downArrow, .space: model.move(by: 1)
            default: model.closeViewer()
            }
            return .handled
        }
        .onAppear { focused = true }
        .task(id: "\(model.focused?.path ?? "")|\(model.contentVersion)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomCommand)) { note in
            if let command = note.object as? ZoomCommand { zoom = command }
        }
    }

    /// 底部列的縮放控制：− 百分比 ＋ 符合 100%
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoom = .zoomOut } label: { Image(systemName: "minus.magnifyingglass") }
                .help(tr("Zoom Out (⌘−)", "縮小（⌘−）"))
            Menu {
                ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { value in
                    Button("\(Int(value * 100))%") { zoom = .scale(value) }
                }
                Divider()
                Button(tr("Zoom to Fit", "符合視窗")) { zoom = .fit }
            } label: {
                Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { zoom = .zoomIn } label: { Image(systemName: "plus.magnifyingglass") }
                .help(tr("Zoom In (⌘+)", "放大（⌘+）"))
            Button(tr("Fit", "符合")) { zoom = .fit }
                .help(tr("Zoom to Fit (⌘0)", "符合視窗（⌘0）"))
            Button("100%") { zoom = .actual }
                .help(tr("Actual Size (⌘1)", "實際大小（⌘1）"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
    }

    private func load() async {
        guard let url = model.focused else { decoded = nil; return }
        let wasCached = await ImagePipeline.shared.isCached(url)
        let start = Date()
        let result = await ImagePipeline.shared.image(url)
        guard model.focused == url else { return }
        decoded = result
        zoom = .fit
        let total = Date().timeIntervalSince(start) * 1000
        if let result {
            loadInfo = wasCached
                ? tr(String(format: "Preloaded · shown in %.0f ms", total), String(format: "已預先載入・%.0f ms 顯示", total))
                : tr(String(format: "Opened in %.0f ms", result.milliseconds), String(format: "開圖 %.0f ms", result.milliseconds))
        } else {
            loadInfo = tr("Cannot open this file", "無法開啟這個檔案")
        }
        model.prefetchAround()
    }
}

enum ZoomCommand: Equatable {
    case fit, actual, zoomIn, zoomOut
    /// 指定比例，1 = 100%
    case scale(CGFloat)
}

extension Notification.Name {
    static let zoomCommand = Notification.Name("BlueViewZoomCommand")
}

/// NSScrollView 包裝：捏合／滾輪／⌘± 縮放、雙擊切換符合視窗與 100%、小於視窗時置中
private struct ZoomableImage: NSViewRepresentable {
    let decoded: DecodedImage?
    @Binding var command: ZoomCommand
    /// 縮放比例改變時回報（1 = 100%）
    let onScale: (CGFloat) -> Void
    /// 放大到需要原始解析度時呼叫
    let needsFullResolution: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ZoomScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 16
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        let imageView = ZoomImageView()
        imageView.onDoubleClick = { [weak coordinator = context.coordinator] point in coordinator?.toggleFit(at: point) }
        scroll.onWheelZoom = { [weak coordinator = context.coordinator] factor, point in coordinator?.zoom(by: factor, at: point) }
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        scroll.documentView = imageView
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.magnificationChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let imageView = scroll.documentView as? NSImageView else { return }
        let c = context.coordinator
        if let decoded {
            // 文件尺寸＝原圖的「點」大小：放大到 100% 時一個影像像素對應一個螢幕像素
            let scale = scroll.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let docSize = NSSize(width: decoded.pixelSize.width / scale, height: decoded.pixelSize.height / scale)
            let changedPhoto = c.currentSize != docSize || c.currentImage !== decoded.image
            if changedPhoto {
                imageView.image = NSImage(cgImage: decoded.image, size: docSize)
                if c.currentSize != docSize {
                    imageView.frame = NSRect(origin: .zero, size: docSize)
                    c.currentSize = docSize
                    c.apply(.fit)
                }
                c.currentImage = decoded.image
            }
        } else {
            imageView.image = nil
            c.currentImage = nil
        }
        if command != c.lastCommand {
            c.apply(command)
            c.lastCommand = command
            DispatchQueue.main.async { if command != .fit { self.command = .fit; c.lastCommand = .fit } }
        }
    }

    final class Coordinator: NSObject {
        var parent: ZoomableImage
        weak var scroll: NSScrollView?
        var currentSize: NSSize = .zero
        var currentImage: CGImage?
        var lastCommand: ZoomCommand = .fit
        var isFit = true

        init(_ parent: ZoomableImage) { self.parent = parent }

        var fitMagnification: CGFloat {
            guard let scroll, currentSize.width > 0 else { return 1 }
            let area = scroll.contentSize
            return min(area.width / currentSize.width, area.height / currentSize.height, 1 * 8)
        }

        func apply(_ command: ZoomCommand) {
            guard let scroll else { return }
            switch command {
            case .fit:
                scroll.magnification = fitMagnification
                isFit = true
            case .actual:
                scroll.magnification = 1
                isFit = false
            case .zoomIn:
                scroll.magnification = min(scroll.magnification * 1.5, scroll.maxMagnification)
                isFit = false
            case .zoomOut:
                scroll.magnification = max(scroll.magnification / 1.5, scroll.minMagnification)
                isFit = false
            case .scale(let value):
                scroll.magnification = min(max(value, scroll.minMagnification), scroll.maxMagnification)
                isFit = false
            }
            changed()
        }

        /// 滾輪縮放：以游標位置為中心
        func zoom(by factor: CGFloat, at point: NSPoint) {
            guard let scroll, currentSize.width > 0 else { return }
            let target = min(max(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification)
            scroll.setMagnification(target, centeredAt: point)
            isFit = false
            changed()
        }

        /// 雙擊：符合視窗時放大到 100%（以點擊處為中心），否則回到符合視窗
        func toggleFit(at point: NSPoint) {
            guard let scroll else { return }
            if isFit || abs(scroll.magnification - fitMagnification) < 0.001 {
                scroll.setMagnification(1, centeredAt: point)
                isFit = false
            } else {
                scroll.magnification = fitMagnification
                isFit = true
            }
            changed()
        }

        private func changed() {
            checkResolution()
            if let scroll { let value = scroll.magnification; DispatchQueue.main.async { self.parent.onScale(value) } }
        }

        @objc func magnificationChanged() {
            isFit = false
            changed()
        }

        @objc func frameChanged() {
            if isFit { scroll?.magnification = fitMagnification; changed() }
        }

        /// 顯示的像素比解碼的多時，要求原始解析度
        func checkResolution() {
            guard let scroll, let image = currentImage, currentSize.width > 0 else { return }
            let backing = scroll.window?.backingScaleFactor ?? 2
            let shownPixels = currentSize.width * scroll.magnification * backing
            parent.needsFullResolution(shownPixels > CGFloat(image.width) * 1.05)
        }
    }
}

/// 滑鼠滾輪（一格一格的）用來縮放；觸控板的雙指捲動仍是平移，捏合縮放
private final class ZoomScrollView: NSScrollView {
    var onWheelZoom: ((CGFloat, NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let isMouseWheel = !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
        guard isMouseWheel || event.modifierFlags.contains(.command), let doc = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = pow(1.15, delta > 0 ? 1.0 : -1.0)
        onWheelZoom?(factor, doc.convert(event.locationInWindow, from: nil))
    }
}

/// 雙擊回報點擊位置（影像座標）
private final class ZoomImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// 圖片比視窗小時置中
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
