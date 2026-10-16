import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一張圖片檔
struct ImageFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let size: Int64
    let modified: Date

    var isRaw: Bool { ImageFormats.isRaw(url) }
}

enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case name, date, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: tr("Name", "名稱")
        case .date: tr("Date Modified", "修改日期")
        case .size: tr("Size", "大小")
        }
    }
}

enum ImageFormats {
    static let rawExtensions: Set<String> = ["cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "x3f", "erf"]

    /// ImageIO 能讀的所有副檔名（JPEG、HEIC、PNG、TIFF、GIF、WebP、各家 RAW…）
    static let readableExtensions: Set<String> = {
        var exts = rawExtensions
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        for id in identifiers {
            if let type = UTType(id) { exts.formUnion(type.tags[.filenameExtension] ?? []) }
        }
        // PDF 雖然 ImageIO 能讀，但不算照片
        exts.remove("pdf")
        return Set(exts.map { $0.lowercased() })
    }()

    static func isImage(_ url: URL) -> Bool { readableExtensions.contains(url.pathExtension.lowercased()) }
    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
}

enum FolderScanner {
    /// 列出資料夾裡的圖片（不含子資料夾）
    static func images(in folder: URL) -> [ImageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            guard ImageFormats.isImage(url), let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return ImageFile(url: url, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
    }

    static func subfolders(of folder: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func sorted(_ files: [ImageFile], by order: SortOrder, ascending: Bool) -> [ImageFile] {
        let result: [ImageFile]
        switch order {
        case .name: result = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: result = files.sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
        case .size: result = files.sorted { ($0.size, $0.name) < ($1.size, $1.name) }
        }
        return ascending ? result : result.reversed()
    }
}

/// 列表模式的一個項目（任何檔案或資料夾）
struct FileEntry: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isFolder: Bool
    let isImage: Bool
    let size: Int64
    let modified: Date
    let kind: String

    /// 資料夾排最前面，用 0；其他用 1（給表格排序用）
    var folderRank: Int { isFolder ? 0 : 1 }
}

extension FolderScanner {
    static func allEntries(in folder: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = v.isDirectory == true && v.isPackage != true
            return FileEntry(url: url, name: url.lastPathComponent, isFolder: isFolder, isImage: !isFolder && ImageFormats.isImage(url),
                             size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast,
                             kind: v.localizedTypeDescription ?? url.pathExtension.uppercased())
        }
        .sorted { a, b in
            if a.folderRank != b.folderRank { return a.folderRank < b.folderRank }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
