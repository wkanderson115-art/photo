import SwiftUI

struct SettingsView: View {
    var isPresentedModally = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoDirector") private var autoDirector = true
    @AppStorage("directorLearning") private var directorLearning = true
    @AppStorage("directorFraming") private var directorFraming = "自动"
    @AppStorage("directorComposition") private var directorComposition = "自动"
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("autoReview") private var autoReview = true
    @AppStorage("autoScene") private var autoScene = true
    @AppStorage("autoFilter") private var autoFilter = true
    @AppStorage("autoComposition") private var autoComposition = true
    @AppStorage("autoZoom") private var autoZoom = true
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("exportToSystemAlbum") private var exportToSystemAlbum = false
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("portraitDepth") private var portraitDepth = false
    @AppStorage("highQuality") private var highQuality = true
    @AppStorage("manualScene") private var manualScene = "风景"
    @AppStorage("manualFilter") private var manualFilterName = "自然"
    @AppStorage("compositionStyle") private var compositionStyle = "自然"
    @AppStorage("realtimeEffects") private var realtimeEffects = true
    @AppStorage("liveBeauty") private var liveBeauty = true
    @AppStorage("liveBeautyStrength") private var liveBeautyStrength = 0.16
    @AppStorage("filterStrength") private var filterStrength = 0.55

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("把画面留给风景").font(.title2.bold())
                        Text("偏好在这里设置，拍摄时保持专注。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section {
                    Toggle("AI导演自动决策", isOn: $autoDirector)
                    Toggle("根据我的反馈调整", isOn: $directorLearning)
                    Picker("取景目标", selection: $directorFraming) {
                        ForEach(["自动", "环境", "完整人物", "突出主体"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("构图偏好", selection: $directorComposition) {
                        ForEach(["自动", "居中", "三分"], id: \.self) { Text($0).tag($0) }
                    }
                    NavigationLink("导演知识、决策与学习记录") { DirectorStatusView() }
                } header: { Text("AI导演") } footer: {
                    Text("导演在后台分析并执行，不在拍摄页堆叠提示。偏好来自明确反馈，视觉识别模型不在本机重新训练。")
                }
                Section("云端图片服务") {
                    NavigationLink("云端服务 · API Key与上传说明") { CloudAPISettingsView() }
                    Text("拍照自动存入本机图库；在图库逐张选择看图建议或云端修图，不自动上传或进行云端处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("智能拍摄") {
                    Toggle("自动识别场景", isOn: $autoScene)
                    if !autoScene {
                        Picker("拍摄场景", selection: $manualScene) {
                            ForEach(["人物", "风景", "建筑", "日落", "夜景", "花草", "海边", "汽车", "自拍"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("自动取景", isOn: $autoComposition)
                    Toggle("自动变焦", isOn: $autoZoom).disabled(!autoComposition || !autoDirector)
                    Toggle("构图达标后自动拍摄", isOn: $autoCapture)
                }
                Section {
                    Toggle("实时预览效果", isOn: $realtimeEffects)
                    Toggle("自然人像美颜", isOn: $liveBeauty)
                    if liveBeauty {
                        Slider(value: $liveBeautyStrength, in: 0...0.30) { Text("磨皮强度") }
                        Text("仅在人脸区域轻柔处理，保护眼唇和纹理；不默认改变脸型。低分辨率预览与原尺寸成片可能有轻微差异。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("自动匹配滤镜", isOn: $autoFilter)
                    if !autoFilter {
                        Picker("滤镜", selection: $manualFilterName) {
                            ForEach(PhotoFilter.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("滤镜强度"); Spacer(); Text("\(Int(filterStrength * 100))%").foregroundStyle(.secondary) }
                        Slider(value: $filterStrength, in: 0...1)
                    }
                    Picker("成片风格", selection: $compositionStyle) {
                        ForEach(["自然", "电影", "主体"], id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("色彩与风格") } footer: {
                    Text("实时预览与成片共用美颜和调色顺序；预览最高15帧/秒并丢弃积压帧，不降低照片尺寸。滤镜强度为零时不应用调色。")
                }
                Section("画质与保存") {
                    Toggle("最高照片尺寸", isOn: $highQuality)
                    Toggle("采集人像深度", isOn: $portraitDepth)
                    if portraitDepth {
                        Text("深度模式可能缩小系统允许的变焦范围；需要全范围变焦时请关闭此项。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("拍照后同时导出到系统相册", isOn: $exportToSystemAlbum)
                    if exportToSystemAlbum { Toggle("导出时同时保存原片", isOn: $saveBoth) }
                    Text("App图库始终保留原片；本地和AI成片作为不同版本保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("拍完进入复盘", isOn: $autoReview)
                }
                Section {
                    Toggle("三分网格", isOn: $showGrid)
                } header: { Text("取景辅助") } footer: {
                    Text("拍摄页不显示功能开启状态、分析评分或常驻导演提示。")
                }
                Section("摄影学院") {
                    LabeledContent("课程", value: "24节 · 7个主题")
                    Text("包含原理、实拍练习、常见误区和验收方法；拍摄教练按最近拍摄指标提供本地建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于与许可") {
                    LabeledContent("版本", value: "1.1 (build 12)")
                    Text("实时拍摄分析在本机完成；图库中的DeepSeek建议和Seedream修图按需联网调用。")
                    Text("固定光圈机型通过自动快门、ISO和曝光补偿适应光线。本版未实现可变物理光圈控制。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Smartcrop · MIT 开源许可") {
                        Text(DirectorLicenses.smartcrop).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("KalmanFilter · MIT 开源许可") {
                        Text(DirectorLicenses.kalman).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("CainCamera · Apache 2.0 开源许可") {
                        Text("高反差保留与强度混合公式已移植到 Core Image；未接入 Android / Face++ SDK。")
                        Text(CainBeautyKernels.licenseText).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("NextLevel · MIT 开源许可") {
                        Text(NextLevelDeviceControls.licenseText).font(.caption).textSelection(.enabled)
                    }
                }
            }.navigationTitle("拍摄设置")
                .toolbar {
                    if isPresentedModally {
                        ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                    }
                }
                .tint(.mint)
        }
    }
}


struct DirectorStatusView: View {
    @EnvironmentObject var analyzer: FrameAnalyzer
    @State private var feedbackCount = 0
    @State private var resetConfirmation = false
    var body: some View {
        List {
            Section("当前能力") {
                Text("视觉识别 + 摄影规则 + 候选构图评分 + 明确反馈形成的本地偏好。")
                Text("已记录 \(feedbackCount) 次反馈").font(.headline)
                Text("至少3次同类反馈后应用；不同场景、人脸/人体与合影分别记录。不会自动下载网络文章或在本机训练摄影大模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(DirectorKnowledge.domains.indices, id: \.self) { i in
                Section(DirectorKnowledge.domains[i].name) {
                    Text(DirectorKnowledge.domains[i].principles)
                }
            }
            Section("最近一次导演决策") {
                if analyzer.directorDecision.evidence.isEmpty {
                    Text("先打开相机，让导演获得可靠画面。")
                }
                ForEach(Array(analyzer.directorDecision.evidence.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.rule).font(.headline)
                        Text(item.observation).font(.caption).foregroundStyle(.secondary)
                        Text(item.action).font(.subheadline)
                    }
                }
            }
            Section {
                Button("清除导演偏好记录", role: .destructive) { resetConfirmation = true }
            } footer: {
                Text("导演偏好只存场景、主体占比和滤镜统计；图库云端服务仅在你点选后上传选中的照片副本。")
            }
        }.navigationTitle("导演知识与学习")
            .onAppear { feedbackCount = DirectorPreferenceStore.shared.feedbackCount }
            .alert("清除导演偏好？", isPresented: $resetConfirmation) {
                Button("清除", role: .destructive) {
                    DirectorPreferenceStore.shared.reset()
                    feedbackCount = 0
                }
                Button("取消", role: .cancel) { }
            } message: { Text("将删除本机积累的取景和滤镜偏好，课程进度与照片不受影响。") }
    }
}
