import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Test View

struct SherpaOnnxTestView: View {
    @State private var selectedFileURL: URL?
    @State private var selectedFileAccessGranted = false
    @State private var selectedFileName: String = ""
    @State private var audioDuration: String = ""
    @State private var audioSampleRate: String = ""

    // 参数
    @State private var threshold: Double = 1.2     // 聚类距离阈值 (余弦距离 0~2，默认 1.2，越低人越多)
    @State private var numSpeakers: Double = -1     // 预期说话人数（-1=自动）
    @State private var minDurationOn: Double = 0.5
    @State private var minDurationOff: Double = 0.5

    // 状态
    @State private var isProcessing = false
    @State private var progress: Float = 0
    @State private var logLines: [LogLine] = []
    @State private var resultSegments: [SegmentDisplay] = []
    @State private var resultSpeakerCount: Int = 0
    @State private var showFilePicker = false

    // 模型状态
    @State private var segModelExists = false
    @State private var embModelExists = false

    private let diarizer = SherpaOnnxDiarizer()
    private let allowedAudioTypes: [UTType] = [.wav, .mp3, .aiff, .audio]

    var body: some View {
        let content = VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                scrollContentView
            }
        }
        return content
            .frame(minWidth: 640, minHeight: 600)
            .background(.regularMaterial)
            .onAppear { checkModels() }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: allowedAudioTypes, allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
    }

    private var scrollContentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            modelStatusCard
            audioSelectionCard
            paramsCard
            runButtonCard
            if isProcessing { progressCard }
            if !resultSegments.isEmpty { resultCard }
            if !logLines.isEmpty { logCard }
        }
        .padding(20)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                // 获取安全作用域访问权限
                let granted = url.startAccessingSecurityScopedResource()
                // 先释放旧文件权限
                if let oldURL = selectedFileURL, selectedFileAccessGranted {
                    oldURL.stopAccessingSecurityScopedResource()
                }
                selectedFileAccessGranted = granted
                loadAudioFile(url)
            }
        case .failure(let error):
            addLog("选择文件失败: \(error.localizedDescription)", .error)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("sherpa-onnx 声纹分离测试")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Text("v1.13.4")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Button {
                checkModels()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("刷新模型状态")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Model Status

    private var modelStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("模型状态", systemImage: "shippingbox")
                .font(.headline)
                .foregroundStyle(.purple)

            HStack(spacing: 20) {
                modelStatusRow(
                    icon: segModelExists ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: segModelExists ? .green : .red,
                    label: "分割模型 (pyannote-segmentation-3-0)",
                    detail: segModelExists ? "已就绪" : "未下载"
                )
                modelStatusRow(
                    icon: embModelExists ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: embModelExists ? .green : .red,
                    label: "声纹模型 (3dspeaker-eres2net)",
                    detail: embModelExists ? "已就绪" : "未下载"
                )
            }

            if !segModelExists || !embModelExists {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("请将 ONNX 模型文件放入以下目录:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(modelsDir)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func modelStatusRow(icon: String, color: Color, label: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio Selection

    private var audioSelectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("音频文件", systemImage: "music.note.list")
                .font(.headline)
                .foregroundStyle(.orange)

            if let url = selectedFileURL {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedFileName)
                            .font(.callout)
                            .fontWeight(.medium)
                        HStack(spacing: 16) {
                            if !audioDuration.isEmpty {
                                Label(audioDuration, systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !audioSampleRate.isEmpty {
                                Label("\(audioSampleRate) Hz", systemImage: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(url.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        selectedFileURL = nil
                        selectedFileName = ""
                        audioDuration = ""
                        audioSampleRate = ""
                        resultSegments = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("选择音频文件...")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Parameters

    private var paramsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分离参数", systemImage: "slider.horizontal.3")
                .font(.headline)
                .foregroundStyle(.teal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                paramSlider("聚类阈值", value: $threshold, range: 0.5...1.5, fmt: "%.2f",
                            hintLow: "更多说话人", hintHigh: "更少说话人")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("说话人数")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text(numSpeakers < 0 ? "自动" : "\(Int(numSpeakers))")
                            .font(.caption)
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(.teal)
                    }
                    Slider(value: $numSpeakers, in: -1...20, step: 1)
                        .controlSize(.small)
                    HStack {
                        Text("自动").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("20").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))

                paramSlider("最短语音段 (s)", value: $minDurationOn, range: 0.1...2.0, fmt: "%.1f",
                            hintLow: "更灵敏", hintHigh: "更稳定")
                paramSlider("最小静音间隔 (s)", value: $minDurationOff, range: 0.1...2.0, fmt: "%.1f",
                            hintLow: "更精细", hintHigh: "更宽松")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func paramSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String,
                             hintLow: String, hintHigh: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.caption)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.teal)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
            HStack {
                Text(hintLow).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(hintHigh).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Run Button

    private var runButtonCard: some View {
        HStack {
            Button(action: runDiarization) {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                        Text("处理中...")
                    } else {
                        Image(systemName: "play.fill")
                        Text("开始分离")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(canRun ? Color.blue : Color.gray.opacity(0.3))
                .foregroundStyle(.white)
                .cornerRadius(8)
                .font(.callout)
                .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(!canRun || isProcessing)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var canRun: Bool {
        selectedFileURL != nil && segModelExists && embModelExists && !isProcessing
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("处理进度", systemImage: "hourglass")
                .font(.headline)
                .foregroundStyle(.blue)

            ProgressView(value: Double(progress))
                .progressViewStyle(.linear)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Results

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分离结果", systemImage: "person.3.fill")
                .font(.headline)
                .foregroundStyle(.green)

            HStack(spacing: 20) {
                statBadge("说话人数", "\(resultSpeakerCount)", .blue)
                statBadge("片段数", "\(resultSegments.count)", .orange)
            }

            // 片段列表
            if !resultSegments.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(resultSegments) { seg in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(speakerColor(seg.speaker))
                                    .frame(width: 8, height: 8)
                                Text("说话人 \(seg.speaker)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(speakerColor(seg.speaker))
                                Spacer()
                                Text("\(formatTime(seg.start)) → \(formatTime(seg.end))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text("(\(String(format: "%.1fs", seg.end - seg.start)))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(seg.speaker % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func statBadge(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("处理日志", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                    .foregroundStyle(.gray)
                Spacer()
                Button {
                    let text = logLines.map { $0.message }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("复制日志")
                Button("清空") {
                    logLines.removeAll()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logLines) { line in
                            Text(line.message)
                                .font(.caption2)
                                .monospaced()
                                .foregroundStyle(line.level.color)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
                .onChange(of: logLines.count) { _ in
                    if let last = logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Helpers

    private var modelsDir: String {
        // 模型由构建脚本复制到 App Resources 目录
        guard let resourcePath = Bundle.main.resourcePath else {
            return ""
        }
        return resourcePath + "/sherpa-onnx-models"
    }

    private func segmentationModelPath() -> String {
        return modelsDir + "/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
    }

    private func embeddingModelPath() -> String {
        return modelsDir + "/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    }

    private func checkModels() {
        segModelExists = FileManager.default.fileExists(atPath: segmentationModelPath())
        embModelExists = FileManager.default.fileExists(atPath: embeddingModelPath())
        addLog("模型状态检查: 分割=\(segModelExists ? "✅" : "❌"), 声纹=\(embModelExists ? "✅" : "❌")", .info)
    }

    private func loadAudioFile(_ url: URL) {
        selectedFileURL = url
        selectedFileName = url.lastPathComponent

        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        if duration.isFinite && duration > 0 {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            audioDuration = mins > 0 ? "\(mins)分\(secs)秒" : "\(secs)秒"
        }

        // 异步加载轨道信息（安全作用域URL需要异步等AVAsset完成加载）
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                if let track = tracks.first {
                    let descs = try await track.load(.formatDescriptions)
                    if let desc = descs.first {
                        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                        if let basic = basic?.pointee {
                            await MainActor.run {
                                audioSampleRate = String(format: "%.0f", basic.mSampleRate)
                            }
                        }
                    }
                }
            } catch {
                addLog("加载音频信息失败: \(error.localizedDescription)", .error)
            }
        }

        addLog("已加载: \(url.lastPathComponent) (\(audioDuration))", .info)
    }

    private func runDiarization() {
        guard let url = selectedFileURL, segModelExists, embModelExists else { return }

        isProcessing = true
        progress = 0
        resultSegments = []
        logLines.removeAll()

        addLog("========== 开始分离 ==========", .info)
        addLog("音频: \(url.lastPathComponent)", .info)
        addLog("阈值: \(String(format: "%.2f", threshold)), 人数: \(numSpeakers < 0 ? "自动" : "\(Int(numSpeakers))")", .info)

        Task.detached(priority: .userInitiated) {
            do {
                // 1. 加载并重采样音频
                await self.addLog("加载音频...", .info)
                let (samples, sampleRate) = try await self.loadAudioSamples(url)

                await self.addLog("音频已加载: \(samples.count) samples, \(sampleRate) Hz", .info)

                // 2. 配置分离器
                var config = SherpaDiarizationConfig()
                config.segmentationModel = self.segmentationModelPath()
                config.embeddingModel = self.embeddingModelPath()
                config.clustering.threshold = Float(self.threshold)
                config.clustering.numClusters = Int32(self.numSpeakers)
                config.minDurationOn = Float(self.minDurationOn)
                config.minDurationOff = Float(self.minDurationOff)

                try self.diarizer.create(config: config)
                let requiredRate = self.diarizer.getSampleRate()

                await self.addLog("分离器已创建，要求采样率: \(requiredRate) Hz", .info)

                // 3. 重采样（如需要）
                let finalSamples: [Float]
                if sampleRate != Int(requiredRate) {
                    await self.addLog("重采样 \(sampleRate) → \(requiredRate)...", .info)
                    finalSamples = try self.resample(samples, from: sampleRate, to: Int(requiredRate))
                    await self.addLog("重采样完成: \(finalSamples.count) samples", .info)
                } else {
                    finalSamples = samples
                }

                // 4. 运行分离
                await self.addLog("开始分离处理...", .info)
                var lastLoggedProgress: Float = 0
                let diarizationStartTime = Date()
                let result = try self.diarizer.process(samples: finalSamples) { p in
                    let percent = Int(p * 100)
                    let lastPercent = Int(lastLoggedProgress * 100)
                    if percent - lastPercent >= 10 || p >= 1.0 {
                        lastLoggedProgress = p
                        let elapsed = Date().timeIntervalSince(diarizationStartTime)
                        Task { @MainActor in
                            self.progress = p
                            self.addLog(String(format: "  进度: %d%% (耗时 %.1fs)", percent, elapsed), .debug)
                        }
                    } else {
                        Task { @MainActor in
                            self.progress = p
                        }
                    }
                }

                // 5. 展示结果
                await MainActor.run {
                    self.resultSpeakerCount = Int(result.numSpeakers)
                    self.resultSegments = result.segments.map {
                        SegmentDisplay(start: $0.start, end: $0.end, speaker: $0.speaker)
                    }
                    self.isProcessing = false
                    self.progress = 1.0

                    self.addLog("✅ 分离完成!", .info)
                    self.addLog("说话人数: \(result.numSpeakers)", .info)
                    self.addLog("片段数: \(result.segments.count)", .info)

                    for seg in result.segments {
                        self.addLog(
                            "  [说话人 \(seg.speaker)] \(String(format: "%.2f", seg.start))s → \(String(format: "%.2f", seg.end))s (\(String(format: "%.1f", seg.end - seg.start))s)",
                            .debug
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.addLog("❌ 错误: \(error.localizedDescription)", .error)
                }
            }
        }
    }

    // MARK: - Audio Loading

    private func loadAudioSamples(_ url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        let asset = AVAsset(url: url)
        
        // 使用异步 API 加载轨道（沙盒安全作用域 URL 需要异步加载）
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SherpaError.audioLoadFailed("无音频轨道")
        }

        let descs = try await track.load(.formatDescriptions)
        guard let desc = descs.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            throw SherpaError.audioLoadFailed("无法获取音频格式")
        }

        let originalRate = Int(basic.mSampleRate)
        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: originalRate
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var allSamples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let data = dataPointer {
                let floatPtr = data.withMemoryRebound(to: Float.self, capacity: length / 4) { $0 }
                let buffer = UnsafeBufferPointer(start: floatPtr, count: length / 4)
                allSamples.append(contentsOf: buffer)
            }
        }

        return (allSamples, originalRate)
    }

    // MARK: - Simple Resampling

    private func resample(_ samples: [Float], from srcRate: Int, to dstRate: Int) throws -> [Float] {
        guard srcRate != dstRate else { return samples }
        let ratio = Double(dstRate) / Double(srcRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var result: [Float] = []
        result.reserveCapacity(outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let i0 = Int(floor(srcIndex))
            let i1 = min(i0 + 1, samples.count - 1)
            let frac = Float(srcIndex - Double(i0))
            result.append(samples[i0] * (1.0 - frac) + samples[i1] * frac)
        }
        return result
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func addLog(_ message: String, _ level: LogLevel) {
        let time = dateFormatter.string(from: Date())
        logLines.append(LogLine(message: "[\(time)] \(message)", level: level))
    }

    private func formatTime(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds - Float(Int(seconds))) * 1000)
        return String(format: "%d:%02d.%03d", mins, secs, ms)
    }

    private let speakerColors: [Color] = [.blue, .orange, .green, .red, .purple, .teal, .pink, .yellow,
                                           .indigo, .mint, .cyan, .brown, .gray]

    private func speakerColor(_ index: Int32) -> Color {
        let i = Int(index) % speakerColors.count
        return speakerColors[i]
    }
}

// MARK: - Supporting Types

enum LogLevel {
    case info, debug, error
    var color: Color {
        switch self {
        case .info: return .primary
        case .debug: return .secondary
        case .error: return .red
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
}

struct SegmentDisplay: Identifiable {
    let id = UUID()
    let start: Float
    let end: Float
    let speaker: Int32
}

#Preview {
    SherpaOnnxTestView()
}
