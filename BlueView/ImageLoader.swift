import AppKit
import ImageIO

/// 縮圖：背景讀取、快取。小縮圖優先用檔案內嵌的縮圖（最快）。
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        q.qualityOfService = .userInitiated
        return q
    }()

    init() { cache.countLimit = 2000 }

    static func makeThumbnail(_ url: URL, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        // 檔案內嵌的縮圖通常 160 px；RAW 的預覽圖很大。要求不大時用內嵌的，否則從原圖縮
        if maxSide <= 160 || ImageFormats.isRaw(url) {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    func thumbnail(_ url: URL, maxSide: Int) async -> NSImage? {
        let key = "\(maxSide)|\(url.path)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                guard let cg = Self.makeThumbnail(url, maxSide: maxSide) else { return continuation.resume(returning: nil) }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.cache.setObject(image, forKey: key as NSString)
                continuation.resume(returning: image)
            }
        }
    }
}

/// 看圖用的解碼結果
struct DecodedImage {
    let image: CGImage
    let pixelSize: CGSize      // 原圖尺寸
    let isFullResolution: Bool
    let milliseconds: Double   // 解碼花的時間
}

/// 看圖：依螢幕大小解碼，並預先載入前後幾張，讓切換下一張幾乎不用等
actor ImagePipeline {
    static let shared = ImagePipeline()

    private var cache: [URL: DecodedImage] = [:]
    private var order: [URL] = []        // 最近使用的在最後
    private var inFlight: [URL: Task<DecodedImage?, Never>] = [:]
    private let capacity = 12

    /// 螢幕大小（像素）的最長邊
    static var screenMaxSide: Int {
        let size = NSScreen.screens.map { $0.frame.size.applying(CGAffineTransform(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
        return Int(size.map { max($0.width, $0.height) }.max() ?? 2560)
    }

    static func pixelSize(_ url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return .zero }
        var w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }  // 轉 90° 的照片
        return CGSize(width: w, height: h)
    }

    /// 解碼：maxSide = nil 表示原始解析度
    static func decode(_ url: URL, maxSide: Int?) -> DecodedImage? {
        let start = Date()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let full = pixelSize(url)
        let longSide = Int(max(full.width, full.height))
        let target = maxSide.map { min($0, longSide) } ?? longSide
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if ImageFormats.isRaw(url) && maxSide != nil {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true  // RAW 先用內嵌預覽，很快
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let ms = Date().timeIntervalSince(start) * 1000
        let isFull = max(image.width, image.height) >= longSide
        return DecodedImage(image: image, pixelSize: full, isFullResolution: isFull, milliseconds: ms)
    }

    func image(_ url: URL, fullResolution: Bool = false) async -> DecodedImage? {
        if let cached = cache[url], !fullResolution || cached.isFullResolution {
            touch(url)
            return cached
        }
        let key = fullResolution ? url.appendingPathExtension("full") : url
        if let task = inFlight[key] { return await task.value }
        let maxSide: Int? = fullResolution ? nil : Self.screenMaxSide
        let task = Task.detached(priority: .userInitiated) { Self.decode(url, maxSide: maxSide) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { store(url, result) }
        return result
    }

    /// 預先解碼前後幾張
    func prefetch(_ urls: [URL]) {
        for url in urls where cache[url] == nil && inFlight[url] == nil {
            let task = Task.detached(priority: .utility) { Self.decode(url, maxSide: Self.screenMaxSide) }
            inFlight[url] = task
            Task {
                let result = await task.value
                self.finishPrefetch(url, result)
            }
        }
    }

    private func finishPrefetch(_ url: URL, _ result: DecodedImage?) {
        inFlight[url] = nil
        if let result, cache[url] == nil { store(url, result) }
    }

    func isCached(_ url: URL) -> Bool { cache[url] != nil }

    private func store(_ url: URL, _ image: DecodedImage) {
        cache[url] = image
        touch(url)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }
}
