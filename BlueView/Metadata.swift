import CoreLocation
import Foundation
import ImageIO

/// 照片資訊（EXIF 等）整理成可以顯示的欄位
struct PhotoInfo {
    struct Row: Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    var camera = ""
    var lens = ""
    var exposure = ""        // 1/250 s · f/2.8 · ISO 400
    var focal = ""
    var dateTaken = ""
    var dimensions = ""
    var fileSize = ""
    var format = ""
    var colorProfile = ""
    var location: CLLocationCoordinate2D?
    var altitude: String?
    var rating: Int?
    /// 所有原始資訊（進階檢視）
    var allRows: [Row] = []

    var mainRows: [Row] {
        [
            Row(label: tr("Camera", "相機"), value: camera),
            Row(label: tr("Lens", "鏡頭"), value: lens),
            Row(label: tr("Exposure", "曝光"), value: exposure),
            Row(label: tr("Focal length", "焦距"), value: focal),
            Row(label: tr("Date taken", "拍攝時間"), value: dateTaken),
            Row(label: tr("Dimensions", "尺寸"), value: dimensions),
            Row(label: tr("File size", "檔案大小"), value: fileSize),
            Row(label: tr("Format", "格式"), value: format),
            Row(label: tr("Color profile", "色彩描述檔"), value: colorProfile),
        ].filter { !$0.value.isEmpty }
    }
}

enum MetadataReader {
    /// 快門：0.004 → 1/250，2.5 → 2.5″
    static func shutter(_ t: Double) -> String {
        guard t > 0 else { return "" }
        if t >= 1 { return String(format: t == t.rounded() ? "%.0f″" : "%.1f″", t) }
        let denominator = (1 / t).rounded()
        return "1/\(Int(denominator))"
    }

    static func aperture(_ f: Double) -> String {
        f == f.rounded() ? String(format: "f/%.0f", f) : String(format: "f/%.1f", f)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func read(_ url: URL) -> PhotoInfo {
        var info = PhotoInfo()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        info.fileSize = fileSize(bytes)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return info }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let exifAux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
        info.camera = model.lowercased().hasPrefix(make.split(separator: " ").first?.lowercased() ?? "\u{0}") || make.isEmpty ? model : "\(make) \(model)"
        info.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String) ?? ""

        var exposure: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double { exposure.append(shutter(t) + " s") }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(aperture(f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 { exposure.append(String(format: "%+.1f EV", bias)) }
        info.exposure = exposure.joined(separator: " · ")

        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            info.focal = String(format: "%.0f mm", focal)
            if let eq = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, Double(eq) != focal.rounded() {
                info.focal += tr("  (\(eq) mm in 35 mm)", "（等效 \(eq) mm）")
            }
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = input.date(from: String(date.prefix(19))) {
                info.dateTaken = d.formatted(date: .abbreviated, time: .standard)
            } else {
                info.dateTaken = date
            }
        }
        let size = ImagePipeline.pixelSize(url)
        if size.width > 0 {
            let mp = size.width * size.height / 1_000_000
            info.dimensions = String(format: "%.0f × %.0f (%.1f MP)", size.width, size.height, mp)
        }
        if let type = CGImageSourceGetType(src) as String? {
            info.format = url.pathExtension.uppercased() + (ImageFormats.isRaw(url) ? " RAW" : "")
            _ = type
        }
        info.colorProfile = p[kCGImagePropertyProfileName] as? String ?? ""
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            info.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { info.altitude = String(format: "%.0f m", alt) }
        }
        if let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any], let r = iptc[kCGImagePropertyIPTCStarRating] as? Int { info.rating = r }

        // 進階：所有欄位攤平
        var rows: [PhotoInfo.Row] = []
        func flatten(_ dict: [CFString: Any], prefix: String) {
            for (k, v) in dict.sorted(by: { ($0.key as String) < ($1.key as String) }) {
                let key = prefix.isEmpty ? k as String : "\(prefix).\(k)"
                if let sub = v as? [CFString: Any] { flatten(sub, prefix: key) }
                else if let data = v as? Data { rows.append(.init(label: key, value: "\(data.count) bytes")) }
                else if let arr = v as? [Any] { rows.append(.init(label: key, value: arr.map { "\($0)" }.joined(separator: ", "))) }
                else { rows.append(.init(label: key, value: "\(v)")) }
            }
        }
        flatten(p, prefix: "")
        info.allRows = rows
        return info
    }
}
