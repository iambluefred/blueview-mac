import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("thumbSize") private var thumbSize = 180.0

    @State private var windowWidth: CGFloat = 1200
    /// 可拖曳調整的欄寬（記住使用者的設定）
    @AppStorage("sidebarWidth") private var sidebarWidth = 200.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 270.0

    /// 視窗太窄時自動收起面板（不改變使用者的設定，放大後會回來）
    /// 中間照片區至少要留的寬度
    private let minContent = 320.0
    private var sidebarVisible: Bool { showSidebar && model.mode != .viewer && Double(windowWidth) >= sidebarWidth + minContent + 8 }
    private var inspectorVisible: Bool {
        showInspector && Double(windowWidth) >= (sidebarVisible ? sidebarWidth : 0) + inspectorWidth + minContent + 16
    }
    /// 拖曳時的上限：不能把中間擠到比 minContent 還窄
    private var sidebarMax: Double { max(140, min(420, Double(windowWidth) - (inspectorVisible ? inspectorWidth : 0) - minContent - 16)) }
    private var inspectorMax: Double { max(220, min(520, Double(windowWidth) - (sidebarVisible ? sidebarWidth : 0) - minContent - 16)) }

    var body: some View {
        // 三欄直接並排（寬度自己控制，13 吋螢幕也不會被裁切）
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(model: model).frame(width: sidebarWidth)
                ResizeHandle(width: $sidebarWidth, range: 140...sidebarMax, defaultWidth: 200, growsToRight: true)
            }
            Group {
                switch model.mode {
                case .grid: GridView(model: model, thumbSize: thumbSize)
                case .list: ListView(model: model)
                case .viewer: ViewerView(model: model)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            if inspectorVisible {
                ResizeHandle(width: $inspectorWidth, range: 220...inspectorMax, defaultWidth: 270, growsToRight: false)
                InspectorView(model: model).frame(width: inspectorWidth)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { windowWidth = g.size.width }
                .onChange(of: g.size.width) { windowWidth = g.size.width }
        })
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model, thumbSize: $thumbSize) }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(model.mode == .viewer ? (model.focusedFile?.name ?? "BlueView") : (model.folder?.lastPathComponent ?? "BlueView"))
        .navigationSubtitle(model.folder?.path ?? "")
        .sheet(isPresented: $model.showConvert) { ConvertView(model: model) }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.goBack) { Label(tr("Back", "上一頁"), systemImage: "chevron.left") }
                    .disabled(!model.canGoBack).help(tr("Back", "上一頁"))
                Button(action: model.goForward) { Label(tr("Forward", "下一頁"), systemImage: "chevron.right") }
                    .disabled(!model.canGoForward).help(tr("Forward", "下一頁"))
                Button(action: model.goUp) { Label(tr("Enclosing Folder", "上一層"), systemImage: "arrow.up") }
                    .disabled(!model.canGoUp).help(tr("Enclosing folder", "上一層資料夾"))
            }
            ToolbarItemGroup {
                Picker(tr("View", "顯示"), selection: Binding(get: { model.mode },
                                                              set: { model.setBrowseMode($0) })) {
                    Image(systemName: "square.grid.2x2").tag(AppModel.Mode.grid)
                    Image(systemName: "list.bullet").tag(AppModel.Mode.list)
                    Image(systemName: "photo").tag(AppModel.Mode.viewer)
                }
                .pickerStyle(.segmented)
                .help(tr("Grid / list (all files) / single photo", "縮圖／列表（所有檔案）／單張"))
                Menu {
                    Picker(tr("Sort by", "排序方式"), selection: $model.sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(tr("Ascending", "遞增"), isOn: $model.ascending)
                } label: { Label(tr("Sort", "排序"), systemImage: "arrow.up.arrow.down") }
                .help(tr("Sort", "排序"))
                Button { model.rotate(.counterClockwise) } label: { Label(tr("Rotate Left", "向左旋轉"), systemImage: "rotate.left") }
                    .disabled(model.convertTargets.isEmpty)
                    .help(tr("Rotate left (⌘L)", "向左旋轉（⌘L）"))
                Button { model.rotate(.clockwise) } label: { Label(tr("Rotate Right", "向右旋轉"), systemImage: "rotate.right") }
                    .disabled(model.convertTargets.isEmpty)
                    .help(tr("Rotate right (⌘R)", "向右旋轉（⌘R）"))
                Button { model.showConvert = true } label: { Label(tr("Convert", "轉檔"), systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.convertTargets.isEmpty || model.isConverting)
                    .help(tr("Convert selected photos (JPEG / HEIC / PNG / TIFF)", "轉換選取的照片（JPEG／HEIC／PNG／TIFF）"))
                Button { withAnimation { showSidebar.toggle() } } label: { Label(tr("Sidebar", "側邊欄"), systemImage: "sidebar.left") }
                    .help(tr("Show or hide the sidebar", "顯示／隱藏側邊欄"))
                Button { withAnimation { showInspector.toggle() } } label: { Label(tr("Info", "資訊"), systemImage: "info.circle") }
                    .help(tr("Show or hide photo info (EXIF)", "顯示／隱藏照片資訊（EXIF）"))
            }
        }
    }
}

// MARK: - 側邊欄

private struct SidebarView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header(tr("Places", "常用位置"))
                ForEach(model.places, id: \.url) { place in
                    row(place.name, icon: place.icon, url: place.url)
                }
                if !model.volumes.isEmpty {
                    header(tr("Volumes", "磁碟"))
                    ForEach(model.volumes, id: \.self) { row($0.lastPathComponent, icon: "externaldrive", url: $0) }
                }
                if let folder = model.folder {
                    header(folder.lastPathComponent)
                    if model.subfolders.isEmpty {
                        Text(tr("No subfolders", "沒有子資料夾")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    ForEach(model.subfolders, id: \.self) { row($0.lastPathComponent, icon: "folder", url: $0) }
                }
                Button(tr("Open Folder…", "開啟資料夾…"), action: model.chooseFolder)
                    .buttonStyle(.link)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
            }
            .padding(8)
        }
        .background(.background.secondary)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }

    private func row(_ name: String, icon: String, url: URL) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: FolderIcon.icon(for: url)).resizable().scaledToFit().frame(width: 18, height: 18)
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(model.folder == url ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.open(url) }
    }
}

// MARK: - 狀態列

private struct StatusBar: View {
    let model: AppModel
    @Binding var thumbSize: Double

    var body: some View {
        HStack(spacing: 12) {
            if model.isConverting {
                ProgressView(value: Double(model.convertDone), total: Double(max(model.convertTotal, 1))).frame(width: 160)
                Text("\(model.convertDone)/\(model.convertTotal)").monospacedDigit()
                Button(tr("Stop", "停止"), action: model.stopConvert).controlSize(.small)
            } else if !model.statusMessage.isEmpty {
                Text(model.statusMessage).lineLimit(1)
            }
            Spacer()
            if model.selection.count > 1 {
                Text(tr("\(model.selection.count) selected", "已選取 \(model.selection.count) 張"))
            }
            if model.mode == .list {
                Text(tr("\(model.entries.count) items, \(model.files.count) photos", "\(model.entries.count) 個項目，照片 \(model.files.count) 張")).monospacedDigit()
            } else {
                Text(tr("\(model.files.count) photos", "\(model.files.count) 張")).monospacedDigit()
            }
            if model.mode == .grid {
                Image(systemName: "photo").imageScale(.small)
                Slider(value: $thumbSize, in: 90...360).frame(width: 110)
                Image(systemName: "photo").imageScale(.large)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 可拖曳的分隔線

/// 拖曳調整旁邊欄位的寬度；滑鼠移上去顯示左右箭頭；雙擊恢復預設寬度
private struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    /// true：欄位在分隔線左邊（往右拖變寬）；false：欄位在右邊（往左拖變寬）
    let growsToRight: Bool
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || startWidth != nil ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: hovering || startWidth != nil ? 3 : 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 3)          // 加寬可以點到的範圍
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        let delta = Double(value.translation.width) * (growsToRight ? 1 : -1)
                        width = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { withAnimation { width = defaultWidth } }
            .help(tr("Drag to resize · double-click to reset", "拖曳調整寬度・雙擊恢復預設"))
    }
}
