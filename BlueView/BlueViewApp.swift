import AppKit
import SwiftUI

@main
struct BlueViewApp: App {
    @State private var model = AppModel()
    @State private var localizer = Localizer.shared

    var body: some Scene {
        Window("BlueView", id: "main") {
            ContentView(model: model)
                .onAppear { DispatchQueue.main.async { WindowSizer.keepOnScreen() } }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("Open Folder…", "開啟資料夾…"), action: model.chooseFolder).keyboardShortcut("o")
                Button(tr("Convert…", "轉檔…")) { model.showConvert = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.convertTargets.isEmpty || model.isConverting)
                Divider()
                Button(tr("Show in Finder", "在 Finder 中顯示"), action: model.revealInFinder).keyboardShortcut("r", modifiers: [.command, .shift])
                Button(tr("Reload Folder", "重新整理資料夾"), action: model.reload).keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle ?? tr("Undo", "還原"), action: model.undoRotate)
                    .keyboardShortcut("z").disabled(model.undoTitle == nil)
                Button(model.redoTitle ?? tr("Redo", "重做"), action: model.redoRotate)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.redoTitle == nil)
            }
            CommandGroup(after: .textEditing) {
                Button(tr("Select All Photos", "全選照片"), action: model.selectAll).keyboardShortcut("a", modifiers: [.command, .option])
            }
            CommandMenu(tr("Image", "圖片")) {
                Button(tr("Rotate Left", "向左旋轉")) { model.rotate(.counterClockwise) }
                    .keyboardShortcut("l").disabled(model.convertTargets.isEmpty)
                Button(tr("Rotate Right", "向右旋轉")) { model.rotate(.clockwise) }
                    .keyboardShortcut("r").disabled(model.convertTargets.isEmpty)
            }
            CommandGroup(after: .windowSize) {
                Divider()
                Button(tr("Fit to Screen", "符合螢幕")) { WindowSizer.fitToScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Menu(tr("Window Size", "視窗大小")) {
                    Button(tr("Large (1280 × 800)", "大（1280 × 800）")) { WindowSizer.resize(to: CGSize(width: 1280, height: 800)) }
                    Button(tr("Medium (1024 × 700)", "中（1024 × 700）")) { WindowSizer.resize(to: CGSize(width: 1024, height: 700)) }
                    Button(tr("Small (800 × 600)", "小（800 × 600）")) { WindowSizer.resize(to: CGSize(width: 800, height: 600)) }
                }
            }
            CommandMenu(tr("Go", "前往")) {
                Button(tr("Back", "上一頁"), action: model.goBack).keyboardShortcut("[").disabled(!model.canGoBack)
                Button(tr("Forward", "下一頁"), action: model.goForward).keyboardShortcut("]").disabled(!model.canGoForward)
                Button(tr("Enclosing Folder", "上一層資料夾"), action: model.goUp).keyboardShortcut(.upArrow).disabled(!model.canGoUp)
                Divider()
                Button(tr("Next Photo", "下一張")) { model.move(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button(tr("Previous Photo", "上一張")) { model.move(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button(model.mode == .grid ? tr("View Photo", "看單張") : tr("Back to Grid", "回到縮圖")) {
                    model.mode == .grid ? model.openViewer() : model.closeViewer()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Divider()
                Button(tr("Zoom to Fit", "符合視窗")) { zoom(.fit) }.keyboardShortcut("0")
                Button(tr("Actual Size", "實際大小 100%")) { zoom(.actual) }.keyboardShortcut("1")
                Button(tr("Zoom In", "放大")) { zoom(.zoomIn) }.keyboardShortcut("+")
                Button(tr("Zoom Out", "縮小")) { zoom(.zoomOut) }.keyboardShortcut("-")
                Divider()
                Picker(tr("Language", "語言"), selection: $localizer.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Divider()
            }
        }
    }

    private func zoom(_ command: ZoomCommand) {
        if model.mode == .grid { model.openViewer() }
        NotificationCenter.default.post(name: .zoomCommand, object: command)
    }
}

/// 調整視窗大小：一律限制在螢幕可用範圍內並置中，不會超出螢幕
enum WindowSizer {
    @MainActor
    static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } }

    @MainActor
    static func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    @MainActor
    static func resize(to size: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let width = min(size.width, area.width), height = min(size.height, area.height)
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// 開啟時若視窗超出螢幕，縮進螢幕範圍內
    @MainActor
    static func keepOnScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}
