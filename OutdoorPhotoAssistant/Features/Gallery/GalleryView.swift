import SwiftUI
import UIKit

struct GalleryView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var filter = "全部照片"
    private let columns = [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]
    private var displayed: [AppPhotoRecord] {
        filter == "AI成片" ? library.records.filter { $0.versions.contains { $0.kind == "seedream" } } : library.records
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("原片与成片，都在这里。").font(.subheadline).foregroundStyle(AppTheme.muted)
                    HStack(spacing: 28) {
                        ForEach(["全部照片", "AI成片", "原片"], id: \.self) { value in
                            Button { filter = value } label: {
                                Text(value).font(.subheadline.weight(filter == value ? .semibold : .regular))
                                    .foregroundStyle(filter == value ? AppTheme.ink : AppTheme.muted).frame(minHeight: 44)
                            }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                        }
                    }
                    if displayed.isEmpty {
                        ContentUnavailableView(filter == "AI成片" ? "还没有AI成片" : "还没有照片", systemImage: "photo", description: Text("拍摄先保存在本机，选择照片后才决定是否精修。"))
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(displayed) { record in
                                NavigationLink { GalleryPhotoDetail(photoID: record.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        GalleryImage(photoID: record.id, assetID: filter == "原片" ? "original" : filter == "AI成片" ? record.versions.last(where: { $0.kind == "seedream" })?.id.uuidString ?? record.preferredAssetID : record.preferredAssetID, thumbnail: true, revision: record.revision)
                                            .frame(height: 174).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
                                        Text(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                                        if record.jobs.contains(where: { $0.state == "running" }) {
                                            Text("云端任务进行中").font(.caption).foregroundStyle(AppTheme.muted)
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Text("选择一张照片，再决定是否精修。").font(.caption).foregroundStyle(AppTheme.muted)
                    if let error = library.lastSaveError { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let error = library.lastExportError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }.padding(24)
            }.background(AppTheme.paper).navigationTitle("我的图库")
                .toolbar { NavigationLink { CloudAPISettingsView() } label: { Image(systemName: "key") }.accessibilityLabel("云端服务") }
                .onAppear { library.loadIfNeeded() }
        }
    }
}

private struct GalleryImage: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let photoID: UUID
    let assetID: String
    let thumbnail: Bool
    let revision: Int
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                if thumbnail { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(uiImage: image).resizable().scaledToFit() }
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: assetID + String(revision)) {
            guard let record = library.records.first(where: { $0.id == photoID }),
                  let name = thumbnail ? record.thumbnailName(for: assetID) : record.fileName(for: assetID) else { return }
            let url = library.store.fileURL(photoID: photoID, name: name)
            let bytes = await Task.detached(priority: .utility) {
                try? PhotoImagePreparation.jpeg(from: url, maximumDimension: thumbnail ? 512 : 1600, quality: 0.88)
            }.value
            if !Task.isCancelled { image = bytes.flatMap { UIImage(data: $0) } }
        }
    }
}

@MainActor final class PhotoCloudWorkflow: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var phase = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var advice: StoredAdvice?
    @Published private(set) var generatedVersionID: String?
    private var task: Task<Void, Never>?

    func clearSelection() {
        guard !busy else { return }
        advice = nil; generatedVersionID = nil; errorMessage = nil; phase = ""
    }
    func analyze(record: AppPhotoRecord, sourceID: String, instruction: String, library: PhotoLibraryService, force: Bool = false) {
        guard !busy else { return }
        if !force, let cached = record.advice.last(where: { $0.sourceAssetID == sourceID && $0.userInstruction == instruction && $0.policyVersion == NaturalPhotoPolicy.version }) {
            advice = cached; phase = "已载入已有建议，没有新增云端请求。"; errorMessage = nil; return
        }
        if !force, record.jobs.contains(where: { $0.provider == "DeepSeek" && $0.sourceAssetID == sourceID && $0.prompt == instruction && $0.state != "completed" }) {
            errorMessage = "上次分析未完成，无法确认是否已计费。不会自动重发；需要时请明确选择重新分析。"; return
        }
        let key: String
        do {
            key = try CloudHTTP.validatedKey(APIKeyStore.read(.deepseek), provider: "DeepSeek")
            guard instruction.count <= 2000 else { throw CloudAPIError.invalidInput("看图要求请控制在2000字以内。") }
        } catch { errorMessage = error.localizedDescription; return }
        busy = true; phase = "准备选中照片的分析副本…"; errorMessage = nil
        task = Task {
            var jobID: UUID?
            do {
                let jpeg = try await library.store.preparedUpload(photoID: record.id, assetID: sourceID, maximumDimension: 1280)
                try Task.checkCancellation()
                jobID = try await library.beginJob(photoID: record.id, provider: "DeepSeek", sourceAssetID: sourceID, prompt: instruction, model: CloudConfiguration.deepSeekDefault)
                try Task.checkCancellation()
                phase = "上传至DeepSeek并生成看图建议…"
                let reply = try await DeepSeekClient().analyze(jpeg: jpeg, instruction: instruction, key: key, model: CloudConfiguration.deepSeekDefault)
                let saved = StoredAdvice(id: UUID(), sourceAssetID: sourceID, userInstruction: instruction, policyVersion: NaturalPhotoPolicy.version, advice: reply.advice,
                                         createdAt: Date(), model: reply.model, usage: reply.usage)
                try await library.saveAdvice(photoID: record.id, value: saved)
                advice = saved
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "completed") }
                phase = "建议已保存，是否精修由你决定。"
            } catch {
                errorMessage = Self.message(error)
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "failed", message: errorMessage) }
                phase = "本次未继续调用Seedream。"
            }
            busy = false; task = nil
        }
    }
    func edit(record: AppPhotoRecord, sourceID: String, prompt: String, library: PhotoLibraryService, force: Bool = false) {
        guard !busy else { return }
        let model = CloudConfiguration.seedreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = NaturalPhotoPolicy.editPrompt(prompt)
        if !force, let cached = record.versions.last(where: { $0.kind == "seedream" && $0.sourceAssetID == sourceID && $0.prompt == effectivePrompt && $0.model == model }) {
            generatedVersionID = cached.id.uuidString; phase = "已有相同要求的修图版本，没有新增云端请求。"; errorMessage = nil; return
        }
        if !force, let pending = record.jobs.last(where: { $0.provider == "Seedream" && $0.sourceAssetID == sourceID && $0.prompt == effectivePrompt && $0.model == model && $0.state != "completed" }) {
            if pending.transport == "direct-v1", pending.resultURL != nil {
                retryDownload(record: record, job: pending, library: library)
            } else {
                errorMessage = "上次请求没有可下载的直连结果，无法确认是否已计费。请检查平台记录；确需再修时选择新建任务。"
            }
            return
        }
        let key: String
        do {
            key = try CloudHTTP.validatedKey(APIKeyStore.read(.seedream), provider: "Seedream / 火山方舟")
            try CloudHTTP.checkModel(model)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudAPIError.invalidInput("请先填写修图要求或采用DeepSeek建议。") }
        } catch { errorMessage = error.localizedDescription; return }
        busy = true; phase = "准备选中照片的修图副本…"; errorMessage = nil
        task = Task {
            var jobID: UUID?
            do {
                let jpeg = try await library.store.preparedUpload(photoID: record.id, assetID: sourceID, maximumDimension: 3072)
                try Task.checkCancellation()
                jobID = try await library.beginJob(photoID: record.id, provider: "Seedream", sourceAssetID: sourceID, prompt: effectivePrompt, model: model)
                try Task.checkCancellation()
                phase = "上传至Seedream并编辑照片…"
                let client = SeedreamClient()
                let reply = try await client.edit(jpeg: jpeg, prompt: effectivePrompt, key: key, model: model)
                guard let id = jobID else { throw CloudAPIError.invalidResponse }
                // Persist the provider's result URL BEFORE download/cancellation; never resend generation to recover a download.
                try await library.saveJobResult(photoID: record.id, jobID: id, url: reply.imageURL.absoluteString, requestID: reply.requestID)
                try Task.checkCancellation()
                phase = "下载并保存修图结果…"
                let data = try await client.download(reply.imageURL)
                let version = try await library.saveGenerated(photoID: record.id, sourceAssetID: sourceID, data: data, prompt: effectivePrompt, model: model, cloudJobID: id)
                generatedVersionID = version.id.uuidString
                await library.finishJob(photoID: record.id, jobID: id, state: "completed")
                phase = "AI修图已存入图库，原片和之前版本均保留。"
            } catch {
                errorMessage = Self.message(error)
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "failed", message: errorMessage) }
                phase = "没有自动重试；原片仍保留。"
            }
            busy = false; task = nil
        }
    }
    func retryDownload(record: AppPhotoRecord, job: PhotoCloudJob, library: PhotoLibraryService) {
        guard !busy, job.transport == "direct-v1", let resultURL = job.resultURL, let prompt = job.prompt, let model = job.model else { return }
        busy = true; phase = "只下载已有结果，不重新生成…"; errorMessage = nil
        task = Task {
            var resumed = false
            do {
                let url = try CloudHTTP.safeImageURL(resultURL)
                try await library.resumeDownload(photoID: record.id, jobID: job.id)
                resumed = true
                // Download does not read or attach API keys; it also works after keys are deleted.
                let data = try await SeedreamClient().download(url)
                let version = try await library.saveGenerated(photoID: record.id, sourceAssetID: job.sourceAssetID, data: data, prompt: prompt, model: model, cloudJobID: job.id)
                generatedVersionID = version.id.uuidString
                await library.finishJob(photoID: record.id, jobID: job.id, state: "completed")
                phase = "已有结果已保存，没有重新调用模型。"
            } catch {
                errorMessage = "下载未完成：" + error.localizedDescription + " 本次没有重新生成。"
                if resumed { await library.finishJob(photoID: record.id, jobID: job.id, state: "failed", message: errorMessage) }
            }
            busy = false; task = nil
        }
    }
    func cancel() {
        task?.cancel()
        phase = "正在停止等待。已提交的云端请求可能仍会计费。"
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            return "已停止等待。若请求已发出，平台可能仍执行并计费；不会自动重试。"
        }
        return error.localizedDescription + " 请求若已提交但响应中断，平台仍可能计费；不会自动重发。"
    }
}

private struct GalleryPhotoDetail: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let photoID: UUID
    @StateObject private var workflow = PhotoCloudWorkflow()
    @AppStorage("cloudUseDeepSeekFirst") private var defaultDeepSeekFirst = true
    @Environment(\.dismiss) private var dismiss
    @State private var stage = "选择"
    @State private var compareResult = false
    @State private var configured = false
    @State private var sourceID = "original"
    @State private var useDeepSeek = true
    @State private var requestText = "自然通透，保留真实人物与场景，避免过度HDR和塑料肤质。"
    @State private var editPrompt = ""
    @State private var adoptedAdviceID: UUID?
    @State private var exportStatus: String?
    private var record: AppPhotoRecord? { library.records.first { $0.id == photoID } }
    private var activeAdvice: StoredAdvice? {
        if let value = workflow.advice, value.sourceAssetID == sourceID, value.policyVersion == NaturalPhotoPolicy.version { return value }
        return record?.advice.last(where: { $0.sourceAssetID == sourceID && $0.policyVersion == NaturalPhotoPolicy.version })
    }
    private var isBusy: Bool { workflow.busy || (record?.jobs.contains(where: { $0.state == "running" }) ?? false) }
    private var matchingResult: PhotoVersion? {
        record?.versions.last { $0.kind == "seedream" && $0.sourceAssetID == sourceID }
    }
    private var displayAssetID: String { compareResult ? matchingResult?.id.uuidString ?? sourceID : sourceID }
    private var pageTitle: String { stage == "建议" ? "看图建议" : stage == "精修" ? "照片精修" : "这张照片怎么处理" }
    private var adviceReady: Bool { !useDeepSeek || (activeAdvice?.id == adoptedAdviceID && !editPrompt.isEmpty) }

    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 22) {
                    Text(stage == "建议" ? "1 / 2    先看建议，再决定修图" : stage == "精修" ? "2 / 2    确认要求后才生成" : "上传源：选中版本 · 可切换")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                    GalleryImage(photoID: photoID, assetID: displayAssetID, thumbnail: false, revision: record.revision)
                        .frame(height: stage == "建议" ? 174 : 220).clipShape(RoundedRectangle(cornerRadius: 18))
                    if stage == "精修", matchingResult != nil {
                        Picker("原片与AI成片对比", selection: $compareResult) {
                            Text("上传源").tag(false); Text("AI成片").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    versionPicker(record)
                    if isBusy || workflow.errorMessage != nil { taskStatus(record) }
                    if stage == "选择" && !isBusy { cloudControls(record) }
                    if stage == "建议", let value = activeAdvice { adviceCard(value) }
                    if stage == "精修" && !isBusy { editControls(record) }
                    if !isBusy && workflow.errorMessage == nil { taskStatus(record) }
                    Button("导出当前版本到系统相册") {
                        Task {
                            do { try await library.export(photoID: photoID, assetID: displayAssetID); exportStatus = "已导出到系统相册。" }
                            catch { exportStatus = error.localizedDescription }
                        }
                    }.buttonStyle(.bordered).disabled(isBusy)
                    if let exportStatus { Text(exportStatus).font(.footnote).foregroundStyle(.secondary) }
                }.padding(24)
            } else { ContentUnavailableView("照片暂不可用", systemImage: "photo") }
        }.background(AppTheme.paper).navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { NavigationLink { CloudAPISettingsView() } label: { Image(systemName: "key") } }
            .onAppear { if !configured { useDeepSeek = defaultDeepSeekFirst; configured = true } }
            .onChange(of: useDeepSeek) { _, enabled in
                if !enabled && editPrompt.isEmpty { editPrompt = requestText }
            }
            .onChange(of: sourceID) { _, _ in
                workflow.clearSelection(); adoptedAdviceID = nil; editPrompt = ""; exportStatus = nil; stage = "选择"; compareResult = false
            }
            .onChange(of: workflow.advice?.id) { _, id in if id != nil { stage = "建议" } }
            .onChange(of: workflow.generatedVersionID) { _, id in if id != nil { stage = "精修"; compareResult = true } }
            .onChange(of: requestText) { _, _ in adoptedAdviceID = nil }
    }
    private func versionPicker(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("上传源", selection: $sourceID) {
                Text("原片").tag("original")
                ForEach(record.versions) { Text($0.title).tag($0.id.uuidString) }
            }.disabled(isBusy)
        }.padding(10).background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 12))
    }
    private func cloudControls(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("先让 DeepSeek 看图建议", isOn: $useDeepSeek).tint(AppTheme.mint).disabled(isBusy)
            TextField("你想保留或改善什么？", text: $requestText, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(isBusy)
            if useDeepSeek {
                Button("获取 DeepSeek 建议") {
                    adoptedAdviceID = nil
                    workflow.analyze(record: record, sourceID: sourceID, instruction: requestText, library: library)
                    if let advice = workflow.advice, advice.sourceAssetID == sourceID, advice.userInstruction == requestText { stage = "建议" }
                }.buttonStyle(AppActionStyle()).disabled(isBusy)
                Text("点击才上传照片并调用DeepSeek。已有相同要求的建议会直接复用。")
                    .font(.caption).foregroundStyle(.secondary)
                if activeAdvice != nil || record.jobs.contains(where: { $0.provider == "DeepSeek" && $0.sourceAssetID == sourceID && $0.state != "completed" }) {
                    Button("重新看图分析（另计一次）") {
                        adoptedAdviceID = nil
                        workflow.analyze(record: record, sourceID: sourceID, instruction: requestText, library: library, force: true)
                    }.font(.caption).disabled(isBusy)
                }
            }
            Button("跳过建议，直接填写修图要求") {
                useDeepSeek = false
                if editPrompt.isEmpty { editPrompt = requestText }
                stage = "精修"
            }.buttonStyle(AppActionStyle(primary: false)).disabled(isBusy)
        }.appCard()
    }
    private func adviceCard(_ value: StoredAdvice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DeepSeek 建议").font(.title3.bold())
            Text("识别场景：" + value.advice.scene).font(.subheadline).foregroundStyle(AppTheme.muted)
            Text("分析时要求：" + value.userInstruction).font(.caption).foregroundStyle(.secondary)
            if value.advice.issues.isEmpty { Text("照片没有明显问题，可以直接保留原片。").font(.subheadline) }
            adviceList("画面优点", value.advice.strengths)
            adviceList("可改善的地方", value.advice.issues)
            adviceList("修图建议", value.advice.recommendations)
            adviceList("保留内容", value.advice.preserve)
            Text(value.advice.editPrompt).font(.subheadline).textSelection(.enabled)
            Button("采用建议，编辑修图要求") {
                editPrompt = value.advice.editPrompt
                adoptedAdviceID = value.id
                stage = "精修"
            }.buttonStyle(AppActionStyle()).disabled(isBusy)
            Button("暂不修图，返回图库") { dismiss() }.buttonStyle(AppActionStyle(primary: false))
            Text("采用建议不会调用Seedream。下一步仍由你决定是否生成。")
                .font(.caption).foregroundStyle(AppTheme.muted)
        }.appCard()
    }
    private func adviceList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text("• " + item).font(.subheadline) }
        }
    }
    private func editControls(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修图要求").font(.headline)
            Text("默认自然精修：保留原貌，只改确有需要的区域。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            TextEditor(text: $editPrompt).frame(minHeight: 135)
                .padding(8).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .disabled(isBusy)
            if editPrompt.isEmpty && !useDeepSeek {
                Button("把我的要求填入修图框") { editPrompt = requestText }.font(.subheadline)
            }
            Button("用 Seedream 修这张") {
                workflow.edit(record: record, sourceID: sourceID, prompt: editPrompt, library: library)
            }.buttonStyle(AppActionStyle())
                .disabled(isBusy || editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !adviceReady)
            Button("重新选择处理方式") { stage = "选择" }.buttonStyle(AppActionStyle(primary: false))
            Text("点击才上传并进行云端处理；不会自动逐张修图。相同结果优先复用，原片始终保留。")
                .font(.caption).foregroundStyle(.secondary)
            if let resultID = workflow.generatedVersionID {
                Button("查看刚才的AI修图版本") { sourceID = resultID }.buttonStyle(.bordered).disabled(isBusy)
            }
            DisclosureGroup("需要另一个结果或原任务无法取回？") {
                Button("新建任务重新生成（可能再次计费）") {
                    workflow.edit(record: record, sourceID: sourceID, prompt: editPrompt, library: library, force: true)
                }.disabled(isBusy || !adviceReady || editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.caption)
        }
    }
    private func taskStatus(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isBusy {
                VStack(alignment: .leading, spacing: 12) {
                    Text("正在处理，请稍候…").font(.title3.bold())
                    ProgressView(workflow.phase.isEmpty ? "此照片的云端任务进行中" : workflow.phase)
                    Text("完成后存入本张照片的版本记录，不会处理其他照片。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }.appCard(tinted: true)
            }
            else if !workflow.phase.isEmpty { Text(workflow.phase).font(.footnote) }
            if workflow.busy { Button("停止等待") { workflow.cancel() }.buttonStyle(AppActionStyle(primary: false)) }
            if let error = workflow.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if let pending = record.jobs.last(where: { $0.transport == "direct-v1" && $0.provider == "Seedream" && $0.resultURL != nil && $0.state != "running" && $0.state != "completed" }) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("可以继续下载结果").font(.title3.bold())
                    Text("已保存平台返回的图片链接，只重试下载，不重新生图。链接可能过期，请及时保存。")
                        .font(.subheadline).foregroundStyle(AppTheme.muted)
                    Button("仅重试下载") { workflow.retryDownload(record: record, job: pending, library: library) }
                        .buttonStyle(AppActionStyle()).disabled(isBusy)
                }.appCard()
            }
            if !record.jobs.isEmpty {
                DisclosureGroup("这张照片的云端任务记录") {
                    ForEach(record.jobs.suffix(5).reversed()) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.provider + " · " + job.stateTitle).font(.caption.bold())
                            Text(job.startedAt.formatted()).font(.caption2)
                            if let message = job.message { Text(message).font(.caption2).foregroundStyle(.secondary) }

                        }.padding(.vertical, 3)
                    }
                }
            }
        }
    }
}
