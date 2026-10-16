import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum Mode { case grid, viewer }

    private(set) var folder: URL?
    private(set) var files: [ImageFile] = []
    private(set) var subfolders: [URL] = []
    var selection: Set<URL> = []
    /// 目前焦點的照片（右側資訊、看圖模式顯示這張）
    var focused: URL?
    var mode: Mode = .grid

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
        mode = .grid
        reload()
        save()
    }

    func reload() {
        guard let folder else { return }
        let url = folder
        Task.detached(priority: .userInitiated) {
            let found = FolderScanner.images(in: url)
            let subs = FolderScanner.subfolders(of: url)
            await MainActor.run {
                guard self.folder == url else { return }
                self.files = FolderScanner.sorted(found, by: self.sort, ascending: self.ascending)
                self.subfolders = subs
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

    func openViewer(_ url: URL? = nil) {
        if let url { select(url) }
        guard focused != nil else { return }
        mode = .viewer
        prefetchAround()
    }

    func closeViewer() { mode = .grid }

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

    // MARK: - 轉檔

    /// 要轉的檔案：有選取就轉選取的，否則轉目前這張
    var convertTargets: [URL] {
        let chosen = selection.isEmpty ? [focused].compactMap { $0 } : files.map(\.url).filter { selection.contains($0) }
        return chosen
    }

    var convertOutputFolder: URL? {
        if !convertOptions.outputPath.isEmpty { return URL(fileURLWithPath: convertOptions.outputPath) }
        return folder?.appendingPathComponent(tr("Converted", "轉檔"))
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
