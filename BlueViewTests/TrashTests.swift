import XCTest
@testable import BlueView

/// 丟到垃圾桶：只動暫存資料夾裡產生的測試圖，測完把它們從垃圾桶清掉
@MainActor
final class TrashTests: XCTestCase {
    private var dir: URL!
    private var model: AppModel!
    /// 使用者的設定，測完還原
    private var savedDefaults: [String: Any?] = [:]
    /// 測試中丟進垃圾桶的檔案（測完從垃圾桶清掉）
    private var trashed: [URL] = []

    override func setUp() async throws {
        for key in ["lastFolder", "sort", "ascending"] { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Fixture.jpeg(width: 40, height: 30).write(to: dir.appendingPathComponent(name))
        }
        model = AppModel()
        model.sort = .name
        model.ascending = true
        model.open(dir, recordHistory: false)
        try await wait { self.model.files.count == 3 }
    }

    override func tearDown() async throws {
        for url in trashed + trashedNow() {
            try? FileManager.default.removeItem(at: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "測試檔不能留在垃圾桶")
        }
        try? FileManager.default.removeItem(at: dir)
        // 不要改到使用者上次開的資料夾與排序
        for (key, value) in savedDefaults { UserDefaults.standard.set(value ?? nil, forKey: key) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "等太久")
    }

    private func url(_ name: String) -> URL { model.files.first { $0.name == name }!.url }
    private var names: [String] { model.files.map(\.name) }

    /// 目前還在垃圾桶裡、可以還原的測試檔
    private func trashedNow() -> [URL] {
        model.undoStack.flatMap { edit -> [URL] in
            if case .trash(let items) = edit { return items.map(\.trashed) }
            return []
        }
    }

    func testNeighborAfterDelete() {
        let order = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        XCTAssertEqual(AppModel.neighbor(of: [order[1]], in: order), order[2], "刪掉中間的，選下一個")
        XCTAssertEqual(AppModel.neighbor(of: [order[3]], in: order), order[2], "刪掉最後一個，選前一個")
        XCTAssertEqual(AppModel.neighbor(of: [order[1], order[3]], in: order), order[2])
        XCTAssertEqual(AppModel.neighbor(of: [order[0], order[1]], in: order), order[2])
        XCTAssertNil(AppModel.neighbor(of: Set(order), in: order), "全部刪掉就沒有")
    }

    func testTrashUndoRedoInGrid() async throws {
        let b = url("b.jpg")
        model.select(b)
        model.moveToTrash()
        try await wait { self.model.undoTitle != nil }

        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path), "檔案要離開原本的資料夾")
        let inTrash = try XCTUnwrap(trashedNow().first)
        trashed.append(inTrash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path), "要在垃圾桶裡，不是永久刪除")
        XCTAssertTrue(inTrash.path.contains(".Trash"))
        XCTAssertEqual(names, ["a.jpg", "c.jpg"])
        XCTAssertEqual(model.focused?.lastPathComponent, "c.jpg", "選取移到下一張")
        XCTAssertEqual(model.selection.map(\.lastPathComponent), ["c.jpg"])

        model.undo()
        try await wait { self.model.redoTitle != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "⌘Z 要搬回原位")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inTrash.path))
        XCTAssertNil(model.undoTitle)
        XCTAssertEqual(model.focused, b, "還原後選取還原的檔案")
        try await wait { self.names == ["a.jpg", "b.jpg", "c.jpg"] }

        model.redo()
        try await wait { self.model.undoTitle != nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path), "⇧⌘Z 要再丟一次")
        XCTAssertEqual(names, ["a.jpg", "c.jpg"])
    }

    func testTrashMultipleAndUndoAllAtOnce() async throws {
        let a = url("a.jpg"), c = url("c.jpg")
        model.select(a)
        model.select(c, toggle: true)
        XCTAssertEqual(model.trashTargets, [a, c])
        model.moveToTrash()
        try await wait { self.model.undoTitle != nil }
        XCTAssertEqual(names, ["b.jpg"])
        XCTAssertEqual(model.focused?.lastPathComponent, "b.jpg")
        XCTAssertEqual(trashedNow().count, 2)
        XCTAssertTrue(model.undoTitle?.contains("2") ?? false)

        model.undo()
        try await wait { self.model.redoTitle != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
        XCTAssertEqual(model.selection, [a, c], "一次全部還原並選取")
        XCTAssertNil(model.undoTitle)
    }

    func testViewerJumpsToNeighborThenBackToGrid() async throws {
        model.openViewer(url("c.jpg"))
        XCTAssertEqual(model.mode, .viewer)

        model.moveToTrash()
        try await wait { self.names.count == 2 }
        trashed += trashedNow()
        XCTAssertEqual(model.mode, .viewer)
        XCTAssertEqual(model.focused?.lastPathComponent, "b.jpg", "最後一張刪掉就跳到上一張")

        model.move(by: -1)
        XCTAssertEqual(model.focused?.lastPathComponent, "a.jpg")
        model.moveToTrash()
        try await wait { self.names.count == 1 }
        trashed += trashedNow()
        XCTAssertEqual(model.focused?.lastPathComponent, "b.jpg", "刪掉第一張就跳到下一張")

        model.moveToTrash()
        try await wait { self.names.isEmpty }
        trashed += trashedNow()
        XCTAssertEqual(model.mode, .grid, "都刪光了回到縮圖")
        XCTAssertNil(model.focused)
        XCTAssertTrue(model.trashTargets.isEmpty)
    }

    func testListTrashesSelectedNonImageFiles() async throws {
        try Data("hello".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        model.reload()
        try await wait { self.model.entries.count == 4 }
        model.setBrowseMode(.list)
        let notes = try XCTUnwrap(model.entries.first { $0.name == "notes.txt" }?.url)
        model.selection = [notes]
        XCTAssertEqual(model.trashTargets, [notes])

        model.moveToTrash()
        try await wait { self.model.undoTitle != nil }
        trashed += trashedNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertEqual(model.entries.map(\.name), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(model.selection.count, 1, "選取移到相鄰的項目")
        XCTAssertEqual(names.count, 3, "照片不受影響")
    }
}
