import SwiftUI

/// 轉檔設定
struct ConvertView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var o: Binding<ConvertOptions> { $model.convertOptions }
    private var targets: [URL] { model.convertTargets }
    private var rawCount: Int { targets.filter(ImageFormats.isRaw).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(tr("Convert \(targets.count) Photos", "轉檔 \(targets.count) 張")).font(.title3.bold())
                    Text(rawCount > 0 ? tr("Including \(rawCount) RAW files. Originals are not changed.", "其中 \(rawCount) 張是 RAW。原始檔不會被修改。")
                                      : tr("Originals are not changed.", "原始檔不會被修改。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 18)

            Form {
                Section(tr("Format", "格式")) {
                    Picker(tr("Save as", "存成"), selection: o.format) {
                        ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.convertOptions.format.isLossy {
                        HStack {
                            Text(tr("Quality", "品質"))
                            Slider(value: o.quality, in: 0.5...1.0, step: 0.01)
                            Text("\(Int((model.convertOptions.quality * 100).rounded()))").monospacedDigit().frame(width: 30)
                        }
                    }
                    Picker(tr("Size", "尺寸"), selection: o.maxSide) {
                        Text(tr("Original", "原尺寸")).tag(0)
                        Text(tr("Long side 4096 px", "長邊 4096 px")).tag(4096)
                        Text(tr("Long side 2048 px", "長邊 2048 px")).tag(2048)
                        Text(tr("Long side 1024 px", "長邊 1024 px")).tag(1024)
                    }
                }
                if rawCount > 0 {
                    Section(tr("RAW", "RAW")) {
                        Picker(tr("Engine", "轉檔方式"), selection: o.rawEngine) {
                            ForEach(RawEngine.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        Text(tr("Embedded preview: the JPEG the camera stored inside the RAW (copied without re-compression when saving JPEG at original size). Falls back to the Apple engine when it is smaller than \(model.convertOptions.minPreviewSide) px.",
                                "內嵌預覽圖：相機存在 RAW 裡的 JPEG（存成原尺寸 JPEG 時不重新壓縮）；小於 \(model.convertOptions.minPreviewSide) px 時自動改用 Apple 引擎。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(tr("Info", "資訊")) {
                    Toggle(tr("Keep shooting info (camera, lens, exposure, date)", "保留拍攝資訊（相機、鏡頭、曝光、時間）"), isOn: o.keepExif)
                    Toggle(tr("Keep GPS location", "保留 GPS 位置"), isOn: o.keepGPS)
                }
                Section(tr("Output", "輸出")) {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(model.convertOutputFolder?.path ?? "").lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(tr("Choose…", "選擇…"), action: model.chooseConvertOutput)
                    }
                    if !model.convertOptions.outputPath.isEmpty {
                        Button(tr("Use a “Converted” folder next to the photos", "改回照片旁邊的「Converted」資料夾")) { model.convertOptions.outputPath = "" }
                            .buttonStyle(.link)
                    }
                    Toggle(tr("Overwrite existing files", "覆蓋已存在的檔案"), isOn: o.overwrite)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                Button(tr("Convert", "開始轉檔")) {
                    dismiss()
                    model.startConvert()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: rawCount > 0 ? 640 : 520)
    }
}
