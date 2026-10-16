import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("thumbSize") private var thumbSize = 180.0

    var body: some View {
        // 三欄直接並排（寬度自己控制，13 吋螢幕也不會被裁切）
        HStack(spacing: 0) {
            if showSidebar && model.mode == .grid {
                SidebarView(model: model).frame(width: 210)
                Divider()
            }
            Group {
                switch model.mode {
                case .grid: GridView(model: model, thumbSize: thumbSize)
                case .viewer: ViewerView(model: model)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                Divider()
                InspectorView(model: model).frame(width: 280)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model, thumbSize: $thumbSize) }
        .frame(minWidth: 860, minHeight: 520)
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
                Picker(tr("View", "顯示"), selection: Binding(get: { model.mode == .grid ? 0 : 1 },
                                                              set: { $0 == 0 ? model.closeViewer() : model.openViewer() })) {
                    Image(systemName: "square.grid.2x2").tag(0)
                    Image(systemName: "photo").tag(1)
                }
                .pickerStyle(.segmented)
                .help(tr("Grid / single photo", "縮圖／單張"))
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
            Text(tr("\(model.files.count) photos", "\(model.files.count) 張")).monospacedDigit()
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
