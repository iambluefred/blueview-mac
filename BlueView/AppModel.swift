import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum Mode { case grid, list, viewer }

    private(set) var folder: URL?
    private(set) var files: [ImageFile] = []
    private(set) var subfolders: [URL] = []
    var selection: Set<URL> = []
    /// 目前焦點的照片（右側資訊、看圖模式顯示這張）
    var focused: URL?
    var mode: Mode = .grid
    /// 看圖前所在的瀏覽方式（縮圖或列表），關閉看圖時回到這裡
    private var browseMode: Mode = .grid
    /// 列表模式：資料夾裡所有的檔案（含非圖片）
    private(set) var entries: [FileEntry] = []
    /// 檔案被修改後遞增，讓看圖畫面重新載入
    private(set) var contentVersion = 0

    var sort: SortOrder { didSet { resort(); save() } }
    var ascending: Bool { didSet { resort(); save() } }
    var convertOptions: ConvertOptions { didSet { save() } }

    private var back: [URL] = []
    private var forward: [URL] = []

    // 轉檔進度
    private(set) var isConverting = false
    private(set) var convertDone = 0
    private(set) var convertTotal = 0
    private(set) var statusMessage = ""
    var showConvert = false
    private var stopRequested = false

    init() {
        let d = UserDefaults.standard
        sort = SortOrder(rawValue: d.string(forKey: "sort") ?? "") ?? .name
        ascending = d.object(forKey: "ascending") as? Bool ?? true
        convertOptions = (d.data(forKey: "convertOptions")).flatMap { try? JSONDecoder().decode(ConvertOptions.self, from: $0) } ?? ConvertOptions()
        let last = d.string(forKey: "lastFolder").map { URL(fileURLWithPath: $0) }
        let start = last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if let start { open(start, recordHistory: false) }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(sort.rawValue, forKey: "sort")
        d.set(ascending, forKey: "ascending")
        d.set(try? JSONEncoder().encode(convertOptions), forKey: "convertOptions")
        if let folder { d.set(folder.path, forKey: "lastFolder") }
    }

    // MARK: - 資料夾

    func open(_ url: URL, recordHistory: Bool = true) {
        if recordHistory, let folder, folder != url {
            back.append(folder)
            forward.removeAll()
        }
        folder = url
        selection = []
        focused = nil
        mode = browseMode
        reload()
        save()
    }

    func reload() {
        guard let folder else { return }
        let url = folder
        Task.detached(priority: .userInitiated) {
            let found = FolderScanner.images(in: url)
            let subs = FolderScanner.subfolders(of: url)
            let all = FolderScanner.allEntries(in: url)
            await MainActor.run {
                guard self.folder == url else { return }
                self.files = FolderScanner.sorted(found, by: self.sort, ascending: self.ascending)
                self.subfolders = subs
                self.entries = all
                if self.focused == nil { self.focused = self.files.first?.url }
                self.selection = self.selection.filter { s in self.files.contains { $0.url == s } }
            }
        }
    }

    private func resort() {
        files = FolderScanner.sorted(files, by: sort, ascending: ascending)
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { folder.map { $0.path != "/" } ?? false }

    func goBack() {
        guard let previous = back.popLast(), let folder else { return }
        forward.append(folder)
        open(previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forward.popLast(), let folder else { return }
        back.append(folder)
        open(next, recordHistory: false)
    }

    func goUp() {
        guard let folder, canGoUp else { return }
        open(folder.deletingLastPathComponent())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// 側邊欄的常用位置與外接磁碟
    var places: [(name: String, icon: String, url: URL)] {
        let fm = FileManager.default
        var list: [(String, String, URL)] = []
        if let u = fm.urls(for: .picturesDirectory, in: .userDomainMask).first { list.append((tr("Pictures", "圖片"), "photo", u)) }
        if let u = fm.urls(for: .desktopDirectory, in: .userDomainMask).first { list.append((tr("Desktop", "桌面"), "menubar.dock.rectangle", u)) }
        if let u = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first { list.append((tr("Downloads", "下載項目"), "arrow.down.circle", u)) }
        list.append((NSUserName(), "house", fm.homeDirectoryForCurrentUser))
        return list
    }

    var volumes: [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path.hasPrefix("/Volumes/") }
    }

    // MARK: - 選取與看圖

    var focusedIndex: Int? { files.firstIndex { $0.url == focused } }
    var focusedFile: ImageFile? { focusedIndex.map { files[$0] } }

    func select(_ url: URL, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else if extend, let anchor = focusedIndex, let target = files.firstIndex(where: { $0.url == url }) {
            let range = min(anchor, target)...max(anchor, target)
            selection.formUnion(files[range].map(\.url))
        } else {
            selection = [url]
        }
        focused = url
    }

    func move(by offset: Int, extend: Bool = false) {
        guard !files.isEmpty else { return }
        let index = focusedIndex ?? -1
        let next = min(max(index + offset, 0), files.count - 1)
        select(files[next].url, extend: extend)
        if mode == .viewer { prefetchAround() }
    }

    func setBrowseMode(_ newMode: Mode) {
        guard newMode != .viewer else { return openViewer() }
        browseMode = newMode
        mode = newMode
    }

    /// 列表中點兩下：資料夾進入、照片開單張、其他檔案用預設 App 開啟
    func activate(_ url: URL) {
        guard let entry = entries.first(where: { $0.url == url }) else { return }
        if entry.isFolder { open(url) }
        else if entry.isImage { openViewer(url) }
        else { NSWorkspace.shared.open(url) }
    }

    /// 目前選取的非圖片檔（右側顯示基本資訊）
    var focusedEntry: FileEntry? {
        guard let focused else { return nil }
        return entries.first { $0.url == focused }
    }

    func openViewer(_ url: URL? = nil) {
        if mode != .viewer { browseMode = mode }
        if let url { select(url) }
        guard focused != nil else { return }
        mode = .viewer
        prefetchAround()
    }

    func closeViewer() { mode = browseMode }

    /// 預先解碼前後各兩張
    func prefetchAround() {
        guard let index = focusedIndex else { return }
        let urls = [1, -1, 2, -2].compactMap { files.indices.contains(index + $0) ? files[index + $0].url : nil }
        Task { await ImagePipeline.shared.prefetch(urls) }
    }

    func selectAll() { selection = Set(files.map(\.url)) }

    func revealInFinder() {
        let urls = selection.isEmpty ? [focused].compactMap { $0 } : Array(selection)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openWithDefaultApp() {
        if let focused { NSWorkspace.shared.open(focused) }
    }

    // MARK: - 旋轉

    /// 已旋轉的紀錄，可以用 ⌘Z 還原、⇧⌘Z 重做
    private(set) var undoStack: [(urls: [URL], direction: Rotator.Direction)] = []
    private(set) var redoStack: [(urls: [URL], direction: Rotator.Direction)] = []

    var undoTitle: String? { undoStack.last.map { tr("Undo Rotate (\($0.urls.count))", "還原旋轉（\($0.urls.count) 張）") } }
    var redoTitle: String? { redoStack.last.map { tr("Redo Rotate (\($0.urls.count))", "重做旋轉（\($0.urls.count) 張）") } }

    /// 旋轉選取的照片（看圖模式下旋轉目前這張）
    func rotate(_ direction: Rotator.Direction) {
        let targets = mode == .viewer ? [focused].compactMap { $0 } : convertTargets
        guard !targets.isEmpty else { return }
        apply(targets, direction, record: .undo)
    }

    func undoRotate() {
        guard let last = undoStack.popLast() else { return }
        apply(last.urls, opposite(last.direction), record: .redo, original: last.direction)
    }

    func redoRotate() {
        guard let last = redoStack.popLast() else { return }
        apply(last.urls, last.direction, record: .undoKeepRedo)
    }

    private enum Record { case undo, redo, undoKeepRedo }

    private func opposite(_ d: Rotator.Direction) -> Rotator.Direction { d == .clockwise ? .counterClockwise : .clockwise }

    private func apply(_ targets: [URL], _ direction: Rotator.Direction, record: Record, original: Rotator.Direction? = nil) {
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            var done: [URL] = []
            for url in targets {
                do {
                    try Rotator.rotate(url, direction)
                    done.append(url)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            await ImagePipeline.shared.invalidate(targets)
            let message = failures.joined(separator: "\n")
            let rotated = done
            await MainActor.run {
                if !rotated.isEmpty {
                    switch record {
                    case .undo:
                        self.undoStack.append((rotated, direction))
                        self.redoStack.removeAll()
                    case .redo:
                        self.redoStack.append((rotated, original ?? direction))
                    case .undoKeepRedo:
                        self.undoStack.append((rotated, direction))
                    }
                    self.statusMessage = tr("Rotated \(rotated.count) photo(s). ⌘Z to undo.", "已旋轉 \(rotated.count) 張，可按 ⌘Z 還原。")
                }
                self.contentVersion += 1
                self.reload()
                if !message.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = tr("Some photos were not rotated", "有些照片沒有旋轉")
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - 轉檔

    /// 要轉的檔案：有選取就轉選取的，否則轉目前這張
    var convertTargets: [URL] {
        let chosen = selection.isEmpty ? [focused].compactMap { $0 } : files.map(\.url).filter { selection.contains($0) }
        return chosen
    }

    var convertOutputFolder: URL? {
        if !convertOptions.outputPath.isEmpty { return URL(fileURLWithPath: convertOptions.outputPath) }
        return folder?.appendingPathComponent("Converted")
    }

    func chooseConvertOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { convertOptions.outputPath = url.path }
    }

    func startConvert() {
        let targets = convertTargets
        guard !isConverting, !targets.isEmpty, let out = convertOutputFolder else { return }
        let o = convertOptions
        isConverting = true
        stopRequested = false
        convertDone = 0
        convertTotal = targets.count
        statusMessage = tr("Converting \(targets.count) photos…", "轉檔中：\(targets.count) 張…")
        let start = Date()
        Task.detached(priority: .userInitiated) {
            var converted = 0, skipped = 0
            var failures: [String] = []
            var notes: [String] = []
            await withTaskGroup(of: (URL, Result<Converter.Outcome, Error>).self) { group in
                var iterator = targets.makeIterator()
                func launch() -> Bool {
                    guard let url = iterator.next() else { return false }
                    group.addTask {
                        (url, Result { try Converter.convert(url, to: Converter.destination(for: url, in: out, format: o.format), options: o) })
                    }
                    return true
                }
                for _ in 0..<4 { if !launch() { break } }
                while let (url, result) = await group.next() {
                    switch result {
                    case .success(.converted(let note)):
                        converted += 1
                        if let note { notes.append("\(url.lastPathComponent)：\(note)") }
                    case .success(.skipped): skipped += 1
                    case .failure(let error): failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                    let done = converted + skipped + failures.count
                    let stop = await MainActor.run { () -> Bool in
                        self.convertDone = done
                        return self.stopRequested
                    }
                    if !stop { _ = launch() }
                }
            }
            let seconds = Date().timeIntervalSince(start)
            let summary = tr(String(format: "Done in %.1f s: %d converted, %d skipped (already there), %d failed", seconds, converted, skipped, failures.count),
                             String(format: "完成，耗時 %.1f 秒：轉檔 %d 張、略過（已存在）%d 張、失敗 %d 張", seconds, converted, skipped, failures.count))
            let details = (failures + notes).prefix(12).joined(separator: "\n")
            await MainActor.run {
                self.isConverting = false
                self.statusMessage = summary
                if !details.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = summary
                    alert.informativeText = details
                    alert.runModal()
                }
                NSWorkspace.shared.activateFileViewerSelecting([out])
                if out.deletingLastPathComponent() == self.folder { self.reload() }
            }
        }
    }

    func stopConvert() { stopRequested = true }
}
