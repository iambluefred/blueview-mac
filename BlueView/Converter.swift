import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 轉檔的輸出格式
enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, heic, png, tiff
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: tr("PNG (lossless)", "PNG（無損）")
        case .tiff: tr("TIFF (lossless)", "TIFF（無損）")
        }
    }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        case .tiff: "tif"
        }
    }
    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        case .tiff: .tiff
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic }
}

/// RAW 的轉檔方式
enum RawEngine: String, Codable, CaseIterable, Identifiable {
    case embeddedPreview, appleRaw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .embeddedPreview: tr("Embedded preview (fastest)", "內嵌預覽圖（最快）")
        case .appleRaw: tr("Apple RAW engine (best quality)", "Apple RAW 引擎（畫質最好）")
        }
    }
}

struct ConvertOptions: Codable, Equatable {
    var format: OutputFormat = .jpeg
    var quality: Double = 0.9
    /// 長邊上限；0 = 原尺寸
    var maxSide = 0
    var keepExif = true
    var keepGPS = true
    var rawEngine: RawEngine = .embeddedPreview
    /// 內嵌預覽圖小於這個尺寸時改用 Apple RAW
    var minPreviewSide = 2000
    var overwrite = false
    var outputPath = ""
}

enum ConvertError: LocalizedError {
    case cannotRead, noPreview, failed(String)
    var errorDescription: String? {
        switch self {
        case .cannotRead: tr("Cannot read the file", "無法讀取檔案")
        case .noPreview: tr("No embedded preview found", "找不到內嵌預覽圖")
        case .failed(let s): tr("Conversion failed: \(s)", "轉檔失敗：\(s)")
        }
    }
}

enum Converter {
    enum Outcome: Equatable {
        case converted(note: String?)
        case skipped
    }

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func destination(for src: URL, in folder: URL, format: OutputFormat) -> URL {
        folder.appendingPathComponent(src.deletingPathExtension().lastPathComponent).appendingPathExtension(format.fileExtension)
    }

    /// 轉一張
    static func convert(_ src: URL, to dest: URL, options o: ConvertOptions) throws -> Outcome {
        let fm = FileManager.default
        if !o.overwrite, fm.fileExists(atPath: dest.path), ((try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0) > 0 {
            return .skipped
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw ConvertError.cannotRead }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(o.format.fileExtension)")
        defer { try? fm.removeItem(at: tmp) }

        var note: String?
        if ImageFormats.isRaw(src) {
            note = try convertRaw(src, props: props, to: tmp, options: o)
        } else {
            guard let image = decode(source, maxSide: o.maxSide) else { throw ConvertError.cannotRead }
            try encode(image, props: props, orientation: 1, to: tmp, options: o)  // 解碼時已經轉正
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return .converted(note: note)
    }

    /// 解碼並轉正；maxSide = 0 為原尺寸
    static func decode(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let longSide = max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let target = maxSide > 0 ? min(maxSide, longSide) : longSide
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ] as CFDictionary)
    }

    private static func convertRaw(_ src: URL, props: [CFString: Any], to tmp: URL, options o: ConvertOptions) throws -> String? {
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if o.rawEngine == .embeddedPreview, let preview = try? largestEmbeddedJPEG(src) {
            let longSide = max(preview.width, preview.height)
            if longSide >= o.minPreviewSide {
                let needsResize = o.maxSide > 0 && longSide > o.maxSide
                if o.format == .jpeg && !needsResize {
                    // 原封不動複製預覽圖，只換上 RAW 的資訊
                    try writeJPEGLossless(preview.data, props: props, orientation: orientation, to: tmp, options: o)
                } else {
                    guard let s = CGImageSourceCreateWithData(preview.data as CFData, nil), let image = decode(s, maxSide: o.maxSide) else {
                        throw ConvertError.noPreview
                    }
                    try encode(image, props: props, orientation: orientation, to: tmp, options: o)
                }
                return nil
            }
            try developWithApple(src, props: props, to: tmp, options: o)
            return tr("preview only \(longSide) px, used Apple RAW", "預覽圖只有 \(longSide) px，改用 Apple RAW")
        }
        try developWithApple(src, props: props, to: tmp, options: o)
        return o.rawEngine == .embeddedPreview ? tr("no embedded preview, used Apple RAW", "沒有內嵌預覽圖，改用 Apple RAW") : nil
    }

    static func developWithApple(_ src: URL, props: [CFString: Any], to tmp: URL, options o: ConvertOptions) throws {
        guard let filter = CIRAWFilter(imageURL: src) else { throw ConvertError.failed(tr("RAW format not supported by macOS", "macOS 不支援這個 RAW 格式")) }
        if o.maxSide > 0 {
            let longSide = max(filter.nativeSize.width, filter.nativeSize.height)
            if longSide > CGFloat(o.maxSide) { filter.scaleFactor = Float(CGFloat(o.maxSide) / longSide) }
        }
        guard let image = filter.outputImage,
              let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConvertError.failed("Core Image")
        }
        try encode(cg, props: props, orientation: 1, to: tmp, options: o)
    }

    // MARK: - 內嵌預覽圖（與 PhotoSel 相同）

    struct EmbeddedJPEG {
        let data: Data
        let width: Int
        let height: Int
    }

    static func largestEmbeddedJPEG(_ url: URL) throws -> EmbeddedJPEG {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var best: EmbeddedJPEG?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            while i + 4 < n {
                if p[i] == 0xFF && p[i + 1] == 0xD8 && p[i + 2] == 0xFF && [0xDB, 0xE0, 0xE1, 0xC4, 0xEE, 0xC0].contains(p[i + 3]) {
                    let slice = data.subdata(in: i..<n)
                    if let s = CGImageSourceCreateWithData(slice as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let pr = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
                       let w = pr[kCGImagePropertyPixelWidth] as? Int, let h = pr[kCGImagePropertyPixelHeight] as? Int,
                       w * h > (best.map { $0.width * $0.height } ?? 0) {
                        let end = jpegEnd(p, start: i) ?? n
                        best = EmbeddedJPEG(data: data.subdata(in: i..<end), width: w, height: h)
                    }
                }
                i += 1
            }
        }
        guard let best else { throw ConvertError.noPreview }
        return best
    }

    static func jpegEnd(_ p: UnsafeBufferPointer<UInt8>, start: Int) -> Int? {
        var i = start + 2
        let n = p.count
        while i + 4 < n {
            guard p[i] == 0xFF else { return nil }
            let marker = p[i + 1]
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            let length = Int(p[i + 2]) << 8 | Int(p[i + 3])
            if marker == 0xDA {
                var j = i + 2 + length
                while j + 1 < n {
                    if p[j] == 0xFF && p[j + 1] == 0xD9 { return j + 2 }
                    j += 1
                }
                return nil
            }
            i += 2 + length
        }
        return nil
    }

    // MARK: - 資訊與寫檔

    /// 依選項挑出要保留的資訊
    static func metadata(_ props: [CFString: Any], orientation: Int, options o: ConvertOptions) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if o.keepExif {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
                if var dict = props[key] as? [CFString: Any] {
                    if key == kCGImagePropertyTIFFDictionary { dict.removeValue(forKey: kCGImagePropertyTIFFOrientation) }
                    if key == kCGImagePropertyExifDictionary {
                        dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                        dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                    }
                    out[key] = dict
                }
            }
        }
        if o.keepGPS, let gps = props[kCGImagePropertyGPSDictionary] { out[kCGImagePropertyGPSDictionary] = gps }
        out[kCGImagePropertyOrientation] = orientation
        return out
    }

    static func makeMetadata(_ props: [CFString: Any]) -> CGMutableImageMetadata {
        let m = CGImageMetadataCreateMutable()
        for (dictKey, value) in props {
            if let dict = value as? [CFString: Any] {
                for (k, v) in dict { CGImageMetadataSetValueMatchingImageProperty(m, dictKey, k, v as CFTypeRef) }
            } else if dictKey == kCGImagePropertyOrientation {
                CGImageMetadataSetValueMatchingImageProperty(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, value as CFTypeRef)
            }
        }
        return m
    }

    /// 不重新壓縮：只把資訊換掉
    static func writeJPEGLossless(_ jpeg: Data, props: [CFString: Any], orientation: Int, to url: URL, options o: ConvertOptions) throws {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { throw ConvertError.cannotRead }
        var copyOptions: [CFString: Any] = [kCGImageDestinationMergeMetadata: false,
                                            kCGImageDestinationMetadata: makeMetadata(metadata(props, orientation: orientation, options: o))]
        if !o.keepGPS { copyOptions[kCGImageMetadataShouldExcludeGPS] = true }
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil),
           CGImageDestinationCopyImageSource(dest, source, copyOptions as CFDictionary, nil) {
            return
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConvertError.cannotRead }
        try encode(image, props: props, orientation: orientation, to: url, options: o)
    }

    static func encode(_ image: CGImage, props: [CFString: Any], orientation: Int, to url: URL, options o: ConvertOptions) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, o.format.utType.identifier as CFString, 1, nil) else {
            throw ConvertError.failed(o.format.label)
        }
        var out = metadata(props, orientation: orientation, options: o)
        if o.format.isLossy { out[kCGImageDestinationLossyCompressionQuality] = o.quality }
        CGImageDestinationAddImage(dest, image, out as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed(o.format.label) }
    }
}
