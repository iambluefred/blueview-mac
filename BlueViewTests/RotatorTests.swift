import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BlueView

final class RotatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-rot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 300×200 的圖：左上角紅色、其他藍色。旋轉後看紅色跑到哪個角落就知道轉對了沒
    private func makeImage(type: UTType, name: String) throws -> URL {
        let w = 300, h = 200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 60, width: 60, height: 60))  // CG 原點在左下，所以這是畫面的左上
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:02 10:00:00"] as [CFString: Any]] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    /// 依方向轉正後，回傳（寬, 高, 紅色在哪個角落）
    private func displayed(_ url: URL) -> (Int, Int, String) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary)!
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 記憶體第 0 列是畫面的最上面
        func isRed(_ x: Int, _ y: Int) -> Bool { let i = (y * w + x) * 4; return pixels[i] > 200 && pixels[i + 2] < 80 }
        let corner = isRed(5, 5) ? "topLeft" : isRed(w - 6, 5) ? "topRight" : isRed(5, h - 6) ? "bottomLeft" : isRed(w - 6, h - 6) ? "bottomRight" : "none"
        return (w, h, corner)
    }

    func testOrientationTablesAreInverse() {
        for o in 1...8 {
            XCTAssertEqual(Rotator.rotated(Rotator.rotated(o, .clockwise), .counterClockwise), o)
            var x = o
            for _ in 0..<4 { x = Rotator.rotated(x, .clockwise) }
            XCTAssertEqual(x, o, "轉四次要回到原樣")
        }
    }

    func testJPEGRotatesLosslesslyAndCorrectly() throws {
        let url = try makeImage(type: .jpeg, name: "a.jpg")
        func scan() -> Data { let d = try! Data(contentsOf: url); return d.subdata(in: d.range(of: Data([0xFF, 0xDA]))!.lowerBound..<d.count) }
        let before = scan()
        XCTAssertEqual(displayed(url).2, "topLeft")

        try Rotator.rotate(url, .clockwise)
        var shown = displayed(url)
        XCTAssertEqual(shown.0, 200); XCTAssertEqual(shown.1, 300)
        XCTAssertEqual(shown.2, "topRight", "順時針轉 90°：左上角會跑到右上角")
        XCTAssertEqual(scan(), before, "JPEG 只改方向標記，影像資料不能變")

        try Rotator.rotate(url, .clockwise)
        XCTAssertEqual(displayed(url).2, "bottomRight")
        try Rotator.rotate(url, .counterClockwise)
        try Rotator.rotate(url, .counterClockwise)
        shown = displayed(url)
        XCTAssertEqual(shown.2, "topLeft"); XCTAssertEqual(shown.0, 300)
        // 其他資訊要保留
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:10:02 10:00:00")
    }

    func testPNGRotatesPixels() throws {
        let url = try makeImage(type: .png, name: "b.png")
        try Rotator.rotate(url, .counterClockwise)
        let shown = displayed(url)
        XCTAssertEqual(shown.0, 200); XCTAssertEqual(shown.1, 300)
        XCTAssertEqual(shown.2, "bottomLeft", "逆時針轉 90°：左上角會跑到左下角")
    }

    func testHEICRotates() throws {
        let url = try makeImage(type: .heic, name: "c.heic")
        try Rotator.rotate(url, .clockwise)
        XCTAssertEqual(displayed(url).2, "topRight")
    }

    func testRawIsRefused() throws {
        let url = dir.appendingPathComponent("x.CR3")
        try Data(repeating: 1, count: 100).write(to: url)
        XCTAssertThrowsError(try Rotator.rotate(url, .clockwise)) { XCTAssertEqual($0 as? Rotator.RotateError, .raw) }
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 1, count: 100), "RAW 檔內容不能被動到")
    }
}

@MainActor
final class RotateUndoTests: XCTestCase {
    func testUndoAndRedoRestoreOrientation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.jpeg(width: 300, height: 200).write(to: dir.appendingPathComponent("a.jpg"))
        var url = dir.appendingPathComponent("a.jpg")
        func orientation() -> Int {
            let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
            return p[kCGImagePropertyOrientation] as? Int ?? 1
        }
        let model = AppModel()
        model.open(dir, recordHistory: false)
        for _ in 0..<100 where model.files.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        url = try XCTUnwrap(model.files.first?.url)  // 用 App 掃描到的路徑（/var 與 /private/var 是同一個地方）
        model.select(url)

        model.rotate(.clockwise)
        for _ in 0..<100 where model.undoTitle == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(orientation(), 6)

        model.undoRotate()
        for _ in 0..<100 where model.redoTitle == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(orientation(), 1, "⌘Z 要轉回原本的方向")
        XCTAssertNil(model.undoTitle)

        model.redoRotate()
        for _ in 0..<100 where model.undoTitle == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(orientation(), 6, "⇧⌘Z 要再轉回去")
    }
}
