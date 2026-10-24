import SwiftUI

/// Personal-key direct access: no application server, no Apple cloud login.
struct CloudAPISettingsView: View {
    @State private var deepSeekKey = ""
    @State private var seedreamKey = ""
    @State private var hasDeepSeekKey = false
    @State private var hasSeedreamKey = false
    @State private var status: String?
    @AppStorage("cloudUseDeepSeekFirst") private var useDeepSeekFirst = true
    @AppStorage("seedreamModel") private var seedreamModel = CloudConfiguration.seedreamDefault
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("直接连接模型平台，无需服务器月租；模型按实际使用计费。")
                    .font(.subheadline).foregroundStyle(AppTheme.muted)
                keyCard(title: "DeepSeek", subtitle: "看图识别与自然修图建议", key: $deepSeekKey, configured: hasDeepSeekKey, provider: .deepseek)
                keyCard(title: "Seedream", subtitle: "照片精修 · 火山方舟 Key", key: $seedreamKey, configured: hasSeedreamKey, provider: .seedream)
                if let status { Text(status).font(.footnote).foregroundStyle(AppTheme.ink).appCard() }
                Toggle("默认先查看 DeepSeek 建议", isOn: $useDeepSeekFirst).tint(AppTheme.mint).appCard(tinted: true)
                Text("只有你点选照片并发起处理时才上传。建议与修图分开确认，保存Key不发送模型请求。上传副本会移除EXIF/GPS，原片保留在本机。")
                    .font(.footnote).foregroundStyle(AppTheme.muted)
                Text("Key保存在本机系统钥匙串，输入及保存后均隐藏，不显示在拍照页。直连方式无法像服务器那样隔离凭证，请使用自己的Key并设置平台额度。")
                    .font(.footnote).foregroundStyle(AppTheme.muted)
                DisclosureGroup("模型与平台") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("看图模型", value: CloudConfiguration.deepSeekDefault)
                        TextField("Seedream模型或接入点ID", text: $seedreamModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        Link("DeepSeek 开放平台", destination: URL(string: "https://platform.deepseek.com/")!)
                        Link("火山方舟控制台", destination: URL(string: "https://console.volcengine.com/ark")!)
                        Text("照片直接发送到对应平台，不经过本应用自建服务器。下载结果不附带Key；链接可能过期，请及时保存。")
                            .font(.caption).foregroundStyle(AppTheme.muted)
                    }.padding(.top, 10)
                }.appCard()
            }.padding(24)
        }.background(AppTheme.paper).navigationTitle("云端服务")
            .onAppear { refreshStatus() }
            .onDisappear { deepSeekKey = ""; seedreamKey = "" }
    }
    private func keyCard(title: String, subtitle: String, key: Binding<String>, configured: Bool, provider: APIKeyStore.Provider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(AppTheme.muted)
            Text(configured ? "已配置 · 内容隐藏" : "尚未配置").font(.caption).foregroundStyle(AppTheme.muted)
            SecureField(configured ? "输入新Key以替换" : "输入API Key", text: key)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                .padding(12).background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 10)).privacySensitive()
            Button("保存 " + title + " Key") {
                do {
                    let value = try CloudHTTP.validatedKey(key.wrappedValue, provider: title)
                    try APIKeyStore.save(value, for: provider)
                    key.wrappedValue = ""
                    refreshStatus(); status = title + " Key已保存，未发送模型请求。"
                } catch { status = error.localizedDescription }
            }.buttonStyle(AppActionStyle(primary: false))
            if configured {
                Button("删除已保存的Key", role: .destructive) {
                    do {
                        try APIKeyStore.save("", for: provider)
                        key.wrappedValue = ""; refreshStatus(); status = title + " Key已删除。"
                    } catch { status = error.localizedDescription }
                }.font(.caption)
            }
        }.appCard()
    }
    private func refreshStatus() {
        hasDeepSeekKey = !APIKeyStore.read(.deepseek).isEmpty
        hasSeedreamKey = !APIKeyStore.read(.seedream).isEmpty
    }
}
