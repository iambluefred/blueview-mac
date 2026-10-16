import AppKit
import SwiftUI

@main
struct BlueViewApp: App {
    @State private var model = AppModel()
    @State private var localizer = Localizer.shared

    var body: some Scene {
        Window("BlueView", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 740)
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
