import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 旋轉圖片。能用「方向」標記的格式只改標記（不重新壓縮）；其他無損格式旋轉像素後重存；RAW 不修改。
enum Rotator {
    enum Direction { case clockwise, counterClockwise }

    enum RotateError: LocalizedError {
        case raw, animated, unsupported, failed
        var errorDescription: String? {
            switch self {
            case .raw: tr("RAW files are not modified. Convert it first, then rotate the converted file.", "RAW 檔不會被修改。請先轉檔，再旋轉轉出來的檔案。")
            case .animated: tr("Animated images can't be rotated.", "動畫圖片無法旋轉。")
            case .unsupported: tr("This format can't be rotated.", "這個格式無法旋轉。")
            case .failed: tr("Couldn't save the rotated image.", "無法儲存旋轉後的圖片。")
            }
        }
    }

    /// EXIF 方向（1–8）順時針轉 90° 後的新方向
    static let clockwise: [Int: Int] = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
    static let counterClockwise: [Int: Int] = [1: 8, 2: 5, 3: 6, 4: 7, 5: 4, 6: 1, 7: 2, 8: 3]

    static func rotated(_ orientation: Int, _ direction: Direction) -> Int {
        (direction == .clockwise ? clockwise : counterClockwise)[orientation] ?? 1
    }

    /// 只改方向標記就能旋轉的格式
    static let orientationTypes: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.tiff.identifier]
    /// 旋轉像素後重存（無損）的格式
    static let pixelTypes: Set<String> = [UTType.png.identifier, UTType.bmp.identifier]

    /// 旋轉一個檔案；成功時檔案被原地更新
    static func rotate(_ url: URL, _ direction: Direction) throws {
        if ImageFormats.isRaw(url) { throw RotateError.raw }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? else {
            throw RotateError.failed
        }
        if CGImageSourceGetCount(source) > 1 { throw RotateError.animated }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = props[kCGImagePropertyOrientation] as? Int ?? 1

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        if orientationTypes.contains(type) {
            // 不重新壓縮：只換方向，其他資訊保留。
            // 用 kCGImageDestinationOrientation（JPEG、HEIC 都有效；只改 EXIF 標記對 HEIC 無效，兩者也不能同時用）
            var error: Unmanaged<CFError>?
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type as CFString, 1, nil),
                  CGImageDestinationCopyImageSource(dest, source, [kCGImageDestinationOrientation: rotated(current, direction)] as CFDictionary, &error) else {
                _ = error?.takeRetainedValue()
                throw RotateError.failed
            }
        } else if pixelTypes.contains(type) {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let turned = rotatePixels(image, direction),
                  let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type as CFString, 1, nil) else { throw RotateError.failed }
            var out = props
            out[kCGImagePropertyOrientation] = nil
            out[kCGImagePropertyPixelWidth] = nil
            out[kCGImagePropertyPixelHeight] = nil
            CGImageDestinationAddImage(dest, turned, out as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw RotateError.failed }
        } else {
            throw RotateError.unsupported
        }
        // 原地取代（保留檔案的建立日期等屬性）
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func rotatePixels(_ image: CGImage, _ direction: Direction) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG 座標原點在左下
        if direction == .clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
