import MapKit
import SwiftUI

/// 右側：照片資訊（EXIF）
struct InspectorView: View {
    let model: AppModel
    @State private var info: PhotoInfo?
    @State private var showAll = false

    var body: some View {
        ScrollView {
            if let file = model.focusedFile, let info {
                VStack(alignment: .leading, spacing: 14) {
                    Text(file.name).font(.headline).lineLimit(2).textSelection(.enabled)
                    if let rating = info.rating, rating > 0 {
                        HStack(spacing: 2) {
                            ForEach(0..<5) { Image(systemName: $0 < rating ? "star.fill" : "star").foregroundStyle(.yellow) }
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        ForEach(info.mainRows) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)

                    if let location = info.location {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Location", "拍攝地點")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Map(initialPosition: .region(MKCoordinateRegion(center: location, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                                Marker(file.name, coordinate: location)
                            }
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .id(file.url)
                            HStack {
                                Text(String(format: "%.5f, %.5f", location.latitude, location.longitude)).font(.caption.monospacedDigit()).textSelection(.enabled)
                                if let alt = info.altitude { Text(alt).font(.caption) }
                                Spacer()
                                Button(tr("Open in Maps", "在地圖開啟")) {
                                    let item = MKMapItem(placemark: MKPlacemark(coordinate: location))
                                    item.name = file.name
                                    item.openInMaps()
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                        }
                    }

                    DisclosureGroup(tr("All metadata (\(info.allRows.count))", "全部資訊（\(info.allRows.count) 項）"), isExpanded: $showAll) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(info.allRows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top) {
                                    Text(row.label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).lineLimit(2)
                                    Text(row.value).textSelection(.enabled).lineLimit(4)
                                }
                                .font(.caption.monospaced())
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)

                    HStack {
                        Button(tr("Show in Finder", "在 Finder 顯示"), action: model.revealInFinder)
                        Button(tr("Open With…", "用其他 App 開啟"), action: model.openWithDefaultApp)
                    }
                    .controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(tr("No photo selected", "尚未選擇照片"), systemImage: "info.circle")
                    .padding(.top, 60)
            }
        }
        .background(.background.secondary)
        .task(id: model.focused) {
            guard let url = model.focused else { info = nil; return }
            info = await Task.detached(priority: .userInitiated) { MetadataReader.read(url) }.value
        }
    }
}
