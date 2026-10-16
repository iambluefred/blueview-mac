import AppKit
import SwiftUI

/// 單張看圖：依螢幕大小解碼（快），放大超過解碼解析度時再載入原圖
struct ViewerView: View {
    let model: AppModel
    @State private var decoded: DecodedImage?
    @State private var loadInfo = ""
    @State private var zoom = ZoomCommand.fit
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            ZoomableImage(decoded: decoded, command: $zoom) { needFull in
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
                    Text(file.name).fontWeight(.medium)
                    Text("\(index + 1) / \(model.files.count)").monospacedDigit()
                    if !loadInfo.isEmpty { Text(loadInfo).monospacedDigit() }
                    Spacer()
                    Text(tr("← → next · Esc back · ⌘0 fit · ⌘1 100%", "← → 切換・Esc 返回・⌘0 符合視窗・⌘1 100%"))
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.55))
            }
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
        .task(id: model.focused) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomCommand)) { note in
            if let command = note.object as? ZoomCommand { zoom = command }
        }
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
}

extension Notification.Name {
    static let zoomCommand = Notification.Name("BlueViewZoomCommand")
}

/// NSScrollView 包裝：捏合／⌘± 縮放、拖曳平移、小於視窗時置中
private struct ZoomableImage: NSViewRepresentable {
    let decoded: DecodedImage?
    @Binding var command: ZoomCommand
    /// 放大到需要原始解析度時呼叫
    let needsFullResolution: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 16
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        let imageView = NSImageView()
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
            }
            checkResolution()
        }

        @objc func magnificationChanged() {
            isFit = false
            checkResolution()
        }

        @objc func frameChanged() {
            if isFit { scroll?.magnification = fitMagnification }
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
