import AppKit
import SwiftUI

/// 縮圖格：點一下選取、⌘ 加選、⇧ 範圍選取、雙擊或 Return 開圖、方向鍵移動
struct GridView: View {
    let model: AppModel
    let thumbSize: Double
    @FocusState private var focused: Bool
    @State private var gridWidth: CGFloat = 800

    private var columns: Int { max(1, Int((gridWidth - 16) / (thumbSize + 12))) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                    ForEach(model.subfolders, id: \.self) { folder in
                        FolderCell(url: folder, size: thumbSize)
                            .onTapGesture(count: 2) { model.open(folder) }
                            .contextMenu {
                                Button(tr("Open", "開啟")) { model.open(folder) }
                                Button(tr("Show in Finder", "在 Finder 中顯示")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            }
                            .help(tr("Double-click to open", "點兩下開啟"))
                    }
                    ForEach(model.files) { file in
                        Thumbnail(file: file, size: thumbSize, isSelected: model.selection.contains(file.url), isFocused: model.focused == file.url)
                            .id(file.url)
                            .onTapGesture(count: 2) { model.openViewer(file.url) }
                            .simultaneousGesture(TapGesture().onEnded {
                                let flags = NSEvent.modifierFlags
                                model.select(file.url, extend: flags.contains(.shift), toggle: flags.contains(.command))
                                focused = true
                            })
                            .contextMenu {
                                Button(tr("Open", "開啟")) { model.openViewer(file.url) }
                                Button(tr("Rotate Left", "向左旋轉")) {
                                    if !model.selection.contains(file.url) { model.select(file.url) }
                                    model.rotate(.counterClockwise)
                                }
                                Button(tr("Rotate Right", "向右旋轉")) {
                                    if !model.selection.contains(file.url) { model.select(file.url) }
                                    model.rotate(.clockwise)
                                }
                                Divider()
                                Button(tr("Convert…", "轉檔…")) {
                                    if !model.selection.contains(file.url) { model.select(file.url) }
                                    model.showConvert = true
                                }
                                Divider()
                                Button(tr("Show in Finder", "在 Finder 中顯示")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                Button(tr("Open with Default App", "用預設 App 開啟")) { NSWorkspace.shared.open(file.url) }
                            }
                    }
                }
                .padding(8)
                .background(GeometryReader { g in Color.clear.onAppear { gridWidth = g.size.width }.onChange(of: g.size.width) { gridWidth = g.size.width } })
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let shift = press.modifiers.contains(.shift)
                switch press.key {
                case .leftArrow: model.move(by: -1, extend: shift)
                case .rightArrow: model.move(by: 1, extend: shift)
                case .upArrow: model.move(by: -columns, extend: shift)
                default: model.move(by: columns, extend: shift)
                }
                if let url = model.focused { proxy.scrollTo(url) }
                return .handled
            }
            .onKeyPress(.return) { model.openViewer(); return .handled }
            .onKeyPress(.space) { model.openViewer(); return .handled }
            .overlay {
                if model.files.isEmpty && model.subfolders.isEmpty {
                    ContentUnavailableView(tr("No photos in this folder", "這個資料夾沒有照片"), systemImage: "photo.on.rectangle",
                                           description: Text(tr("Pick another folder on the left, or drop a folder here.", "從左邊選其他資料夾，或把資料夾拖到這裡。")))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                model.open(isDir.boolValue ? url : url.deletingLastPathComponent())
                return true
            }
            .onAppear {
                focused = true
                if let url = model.focused { proxy.scrollTo(url, anchor: .center) }
            }
        }
    }
}

private struct Thumbnail: View {
    let file: ImageFile
    let size: Double
    let isSelected: Bool
    let isFocused: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(height: size * 0.75)
            .overlay(alignment: .topTrailing) {
                if file.isRaw {
                    Text("RAW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.orange)).foregroundStyle(.white).padding(4)
                }
            }
            Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .task(id: "\(file.url.path)|\(Int(size / 60))|\(file.modified.timeIntervalSince1970)") {
            // 縮圖解析度依格子大小分段（Retina 要兩倍像素）
            let pixels = Int((size / 60).rounded(.up) * 60 * 2)
            image = await ThumbnailLoader.shared.thumbnail(file.url, maxSide: pixels, version: file.modified)
        }
    }
}

/// 資料夾：用 macOS 的真實圖示（包括自訂的資料夾圖示）
private struct FolderCell: View {
    let url: URL
    let size: Double

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: FolderIcon.icon(for: url))
                .resizable()
                .scaledToFit()
                .frame(height: size * 0.75 * 0.8)
                .frame(height: size * 0.75)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(6)
        .contentShape(Rectangle())
    }
}

/// 系統圖示快取
enum FolderIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}
