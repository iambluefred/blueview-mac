# BlueView

快速看圖的 Mac App（仿 Lyn 的第一版）：瀏覽、看圖、EXIF、轉檔。約 4 MB（Lyn 約 102 MB）。

## 功能

| 功能 | 說明 |
| --- | --- |
| 瀏覽 | 側邊欄常用位置、外接磁碟、子資料夾；上一頁／下一頁／上一層；縮圖大小可調；依名稱（自然排序）、日期、大小排序；可把資料夾拖進視窗 |
| 看圖 | 雙擊、Return 或空白鍵開圖；← → 切換；Esc 返回；⌘0 符合視窗、⌘1 100%、⌘＋／⌘－、觸控板縮放；放大超過螢幕解析度時自動載入原圖 |
| 快 | 依螢幕大小解碼；**預先載入前後兩張**，切換下一張只要幾毫秒；畫面下方顯示開圖時間 |
| EXIF | 相機、鏡頭、快門／光圈／ISO／曝光補償、焦距（含等效焦距）、拍攝時間、尺寸、色彩描述檔、評分、GPS 地圖（可在「地圖」開啟），以及全部原始資訊 |
| 旋轉 | 向左 ⌘L／向右 ⌘R（工具列、右鍵選單、「圖片」選單）。JPEG／HEIC／TIFF 只改方向標記、不重新壓縮；PNG／BMP 旋轉像素（無損）；RAW 不修改。**⌘Z 還原、⇧⌘Z 重做** |
| 列表模式 | 工具列「縮圖／列表／單張」。列表顯示資料夾裡**所有檔案**（含 PDF、影片、文件等非圖片），欄位：名稱（含檔案圖示）、種類、大小、修改日期，點標題排序，資料夾在最前面；點兩下：資料夾進入、照片開單張、其他檔案用預設 App 開啟 |
| 視窗與欄寬 | 左側資料夾欄、右側資訊欄可**拖曳分隔線**調整寬度（雙擊恢復預設，會記住設定）；列表各欄可拖曳標題調整；視窗最小 640×420，太窄時自動收起兩側；「視窗」選單：符合螢幕 ⌥⌘F、大／中／小尺寸（不會超出螢幕） |
| 檔案圖示 | 縮圖格、看圖畫面、資訊面板的檔名旁顯示檔案類型圖示（JPEG、PNG、HEIC、RAW…） |
| 資料夾 | 縮圖格最前面列出子資料夾（macOS 真實圖示，含自訂圖示），點兩下進入；側邊欄也用真實圖示 |
| 轉檔 | 選取的照片轉成 JPEG／HEIC／PNG／TIFF；品質、尺寸（原尺寸／4096／2048／1024）、保留拍攝資訊與 GPS；RAW 可用內嵌預覽圖（存原尺寸 JPEG 時不重新壓縮）或 Apple RAW 引擎 |
| 格式 | JPEG、HEIC、PNG、TIFF、GIF、WebP、BMP 以及各家 RAW（CR3、CR2、NEF、ARW、DNG、RAF、ORF、RW2…，依 macOS 支援） |
| 介面 | 繁體中文／English（顯示方式 → 語言） |

## 速度（實測：iPhone 2400 萬像素 JPEG，M 系列 MacBook Air）

| 動作 | 中位數 |
| --- | --- |
| 縮圖（360 px） | 約 29 ms |
| 開圖（螢幕大小） | 約 28 ms（PNG 截圖約 150 ms） |
| 切換到已預先載入的下一張 | 約 8 ms |

## 建置

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project BlueView.xcodeproj -scheme BlueView -configuration Release -derivedDataPath build.noindex build
ditto build.noindex/Build/Products/Release/BlueView.app /Applications/BlueView.app
```

測試（`BLUEVIEW_PHOTOS` 可選，用來量真實照片的速度）：

```bash
TEST_RUNNER_BLUEVIEW_PHOTOS=~/Pictures xcodebuild -project BlueView.xcodeproj -scheme BlueView \
  -configuration Release ENABLE_TESTABILITY=YES -derivedDataPath build.noindex test
```

## 提交前檢查

每次提交前會自動檢查有沒有金鑰、密碼或敏感檔案（`.githooks/pre-commit`）。重新 clone 之後要先執行一次：

```bash
git config core.hooksPath .githooks
```
