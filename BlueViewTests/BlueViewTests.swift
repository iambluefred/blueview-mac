import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BlueView

/// 測試用的圖片產生器
enum Fixture {
    static func jpeg(width: Int, height: Int, exif: [CFString: Any] = [:], gps: Bool = false, orientation: Int = 1) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R6"] as [CFString: Any],
            kCGImagePropertyExifDictionary: exif.isEmpty ? [kCGImagePropertyExifDateTimeOriginal: "2026:10:02 19:30:15",
                                                            kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                                                            kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 85.0] as [CFString: Any] : exif,
        ]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 24.8, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 121.0, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func props(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    }
}

final class MetadataTests: XCTestCase {
    func testExposureFormatting() {
        XCTAssertEqual(MetadataReader.shutter(0.004), "1/250")
        XCTAssertEqual(MetadataReader.shutter(1.0 / 8000), "1/8000")
        XCTAssertEqual(MetadataReader.shutter(2), "2″")
        XCTAssertEqual(MetadataReader.shutter(2.5), "2.5″")
        XCTAssertEqual(MetadataReader.aperture(2.8), "f/2.8")
        XCTAssertEqual(MetadataReader.aperture(8), "f/8")
    }

    func testReadsExifAndGPS() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bv-meta-\(UUID().uuidString).jpg")
        try Fixture.jpeg(width: 600, height: 400, gps: true).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = MetadataReader.read(url)
        XCTAssertEqual(info.camera, "Canon EOS R6")
        XCTAssertEqual(info.exposure, "1/250 s · f/2.8 · ISO 400")
        XCTAssertEqual(info.focal, "85 mm")
        XCTAssertTrue(info.dimensions.hasPrefix("600 × 400"))
        XCTAssertEqual(info.location?.latitude ?? 0, 24.8, accuracy: 0.0001)
        XCTAssertFalse(info.allRows.isEmpty)
    }
}

final class FolderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Fixture.jpeg(width: 10, height: 10).write(to: dir.appendingPathComponent("IMG_10.jpg"))
        try Fixture.jpeg(width: 20, height: 20).write(to: dir.appendingPathComponent("IMG_2.JPG"))
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("photo.CR3"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden.jpg"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testListsOnlyImagesAndSortsNaturally() {
        let files = FolderScanner.sorted(FolderScanner.images(in: dir), by: .name, ascending: true)
        XCTAssertEqual(files.map(\.name), ["IMG_2.JPG", "IMG_10.jpg", "photo.CR3"], "數字要自然排序，文字檔與隱藏檔不列出")
        XCTAssertTrue(files[2].isRaw)
        XCTAssertEqual(FolderScanner.subfolders(of: dir).map(\.lastPathComponent), ["sub"])
        XCTAssertEqual(FolderScanner.sorted(files, by: .size, ascending: false).first?.name, files.max { $0.size < $1.size }?.name)
    }

    func testReadableFormatsIncludeCommonTypes() {
        for ext in ["jpg", "jpeg", "heic", "png", "tif", "gif", "cr3", "nef", "arw", "dng"] {
            XCTAssertTrue(ImageFormats.readableExtensions.contains(ext), ext)
        }
        XCTAssertFalse(ImageFormats.readableExtensions.contains("pdf"))
    }
}

final class ConverterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAllFormatsResizeAndKeepInfo() throws {
        let src = dir.appendingPathComponent("IMG.jpg")
        try Fixture.jpeg(width: 3000, height: 2000, gps: true).write(to: src)
        for format in OutputFormat.allCases {
            var o = ConvertOptions()
            o.format = format
            o.maxSide = 1024
            let dest = Converter.destination(for: src, in: dir.appendingPathComponent("out"), format: format)
            XCTAssertEqual(try Converter.convert(src, to: dest, options: o), .converted(note: nil), format.rawValue)
            let p = Fixture.props(dest)
            XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 1024, format.rawValue)
            XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 683, format.rawValue)
            XCTAssertEqual((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String, "Canon EOS R6", format.rawValue)
            XCTAssertNotNil(p[kCGImagePropertyGPSDictionary], format.rawValue)
            XCTAssertEqual(dest.pathExtension, format.fileExtension)
        }
    }

    func testStripInfoAndRespectOrientation() throws {
        // 直拍照片（方向 6）：轉檔後像素應該轉正，方向寫 1
        let src = dir.appendingPathComponent("portrait.jpg")
        try Fixture.jpeg(width: 1200, height: 800, gps: true, orientation: 6).write(to: src)
        var o = ConvertOptions()
        o.keepExif = false
        o.keepGPS = false
        let dest = dir.appendingPathComponent("p.jpg")
        _ = try Converter.convert(src, to: dest, options: o)
        let p = Fixture.props(dest)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 800)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 1200)
        XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary])
        XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertEqual(try Converter.convert(src, to: dest, options: o), .skipped, "已存在就略過")
    }

    /// 假 RAW：內嵌一張夠大的預覽圖 → 存 JPEG 原尺寸時應該原封不動
    func testRawEmbeddedPreviewIsLossless() throws {
        let preview = Fixture.jpeg(width: 2400, height: 1600)
        var raw = Data(repeating: 0x00, count: 4096)
        raw.append(preview)
        let src = dir.appendingPathComponent("IMG_0001.CR3")
        try raw.write(to: src)
        let dest = dir.appendingPathComponent("IMG_0001.jpg")
        XCTAssertEqual(try Converter.convert(src, to: dest, options: ConvertOptions()), .converted(note: nil))
        func scan(_ d: Data) -> Data { d.subdata(in: d.range(of: Data([0xFF, 0xDA]))!.lowerBound..<d.count) }
        XCTAssertEqual(scan(try Data(contentsOf: dest)), scan(preview))
    }
}

final class PipelineTests: XCTestCase {
    func testScreenSizeDecodeAndPrefetchCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try Fixture.jpeg(width: 6000, height: 4000).write(to: a)
        try Fixture.jpeg(width: 6000, height: 4000).write(to: b)

        let decoded = ImagePipeline.decode(a, maxSide: 2560)
        XCTAssertEqual(decoded?.image.width, 2560)
        XCTAssertEqual(decoded?.pixelSize, CGSize(width: 6000, height: 4000))
        XCTAssertEqual(decoded?.isFullResolution, false)
        XCTAssertEqual(ImagePipeline.decode(a, maxSide: nil)?.image.width, 6000)

        let pipeline = ImagePipeline()
        await pipeline.prefetch([b])
        for _ in 0..<100 where !(await pipeline.isCached(b)) { try await Task.sleep(nanoseconds: 20_000_000) }
        let cached = await pipeline.isCached(b)
        XCTAssertTrue(cached, "預先載入後應該已在快取")
        let start = Date()
        _ = await pipeline.image(b)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.01, "已預先載入的照片應該立刻拿到")
    }
}

/// 用真實照片量測速度（需要 BLUEVIEW_PHOTOS）
final class SpeedTests: XCTestCase {
    func testOpenSpeedOnRealPhotos() throws {
        guard let path = ProcessInfo.processInfo.environment["BLUEVIEW_PHOTOS"] else { throw XCTSkip("BLUEVIEW_PHOTOS not set") }
        let files = FolderScanner.sorted(FolderScanner.images(in: URL(fileURLWithPath: path)), by: .name, ascending: true).prefix(40)
        var thumb: [Double] = [], screen: [Double] = []
        for f in files {
            var s = Date(); _ = ThumbnailLoader.makeThumbnail(f.url, maxSide: 360); thumb.append(Date().timeIntervalSince(s) * 1000)
            s = Date(); _ = ImagePipeline.decode(f.url, maxSide: 2560); screen.append(Date().timeIntervalSince(s) * 1000)
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        print(String(format: "SPEED thumbnail360 median %.1f ms, screen2560 median %.1f ms (n=%d)", median(thumb), median(screen), files.count))
    }
}

@MainActor
final class FileTypeIconTests: XCTestCase {
    func testIconsForCommonFormatsAreCachedPerExtension() {
        let jpg = FileTypeIcon.icon(for: URL(fileURLWithPath: "/tmp/a.JPG"))
        let jpg2 = FileTypeIcon.icon(for: URL(fileURLWithPath: "/tmp/b.jpg"))
        XCTAssertTrue(jpg === jpg2, "同一種副檔名要共用同一個圖示（不分大小寫）")
        for ext in ["png", "heic", "cr3", "nef", "tif"] {
            let icon = FileTypeIcon.icon(for: URL(fileURLWithPath: "/tmp/x.\(ext)"))
            XCTAssertGreaterThan(icon.size.width, 0, ext)
        }
        XCTAssertFalse(FileTypeIcon.icon(for: URL(fileURLWithPath: "/tmp/x.png")) === jpg, "不同格式應該是不同的圖示")
    }
}

@MainActor
final class ListModeTests: XCTestCase {
    func testAllEntriesIncludeNonImagesWithFoldersFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bv-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Zoo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.jpeg(width: 10, height: 10).write(to: dir.appendingPathComponent("b.jpg"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("a-notes.txt"))
        try Data("%PDF".utf8).write(to: dir.appendingPathComponent("c.pdf"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))

        let entries = FolderScanner.allEntries(in: dir)
        XCTAssertEqual(entries.map(\.name), ["Zoo", "a-notes.txt", "b.jpg", "c.pdf"], "資料夾在最前面，非圖片也要列出，隱藏檔不列")
        XCTAssertTrue(entries[0].isFolder)
        XCTAssertEqual(entries.filter(\.isImage).map(\.name), ["b.jpg"])
        XCTAssertFalse(entries[1].kind.isEmpty)
    }

    func testModeSwitchingReturnsToPreviousBrowseMode() {
        let model = AppModel()
        model.setBrowseMode(.list)
        XCTAssertEqual(model.mode, .list)
        model.mode = .viewer
        model.closeViewer()
        XCTAssertEqual(model.mode, .list, "從單張返回時要回到列表")
        model.setBrowseMode(.grid)
        XCTAssertEqual(model.mode, .grid)
    }
}

/// 真實相機 RAW 轉 JPEG（需要 BLUEVIEW_RAW 指向 RAW 資料夾；輸出只寫到暫存資料夾）
final class RealRawConvertTests: XCTestCase {
    func testConvertRealRawWithBothEngines() throws {
        guard let path = ProcessInfo.processInfo.environment["BLUEVIEW_RAW"] else { throw XCTSkip("BLUEVIEW_RAW not set") }
        let raws = FolderScanner.images(in: URL(fileURLWithPath: path)).map(\.url).filter(ImageFormats.isRaw).prefix(5)
        XCTAssertFalse(raws.isEmpty)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bv-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        for engine in RawEngine.allCases {
            var options = ConvertOptions()
            options.rawEngine = engine
            options.minPreviewSide = 0
            for src in raws {
                let dest = Converter.destination(for: src, in: out.appendingPathComponent(engine.rawValue), format: .jpeg)
                let start = Date()
                let outcome = try Converter.convert(src, to: dest, options: options)
                let ms = Date().timeIntervalSince(start) * 1000
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(dest as CFURL, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                XCTAssertGreaterThan(max(w, h), 1000, src.lastPathComponent)
                XCTAssertNotNil(tiff?[kCGImagePropertyTIFFModel], "相機型號要保留")
                XCTAssertNotNil(exif?[kCGImagePropertyExifDateTimeOriginal], "拍攝時間要保留")
                print(String(format: "RAW %@ %@ → %dx%d %.0f ms %@", engine.rawValue, src.lastPathComponent, w, h, ms, String(describing: outcome)))
            }
        }
    }
}
