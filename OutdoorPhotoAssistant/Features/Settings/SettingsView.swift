import SwiftUI

struct SettingsView: View {
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("autoReview") private var autoReview = true
    @AppStorage("autoScene") private var autoScene = true
    @AppStorage("autoFilter") private var autoFilter = true
    @AppStorage("autoComposition") private var autoComposition = true
    @AppStorage("autoCapture") private var autoCapture = false
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("highQuality") private var highQuality = false

    var body: some View {
        NavigationStack {
            Form {
                Section("拍摄助手") {
                    Toggle("自动识别场景", isOn: $autoScene)
                    Toggle("自动取景 / 自动选镜头", isOn: $autoComposition)
                    Toggle("根据场景自动滤镜", isOn: $autoFilter)
                    Toggle("构图达标后自动拍摄", isOn: $autoCapture)
                    Toggle("保存原片 + 成片", isOn: $saveBoth)
                    Toggle("最高画质（更大照片尺寸）", isOn: $highQuality)
                }

                Section("取景") {
                    Toggle("显示三分线", isOn: $showGrid)
                    Toggle("拍完自动复盘", isOn: $autoReview)
                }

                Section("说明") {
                    Text("AI 导演会持续分析人物、主体、场景、亮度、显著区域、水平状态和稳定度，并给出移动手机、留白、镜头、光线和色彩建议。")
                    Text("曝光只做曝光补偿，不会关闭系统自动曝光；iPhone 的物理光圈是固定的，本版本不再尝试改变光圈。")
                    Text("保存时会保留原片的 EXIF / 深度信息；成片是重新渲染后的 JPEG。")
                    Text("全部分析在设备端完成，不联网、不上传任何照片。")
                }

                Section("关于") {
                    LabeledContent("版本") {
                        Text("1.0 · iOS 17.6+")
                    }
                    LabeledContent("构建") {
                        Text("离线 · 无第三方 SDK")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
