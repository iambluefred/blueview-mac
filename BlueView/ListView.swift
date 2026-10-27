import AppKit
import SwiftUI

/// 列表模式：顯示資料夾裡所有檔案（含非圖片），可依欄位排序
struct ListView: View {
    @Bindable var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]

    private var rows: [FileEntry] {
        // 資料夾一律在前面，同類再依使用者點的欄位排序
        model.entries.sorted { a, b in
            if a.folderRank != b.folderRank { return a.folderRank < b.folderRank }
            for comparator in sortOrder {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
    }

    var body: some View {
        Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn(tr("Name", "名稱"), value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: entry.isFolder ? FolderIcon.icon(for: entry.url) : FileTypeIcon.icon(for: entry.url))
                        .resizable().frame(width: 16, height: 16)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.isImage || entry.isFolder ? .primary : .secondary)
                }
            }
            .width(min: 120, ideal: 320)
            TableColumn(tr("Kind", "種類"), value: \.kind) { Text($0.kind).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 130)
            TableColumn(tr("Size", "大小"), value: \.size) { entry in
                Text(entry.isFolder || entry.isPackage ? "--" : MetadataReader.fileSize(entry.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)
            TableColumn(tr("Date Modified", "修改日期"), value: \.modified) { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 160)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button(tr("Open", "開啟")) { model.activate(url) }
                Button(tr("Open with Default App", "用預設 App 開啟")) { NSWorkspace.shared.open(url) }
                Button(tr("Show in Finder", "在 Finder 中顯示")) { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Divider()
                Button(tr("Move to Trash", "丟到垃圾桶")) {
                    model.selection = urls
                    model.moveToTrash()
                }
            }
        } primaryAction: { urls in
            // 點兩下或按 Return
            if let url = urls.first { model.activate(url) }
        }
        .onChange(of: model.selection) { _, newValue in
            // 右側資訊顯示最後選到的項目
            if let last = newValue.first(where: { $0 != model.focused }) ?? newValue.first { model.focused = last }
        }
        .overlay {
            if model.entries.isEmpty {
                ContentUnavailableView(tr("This folder is empty", "這個資料夾是空的"), systemImage: "folder")
            }
        }
    }
}
