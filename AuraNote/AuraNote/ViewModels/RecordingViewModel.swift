import SwiftUI
import AVFoundation

/// 录音 ViewModel：协调 AudioRecorder、DatabaseManager 和 UI 状态
@MainActor
@Observable
final class RecordingViewModel {

    // MARK: - UI 状态

    var meetingStatus: MeetingStatus = .idle
    var currentMeeting: Meeting?
    var audioChunks: [AudioChunk] = []         // 实时录音时的音频片段列表
    var transcriptSegments: [TranscriptSegment] = []  // 回顾模式下的转写片段
    var isListening: Bool = false               // 当前是否有语音活动
    var recordingDuration: TimeInterval = 0
    var showNewMeetingSheet = false
    var errorAlert: String?
    var analysisCompletionMessage: String?

    // MARK: - 新建会议表单

    var formTitle = ""
    var formLocation = ""
    var formAttendees = ""
    var shouldExtendLastMeeting = false
    var selectedParentMeetingId: String? = nil
    var formCreatedAt = Date()
    var formSpeechLang = UserDefaults.standard.string(forKey: "speech_language") ?? "zh"
    var formHotwordCategories: Set<String> = []

    enum RecordingMode {
        case liveRecording
        case importFile
    }

    var recordingMode: RecordingMode = .liveRecording
    var showingMeetingEditor = false

    enum MeetingStatus {
        case idle
        case recording
        case reviewing
    }

    // MARK: - 依赖

    var audioPlayer = AudioPlayer() // 回放播放器
    let audioRecorder: AudioRecorder
    private let databaseManager: DatabaseManager
    
    // 离线转写状态
    var isTranscribingOffline: Bool = false
    var segmentCount: Int = 0
    /// 离线转写的最终总段数（转写完成前为 0，完成后锁定为准确值）
    var offlineTotalSegments: Int = 0
    /// 转写进度 0.0~1.0（基于已发现段数与估计总量的比值）
    var offlineProgressFraction: Double = 0
    /// 已处理音频/声纹时长（秒）与总音频时长（秒）
    var processedDiarizationDuration: Double = 0
    var totalAudioDuration: Double = 0
    private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var lastDiarEmbeddings: [String: [Float]]?

    // 定时器
    private var durationTimer: Timer?

    // MARK: - 会议整理期间临时发言人（仅内存，不立即写入数据库）
    /// 键为 speakerLabel（如 Speaker_S0），值为临时在内存中的 Contact
    var pendingNewContacts: [String: Contact] = [:]
    /// 临时发言人的声纹向量（用于会议内声纹比对）
    var pendingNewEmbeddings: [String: [Float]] = [:]
    /// 退出时待确认保存的新联系人列表
    var pendingNewContactsToPrompt: [Contact] = []
    /// 用户已勾选的新联系人 ID（用于 checkbox 多选保存）
    var selectedPendingContactIds: Set<String> = []
    /// 是否显示保存新联系人确认弹窗
    var showSaveNewContactsAlert = false
    /// 待持久化的发言人重命名（退出会议时统一写入 DB）
    /// key=oldName, value=(newName, contactId)
    private var pendingSpeakerRenames: [String: (newName: String, contactId: String)] = [:]

    init(audioRecorder: AudioRecorder, databaseManager: DatabaseManager) {
        self.audioRecorder = audioRecorder
        self.databaseManager = databaseManager
        
        // 设置声纹匹配用的联系人提供者（从全局人员库查找）
        audioRecorder.contactsProvider = { [weak databaseManager] in
            guard let db = databaseManager else { return [] }
            return await MainActor.run { db.fetchContactsWithEmbeddings() }
        }
        // 匹配成功后自动添加为会议参会人
        audioRecorder.onSpeakerMatched = { [weak self] contactId, contactName in
            self?.addAttendee(contactName)
        }
        // 增量聚类发现新匿名说话人时实时添加为参会人
        audioRecorder.onNewSpeakerDiscovered = { [weak self] label in
            self?.addAttendee(label)
        }
        // 声纹标签更新后立即同步 audioChunks，避免等 1s 定时器
        audioRecorder.onVoiceprintLabelsUpdated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioChunks = self.audioRecorder.audioChunks
            }
        }
    }

    // MARK: - 录音控制

    /// 用户点击"开始新录音"
    func onTapStartRecording() {
        resetForm()  // 确保每次新建会议时表单为空白状态
        showNewMeetingSheet = true
    }

    /// 用户在弹窗中确认开始
    func startRecording() async {
        showNewMeetingSheet = false

        // 保存转写语言选择
        UserDefaults.standard.set(formSpeechLang, forKey: "speech_language")

        // 1. 请求权限
        let granted = await audioRecorder.requestPermissions()
        guard granted else {
            errorAlert = audioRecorder.errorMessage ?? loc("err_permission_denied")
            return
        }

        // 2. 创建会议记录
        let title = formTitle.isEmpty
            ? String(format: loc("default_meeting_title"), formattedDate)
            : formTitle

        // 如果勾选了延续上一次会议，则获取选中的关联会议 ID
        var parentId: String? = nil
        if shouldExtendLastMeeting {
            parentId = selectedParentMeetingId
        }

        var meeting = Meeting.create(
            title: title,
            location: formLocation.isEmpty ? nil : formLocation,
            parentMeetingId: parentId,
            attendees: formAttendees.isEmpty ? nil : formAttendees
        )
        meeting.createdAt = formCreatedAt
        meeting.updatedAt = formCreatedAt
        meeting.hotwordCategories = formHotwordCategories.isEmpty ? nil : formHotwordCategories.sorted().joined(separator: ",")

        do {
            try databaseManager.createMeeting(meeting)
        } catch {
            errorAlert = "\(loc("err_create_meeting_failed")): \(error.localizedDescription)"
            return
        }

        // 3. 准备音频路径与上下文词汇
        let audioDir = SettingsManager.shared.dataDirectory
        let audioPath = audioDir.appendingPathComponent("audio_\(meeting.id).wav")

        // 组装在线识别器热词：标题 + 地点 + 参会人 + 行业词库 + 自定义热词
        var contextualWords: [String] = []
        if !formTitle.isEmpty { contextualWords.append(formTitle) }
        if !formLocation.isEmpty { contextualWords.append(formLocation) }
        if !formAttendees.isEmpty { contextualWords.append(contentsOf: formAttendees.split(separator: " ").map(String.init)) }
        let hotwordCats = formHotwordCategories
        let industryHws = HotwordPresetsManager.shared.getWords(for: Array(hotwordCats))
        if !industryHws.isEmpty { contextualWords.append(industryHws) }
        if hotwordCats.contains("__custom__") {
            let customHws = SettingsManager.shared.hotwords.trimmingCharacters(in: .whitespaces)
            if !customHws.isEmpty { contextualWords.append(customHws) }
        }
        let finalOnlineHotwords = contextualWords.joined(separator: " ")

        // 注：FunASR 在线模型由 AudioRecorder.startRecording() 内部按需初始化
        // 4. 启动录音（音频直接写入文件）
        do {
            try audioRecorder.startRecording(meetingId: meeting.id, savePath: audioPath, hotwords: finalOnlineHotwords)
        } catch {
            errorAlert = "\(loc("err_start_record_failed"))\n\(error.localizedDescription)"
            return
        }

        // 将音频路径保存到数据库
        do {
            try databaseManager.updateMeetingAudioPath(id: meeting.id, audioPath: audioPath.path)
        } catch {
            AppLog.warn("Failed to save audio path meeting=\(meeting.id): \(error.localizedDescription)")
        }

        // 5. 更新状态
        currentMeeting = meeting
        meetingStatus = .recording
        recordingDuration = 0
        audioChunks = []
        transcriptSegments = []
        resetForm()

        // 6. 启动计时器
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.recordingDuration += 1
                self.audioChunks = self.audioRecorder.audioChunks
                self.isListening = self.audioRecorder.isListening
            }
        }
        self.durationTimer = timer
    }

    /// 停止录音，进入回顾模式
    func stopRecording() {
        AppLog.info("stopRecording started")
        durationTimer?.invalidate()
        durationTimer = nil

        // 必须在后台线程停止音频引擎，避免主线程死锁
        // installTap 回调内使用 DispatchQueue.main.async 投递工作到主线程，
        // 若在主线程调用 removeTap/stop，引擎内部清理可能等待回调完成 → 死锁
        let recorder = audioRecorder
        let duration: Int = DispatchQueue.global().sync {
            recorder.stopRecording()
        }
        AppLog.info("Recording engine stopped, duration=\(duration)s")

        // 更新数据库状态并补充音频路径
        if let meeting = currentMeeting {
            let audioDir = SettingsManager.shared.dataDirectory
            let audioPath = audioDir.appendingPathComponent("audio_\(meeting.id).wav").path
            
            // 更新数据库
            safeUpdateStatus(id: meeting.id, status: .pendingDiarization, duration: duration)
            
            // 同步本地对象的时长（数据库已更新，本地也需同步，供后续进度计算使用）
            currentMeeting?.duration = duration
            currentMeeting?.audioPath = audioPath
            
            // 设置播放器总时长为录音实际秒数
            audioPlayer.duration = TimeInterval(duration)
            audioPlayer.currentTime = 0
        }

        // 将实时 AudioChunk 转换为 TranscriptSegment 供回顾模式使用
        // 保留实时转写文本和声纹匹配结果，不再重新识别
        transcriptSegments = audioRecorder.audioChunks.compactMap { chunk in
            // 跳过纯静默片段（无文本且被标记为已处理空内容）
            let text = chunk.text ?? ""
            guard !chunk.isTranscribing else {
                // 仍在识别中的片段，保留进来（后续可能被离线结果覆盖）
                return TranscriptSegment(
                    id: chunk.id,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: "",
                    speakerLabel: chunk.speakerLabel ?? "?",
                    isFinal: false,
                    isManualEdit: chunk.isManualEdit
                )
            }
            return TranscriptSegment(
                id: chunk.id,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                text: text,
                speakerLabel: chunk.speakerLabel ?? "?",
                isFinal: true,
                isManualEdit: chunk.isManualEdit
            )
        }

        // 延迟 0.15 秒改变状态，确保 macOS 文件句柄从写入锁定状态安全释放
        // 在切换状态前释放原始音频缓存：WAV 已写入磁盘，后续分析从文件读取，内存拷贝不再需要
        self.audioChunks = []
        audioRecorder.audioChunks = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.meetingStatus = .reviewing
            self.runOfflineTranscription()
        }
    }

    /// 运行本地大模型进行高精度离线转写
    private func runOfflineTranscription() {
        guard let meeting = currentMeeting else { return }
        let audioURL = meeting.localAudioURL

        runOfflineTranscription(for: meeting.id, audioURL: audioURL)
    }

    func retryOfflineTranscription(for meetingId: String, audioURL: URL) {
        runOfflineTranscription(for: meetingId, audioURL: audioURL)
    }
    
    /// 仅继续声纹分离（不重新转写），用于已有转写结果但分离未完成/需重做的场景
    func continueOfflineDiarization(for meetingId: String, audioURL: URL) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            AppLog.info("Voiceprint diarization started: meeting=\(meetingId)")
            safeUpdateStatus(id: meetingId, status: .processingLlm)
            isTranscribingOffline = true
            
            let currentSegments = self.transcriptSegments
            
            let result: DiarizationOutput? = await Task.detached {
                try? await DiarizationService.shared.diarizeSegmented(audioURL: audioURL, fastVAD: true)
            }.value
            
            guard let diarOutput = result else {
                AppLog.warn("Voiceprint diarization failed: meeting=\(meetingId)")
                await MainActor.run { [weak self] in
                    self?.isTranscribingOffline = false
                    self?.safeUpdateStatus(id: meetingId, status: .pendingDiarization)
                }
                return
            }
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let matchEmbeddings = diarOutput.embeddings
                self.lastDiarEmbeddings = matchEmbeddings
                do {
                    try self.databaseManager.saveMeetingEmbeddings(meetingId: meetingId, embeddings: matchEmbeddings)
                } catch {
                    AppLog.error("Failed to save voiceprint vectors meeting=\(meetingId): \(error.localizedDescription)")
                }
                
                let speakerCount = Set(diarOutput.segments.map(\.speakerId)).count
                AppLog.info("Voiceprint diarization complete: \(speakerCount) speakers, \(diarOutput.segments.count) segments | config: incrClusterDist=\(SettingsManager.shared.incrementalClusteringDistance)")
                
                // 保留用户手动修改的标签
                var customLabels: [String: (label: String, contactId: String?)] = [:]
                for seg in currentSegments {
                    if seg.isManualEdit {
                        customLabels[seg.id] = (seg.speakerLabel, seg.contactId)
                    }
                }
                
                var aligned = SpeakerAlignmentService.align(transcripts: currentSegments, diarization: diarOutput.segments)
                
                // 恢复手动标签
                if !customLabels.isEmpty {
                    aligned = aligned.map { seg in
                        var s = seg
                        if let saved = customLabels[seg.id] {
                            s.speakerLabel = saved.label
                            s.contactId = saved.contactId
                        }
                        return s
                    }
                }
                
                // 声纹匹配
                let allContacts = self.databaseManager.fetchAllContacts()
                let knownContacts = self.databaseManager.fetchContactsWithEmbeddings()
                AppLog.info("Voiceprint matching: known contacts=\(allContacts.count)")
                var matchedSpeakerIds = Set<String>()
                if !knownContacts.isEmpty {
                    let matchResult = SpeakerMatcher.match(embeddings: matchEmbeddings, against: knownContacts)
                    matchedSpeakerIds = matchResult.matchedSpeakerIds
                    for (_, match) in matchResult.highConfidence {
                        self.addAttendee(match.name)
                        // 声纹持久化延迟到退出会议时由用户确认
                    }
                    var autoMap: [String: (name: String, contactId: String)] = [:]
                    for (speakerId, match) in matchResult.highConfidence {
                        autoMap[speakerId] = (name: match.name, contactId: match.contactId)
                    }
                    if !autoMap.isEmpty {
                        aligned = aligned.map { seg in
                            var s = seg
                            if let match = autoMap[seg.speakerLabel] {
                                s.speakerLabel = match.name
                                s.contactId = match.contactId
                            }
                            return s
                        }
                    }
                }
                
                // 未匹配的临时 Speaker 转正（仅内存，不写库。退出时根据发言记录数决定是否保存）
                let remainingLabels = Set(aligned.map(\.speakerLabel)).filter { $0.hasPrefix("Speaker_") && !matchedSpeakerIds.contains($0) }
                for label in remainingLabels {
                    self.addAttendee(label)
                    let memContact = self.getOrCreateMemoryContact(for: label, embedding: matchEmbeddings[label])
                    for i in 0..<aligned.count where aligned[i].speakerLabel == label {
                        aligned[i].contactId = memContact.id
                    }
                }
                // 清理已被匹配到已知联系人的 pending 条目
                let staleKeys = self.pendingNewContacts.keys.filter { key in
                    key.hasPrefix("Speaker_") && !remainingLabels.contains(key)
                }
                if !staleKeys.isEmpty {
                    AppLog.info("[Diar] Cleaning up \(staleKeys.count) stale pending contacts: \(staleKeys.sorted().joined(separator: ", "))")
                    for key in staleKeys {
                        self.pendingNewContacts.removeValue(forKey: key)
                        self.pendingNewEmbeddings.removeValue(forKey: key)
                    }
                }
                
                self.transcriptSegments = aligned
                self.segmentCount = aligned.count
                self.offlineTotalSegments = aligned.count
                self.offlineProgressFraction = 1.0
                self.saveSegmentsToDatabase(meetingId: meetingId)
                self.isTranscribingOffline = false
                let allLabeled = aligned.filter { $0.isFinal }.allSatisfy { !$0.speakerLabel.isEmpty && $0.speakerLabel != "?" }
                safeUpdateStatus(id: meetingId, status: allLabeled ? .completed : .pendingDiarization)
                
                self.analysisCompletionMessage = loc("diarization_complete_msg")
            }
        }
    }

    private func runOfflineTranscription(for meetingId: String, audioURL: URL) {
        transcriptionTask?.cancel()

        AppLog.info("Offline transcription + diarization started: meeting=\(meetingId)")
        safeUpdateStatus(id: meetingId, status: .processingLlm)
        isTranscribingOffline = true

        // 保存实时录音阶段的声纹标签（离线完成后按时间重叠恢复，防止 diarization 互换标签）
        let savedRealtimeSegments = self.transcriptSegments.filter { $0.isFinal && !$0.text.isEmpty }

        // 使用实时段作为初始显示基础（保留已有的文本和声纹人标签），
        // 仅在实时段未覆盖的时间区域填充占位段
        let realtimeSegs = savedRealtimeSegments.sorted { $0.startTime < $1.startTime }
        let totalDuration = Double(currentMeeting?.duration ?? 0)
        let hasRealtimeSegments = !realtimeSegs.isEmpty

        if hasRealtimeSegments {
            // 实时录音场景：保留实时段 + 间隙占位段
            let estimatedTotal = max(realtimeSegs.count, max(1, Int(ceil(totalDuration / 3.0))))
            self.offlineTotalSegments = estimatedTotal

            var displaySegments: [TranscriptSegment] = realtimeSegs
            if totalDuration > 0 {
                // 在实时段之间的间隙和末尾填充占位段
                var cursor: Double = 0
                var placeholderIdx = 0
                for seg in realtimeSegs {
                    if seg.startTime > cursor + 0.3 {
                        let gapCount = max(1, Int(ceil((seg.startTime - cursor) / 3.0)))
                        for i in 0..<gapCount {
                            let pStart = cursor + Double(i) * (seg.startTime - cursor) / Double(gapCount)
                            let pEnd = cursor + Double(i + 1) * (seg.startTime - cursor) / Double(gapCount)
                            displaySegments.append(TranscriptSegment(
                                id: "placeholder_seed_\(meetingId)_\(placeholderIdx)",
                                startTime: pStart, endTime: pEnd,
                                text: "", speakerLabel: "?",
                                isFinal: true, isPlaceholder: true
                            ))
                            placeholderIdx += 1
                        }
                    }
                    cursor = max(cursor, seg.endTime)
                }
                // 末尾填充
                if cursor < totalDuration - 0.3 {
                    let remaining = totalDuration - cursor
                    let extraCount = max(1, Int(ceil(remaining / 3.0)))
                    for i in 0..<extraCount {
                        let pStart = cursor + Double(i) * remaining / Double(extraCount)
                        let pEnd = cursor + Double(i + 1) * remaining / Double(extraCount)
                        displaySegments.append(TranscriptSegment(
                            id: "placeholder_seed_\(meetingId)_\(placeholderIdx)",
                            startTime: pStart, endTime: min(totalDuration, pEnd),
                            text: "", speakerLabel: "?",
                            isFinal: true, isPlaceholder: true
                        ))
                        placeholderIdx += 1
                    }
                }
            }
            // 若没有任何实时段，至少保证一个占位段
            if displaySegments.isEmpty {
                displaySegments.append(TranscriptSegment(
                    id: "placeholder_seed_\(meetingId)_0",
                    startTime: 0, endTime: max(1, totalDuration),
                    text: "", speakerLabel: "?",
                    isFinal: true, isPlaceholder: true
                ))
            }
            displaySegments.sort { $0.startTime < $1.startTime }
            self.transcriptSegments = displaySegments
            self.segmentCount = 0  // 重新分析时段数从 0 起步重新累加
        } else {
            // 导入音频场景：不预建占位段，Whisper 产出逐步追加显示
            self.offlineTotalSegments = 0
            self.transcriptSegments = []
            self.segmentCount = 0
        }
        self.offlineProgressFraction = 0
        self.processedDiarizationDuration = 0
        if let m = self.currentMeeting, m.duration > 0 {
            self.totalAudioDuration = Double(m.duration)
        } else {
            self.totalAudioDuration = 0
        }

        // 消费者累积的真实段（与占位段分开管理）
        // var consumerRealSegments: [TranscriptSegment] = []

        // 消息通道：后台生产 → 前台消费
        let segmentQueue = DispatchQueue(label: "segment.q")
        var pendingChunks: [[TranscriptSegment]] = []

        // 使用 actor 安全共享声纹分离结果，替代 UnsafeMutablePointer
        let sharedState = DiarSharedState()

        // 前台消费者：每 0.3s 批量读取，如有声纹分离结果则即时对齐
        let consumerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var saveCounter = 0
            var realSeenIds = Set<String>()  // 已出现的真实段 ID（排除占位段）
            while !Task.isCancelled {
                var batch: [TranscriptSegment] = []
                segmentQueue.sync { batch = pendingChunks.flatMap { $0 }; pendingChunks = [] }
                if !batch.isEmpty {
                    var newReal: [TranscriptSegment] = []
                    for seg in batch where !realSeenIds.contains(seg.id) {
                        // 过滤 Whisper 可能产出的空文本段（必须在 insert 之前，否则会阻挡后续同 ID 的有文本版本）
                        guard !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        realSeenIds.insert(seg.id)
                        newReal.append(seg)
                    }
                    if !newReal.isEmpty {
                        // 仅追踪段到达，不更新进度（进度以声纹分离 onProgress 回调为准）
                    }
                }

                // 无论是否有新 Whisper 段，始终检查声纹分离结果并对齐标签
                let existingReal = self.transcriptSegments.filter { !$0.isPlaceholder }
                if let diar = await sharedState.getDiarSegments(), !diar.isEmpty {
                    let diarSpeakerCount = Set(diar.map(\.speakerId)).count
                    let hasUnlabeled = existingReal.contains { $0.speakerLabel.hasPrefix("Speaker_") || $0.speakerLabel == "?" }
                    if hasUnlabeled || !batch.isEmpty {
                        if !batch.isEmpty {
                            AppLog.info("[Consumer] aligning \(existingReal.count) existing + \(batch.count) new segments with \(diar.count) diar segments (\(diarSpeakerCount) speakers)")
                        } else if hasUnlabeled {
                            AppLog.info("[Consumer] retro-aligning \(existingReal.count) unlabeled segments with \(diar.count) diar segments (\(diarSpeakerCount) speakers)")
                        }
                        var allReal = existingReal
                        // 合并新到达的段
                        for seg in batch where !allReal.contains(where: { $0.id == seg.id }) {
                            if !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                allReal.append(seg)
                            }
                        }
                        allReal.sort { $0.startTime < $1.startTime }

                        var customLabels: [String: (label: String, contactId: String?)] = [:]
                        for seg in allReal {
                            if !seg.speakerLabel.isEmpty && !seg.speakerLabel.hasPrefix("Speaker_") && seg.speakerLabel != "?" {
                                customLabels[seg.id] = (seg.speakerLabel, seg.contactId)
                            }
                        }
                        // 正确做法：使用时间轴重叠度进行对齐，而不是按索引强行映射
                        let aligned = SpeakerAlignmentService.align(transcripts: allReal, diarization: diar)
                        var finalAligned = aligned
                        if !customLabels.isEmpty {
                            finalAligned = aligned.map { seg in
                                var s = seg
                                if let saved = customLabels[seg.id] {
                                    s.speakerLabel = saved.label
                                    s.contactId = saved.contactId
                                }
                                return s
                            }
                        }
                        if let autoMap = await sharedState.getSpeakerMap(), !autoMap.isEmpty {
                            finalAligned = finalAligned.map { seg in
                                var s = seg
                                if let match = autoMap[seg.speakerLabel] {
                                    s.speakerLabel = match.name
                                    s.contactId = match.contactId
                                }
                                return s
                            }
                            // 仅更新 UI 标签与与会者列表，联系人声纹持久化在最终收尾块统一执行
                            for (_, match) in autoMap {
                                self.addAttendee(match.name)
                            }
                        }

                        // 重建显示列表
                        if self.offlineTotalSegments > 0 {
                            let needed = max(0, self.offlineTotalSegments - finalAligned.count)
                            let fillPlaceholders: [TranscriptSegment] = (0..<needed).map { i in
                                TranscriptSegment(
                                    id: "placeholder_fill_\(meetingId)_\(i)",
                                    startTime: 0, endTime: 0,
                                    text: "", speakerLabel: "?",
                                    isFinal: true, isPlaceholder: true
                                )
                            }
                            self.transcriptSegments = finalAligned + fillPlaceholders
                        } else {
                            self.transcriptSegments = finalAligned
                        }
                        self.segmentCount = max(self.segmentCount, finalAligned.count)
                    }
                } else if !batch.isEmpty {
                    // 声纹分离尚未就绪：仅更新显示（无标签）
                    var allReal = existingReal
                    for seg in batch where !allReal.contains(where: { $0.id == seg.id }) {
                        if !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            var newSeg = seg
                            if let pending = self.pendingSpeakerRenames[newSeg.speakerLabel] {
                                newSeg.speakerLabel = pending.newName
                                newSeg.contactId = pending.contactId
                            }
                            allReal.append(newSeg)
                        }
                    }
                    allReal.sort { $0.startTime < $1.startTime }
                    if self.offlineTotalSegments > 0 {
                        let needed = max(0, self.offlineTotalSegments - allReal.count)
                        let fillPlaceholders: [TranscriptSegment] = (0..<needed).map { i in
                            TranscriptSegment(
                                id: "placeholder_fill_\(meetingId)_\(i)",
                                startTime: 0, endTime: 0,
                                text: "", speakerLabel: "?",
                                isFinal: true, isPlaceholder: true
                            )
                        }
                        self.transcriptSegments = allReal + fillPlaceholders
                    } else {
                        self.transcriptSegments = allReal
                    }
                    self.segmentCount = max(self.segmentCount, allReal.count)
                }
                // 基于声纹分离进度实时更新百分比（processedDiarizationDuration 由 onProgress 回调持续驱动）
                if self.totalAudioDuration > 0 {
                    self.offlineProgressFraction = min(self.processedDiarizationDuration / self.totalAudioDuration, 0.99)
                }
                // 每 10 次循环（~3秒）保存中间结果到数据库
                saveCounter += 1
                let realOnly = self.transcriptSegments.filter { !$0.isPlaceholder }
                if saveCounter % 10 == 0 && !realOnly.isEmpty {
                    Task.detached { [weak self, meetingId, realOnly] in
                        await self?.saveSegmentsToDatabase(meetingId: meetingId, segments: realOnly)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(SettingsManager.shared.consumerPollInterval * 1_000_000_000))
                if !self.isTranscribingOffline {
                    // 分析已结束，清理所有残留占位段（停顿/静默区域无实际讲话内容）
                    self.transcriptSegments = self.transcriptSegments.filter { !$0.isPlaceholder }
                    break
                }
            }
        }

        // 提前在主线程组装热词，供离线转写后台管线使用
        let hotwordCats = self.currentMeeting?.hotwordCategories?.components(separatedBy: ",") ?? []
        let industryHws = HotwordPresetsManager.shared.getWords(for: hotwordCats)
        let customHws = hotwordCats.contains("__custom__") ? SettingsManager.shared.hotwords : ""
        let finalHotwords = [industryHws, customHws, self.currentMeeting?.attendees ?? ""].filter { !$0.isEmpty }.joined(separator: " ")

        // 后台生产者
        transcriptionTask = Task.detached { [weak self, finalHotwords] in
            guard let self = self else { return }
            defer {
                consumerTask.cancel()
                // 释放共享状态中的大型数据（声纹和分离结果），它们已被转录段消化
                Task { await sharedState.setDiarization([], embeddings: [:]) }
                Task { @MainActor [weak self] in
                    self?.isTranscribingOffline = false
                    if let self = self {
                        self.processedDiarizationDuration = self.totalAudioDuration
                        self.offlineProgressFraction = 1.0
                    }
                }
            }

            do {
                // 确保 FunASR 离线模型已初始化（传入热词，若热词变更会自动重建识别器）
                if !(await FunASRService.shared.isOfflineReady) {
                    try await FunASRService.shared.initializeOffline(hotwords: finalHotwords)
                } else {
                    // 即使已就绪，也传入热词以触发热词变更时的重建
                    try await FunASRService.shared.initializeOffline(hotwords: finalHotwords)
                }
                // 确保 VAD 已初始化（Silero VAD）
                if !(await FunASRService.shared.isVadReady) {
                    try await FunASRService.shared.initializeVAD()
                }
                // 确保标点恢复模型已初始化
                if SettingsManager.shared.isFunASRPunctAvailable {
                    let punctReady = await FunASRService.shared.isPunctReady
                    if !punctReady {
                        try? await FunASRService.shared.initializePunctuation()
                    }
                }
                try Task.checkCancellation()

                // ═══ Step 1: 加载音频样本并启动交错处理管线 ═══
                AppLog.info("[Diar+ASR] Starting interleaved hybrid diarization and transcription...")
                
                let samples = try await DiarizationService.shared.loadAudioSamples(audioURL)
                let sampleRate = 16000
                
                nonisolated(unsafe) var collectedSegments: [TranscriptSegment] = []
                
                // 开启专门的异步流，让声纹分离引擎（生产者）把切好的 chunk 送给转写引擎（消费者）
                let (chunkStream, chunkContinuation) = AsyncStream<[DiarizedSegment]>.makeStream()
                
                // (热词已在主线程提前组装并通过 finalHotwords 捕获)
                
                let transcriptionWorker = Task.detached { [meetingId, samples, sampleRate, finalHotwords] in
                    for await chunk in chunkStream {
                        _ = try? await FunASRService.shared.transcribeDiarizedSegments(
                            samples: samples,
                            sampleRate: sampleRate,
                            diarSegments: chunk,
                            meetingId: meetingId,
                            hotwords: finalHotwords,
                            onSegment: { segment in
                                collectedSegments.append(segment)
                                // 实时推送到前端展示队列
                                segmentQueue.sync { pendingChunks.append([segment]) }
                            }
                        )
                    }
                }
                
                var diarOutput: DiarizationOutput?
                do {
                    diarOutput = try await DiarizationService.shared.diarizeWithEmbeddings(
                        samples: samples,
                        audioURL: audioURL,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.processedDiarizationDuration = Double(progress) * (self?.totalAudioDuration ?? 0)
                            }
                        },
                        onIncrementalResult: { [weak self] _, embeddings in
                            guard let self = self else { return }
                            await MainActor.run {
                                let knownContacts = self.databaseManager.fetchContactsWithEmbeddings()
                                let matchResult = SpeakerMatcher.match(embeddings: embeddings, against: knownContacts)
                                var autoMap: [String: (name: String, contactId: String)] = [:]
                                for (speakerId, match) in matchResult.highConfidence {
                                    autoMap[speakerId] = (name: match.name, contactId: match.contactId)
                                }
                                if !autoMap.isEmpty {
                                    var changed = false
                                    for i in 0..<self.transcriptSegments.count {
                                        if let match = autoMap[self.transcriptSegments[i].speakerLabel] {
                                            self.transcriptSegments[i].speakerLabel = match.name
                                            self.transcriptSegments[i].contactId = match.contactId
                                            changed = true
                                        }
                                    }
                                    if changed {
                                        // 添加参会人
                                        for name in autoMap.values.map(\.name) {
                                            self.addAttendee(name)
                                        }
                                    }
                                }
                            }
                        },
                        onChunkDiarized: { segments in
                            // 边分离边把新产生的带说话人标签的短句交给 ASR 转写
                            chunkContinuation.yield(segments)
                        }
                    )
                    
                    chunkContinuation.finish()
                    _ = await transcriptionWorker.value // 等待所有已生成的 chunk 转写完毕
                    
                    let speakerCount = Set(diarOutput?.segments.map(\.speakerId) ?? []).count
                    AppLog.info("[Diar] Hybrid diarization complete: \(diarOutput?.segments.count ?? 0) diar segments, \(speakerCount) speakers")
                    if let output = diarOutput {
                        await sharedState.setDiarization(output.segments, embeddings: output.embeddings)
                    }
                } catch {
                    AppLog.warn("[Diar] Diarization failed: \(error.localizedDescription)")
                    chunkContinuation.finish()
                    
                    // 降级：如果声纹分离失败或为空，走全局 VAD-Accum 粗转写
                    _ = try await FunASRService.shared.transcribeVadAccumulated(
                        audioURL: audioURL,
                        meetingId: meetingId,
                        hotwords: finalHotwords,
                        onSegment: { segment in
                            collectedSegments.append(segment)
                            // 实时推送到前端展示队列
                            segmentQueue.sync { pendingChunks.append([segment]) }
                        }
                    )
                }
                
                var uniqueSegments: [String: TranscriptSegment] = [:]
                for seg in collectedSegments {
                    uniqueSegments[seg.id] = seg
                }
                let finalSegments = uniqueSegments.values
                    .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { $0.startTime < $1.startTime }
                AppLog.info("[FunASR] Transcription complete: \(finalSegments.count) sentences generated")

                try Task.checkCancellation()

                let finalDiarOutput = diarOutput
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    var aligned = finalSegments
                    
                    // 保留处理期间用户手动修改的发言人标签（基于时间重叠度匹配）
                    let originalSegments = self.transcriptSegments
                    
                    aligned = aligned.map { seg in
                        var s = seg
                        
                        // 1. 根据时间重叠度寻找最匹配的原始段
                        let overlapping = originalSegments.filter {
                            $0.startTime < s.endTime && $0.endTime > s.startTime
                        }
                        
                        if let bestMatch = overlapping.max(by: { a, b in
                            let overlapA = min(a.endTime, s.endTime) - max(a.startTime, s.startTime)
                            let overlapB = min(b.endTime, s.endTime) - max(b.startTime, s.startTime)
                            return overlapA < overlapB
                        }) {
                            // 优先恢复已被用户手动重命名的发言人（非 Speaker_ 开头）
                            if !bestMatch.speakerLabel.hasPrefix("Speaker_") {
                                s.speakerLabel = bestMatch.speakerLabel
                                s.contactId = bestMatch.contactId
                            }
                        }
                        
                        // 2. 如果之前没有改名，但处于全局待重命名列表中（防止漏网之鱼）
                        if s.speakerLabel.hasPrefix("Speaker_"), let pending = self.pendingSpeakerRenames[s.speakerLabel] {
                            s.speakerLabel = pending.newName
                            s.contactId = pending.contactId
                        }
                        return s
                    }
                    
                    // finalDiarOutput is captured from outside
                    // --- 声纹匹配与联系人替换 ---
                    let matchEmbeddings = finalDiarOutput?.embeddings ?? [:]
                    if !matchEmbeddings.isEmpty {
                        self.lastDiarEmbeddings = matchEmbeddings
                        do {
                            try self.databaseManager.saveMeetingEmbeddings(meetingId: meetingId, embeddings: matchEmbeddings)
                        } catch {
                            AppLog.error("Failed to save voiceprint vectors meeting=\(meetingId): \(error.localizedDescription)")
                        }
                        
                        let knownContacts = self.databaseManager.fetchContactsWithEmbeddings()
                        var matchedSpeakerIds = Set<String>()
                        if !knownContacts.isEmpty {
                            let matchResult = SpeakerMatcher.match(embeddings: matchEmbeddings, against: knownContacts)
                            matchedSpeakerIds = matchResult.matchedSpeakerIds
                            
                            var autoMap: [String: (name: String, contactId: String)] = [:]
                            for (speakerId, match) in matchResult.highConfidence {
                                self.addAttendee(match.name)
                                autoMap[speakerId] = (name: match.name, contactId: match.contactId)
                            }
                            if !autoMap.isEmpty {
                                aligned = aligned.map { seg in
                                    var s = seg
                                    // 仅在未被手动重命名的前提下，应用自动匹配结果
                                    if s.speakerLabel.hasPrefix("Speaker_"), let match = autoMap[s.speakerLabel] {
                                        s.speakerLabel = match.name
                                        s.contactId = match.contactId
                                    }
                                    return s
                                }
                            }
                        }
                        
                        let remainingLabels = Set(aligned.map(\.speakerLabel)).filter { $0.hasPrefix("Speaker_") && !matchedSpeakerIds.contains($0) }
                        for label in remainingLabels {
                            self.addAttendee(label)
                            let memContact = self.getOrCreateMemoryContact(for: label, embedding: matchEmbeddings[label])
                            for i in 0..<aligned.count where aligned[i].speakerLabel == label {
                                aligned[i].contactId = memContact.id
                            }
                        }
                    }
                    
                    self.transcriptSegments = aligned.filter { !$0.isPlaceholder }
                    self.segmentCount = aligned.filter { !$0.isPlaceholder }.count
                    self.offlineTotalSegments = aligned.filter { !$0.isPlaceholder }.count
                    self.offlineProgressFraction = 1.0
                    
                    // 终态持久化，放入后台线程避免卡死 UI
                    Task.detached { [weak self, meetingId, aligned] in
                        await self?.saveSegmentsToDatabase(meetingId: meetingId, segments: aligned)
                    }
                    
                    safeUpdateStatus(id: meetingId, status: .completed)
                    AppLog.info("Offline transcription + diarization complete: \(aligned.count) segments")
                    
                    let finals = aligned.filter { $0.isFinal }
                    var knownSpeakers: [String: Int] = [:]
                    var unknownSpeakers: [String: Int] = [:]
                    for seg in finals {
                        if seg.speakerLabel.hasPrefix("Speaker_") {
                            unknownSpeakers[seg.speakerLabel, default: 0] += 1
                        } else if seg.speakerLabel != "?" {
                            knownSpeakers[seg.speakerLabel, default: 0] += 1
                        }
                    }
                    
                    var msgLines: [String] = []
                    if !knownSpeakers.isEmpty {
                        let knownDetails = knownSpeakers.sorted(by: { $0.value > $1.value })
                            .map { "\($0.key)(\($0.value)句)" }
                            .joined(separator: "，")
                        msgLines.append("已知发言人 \(knownSpeakers.count) 位：\(knownDetails)")
                    }
                    if !unknownSpeakers.isEmpty {
                        let unkTotal = unknownSpeakers.values.reduce(0, +)
                        msgLines.append("未知发言人 \(unknownSpeakers.count) 位，总计发言 \(unkTotal) 句")
                    }
                    if knownSpeakers.isEmpty && unknownSpeakers.isEmpty {
                        msgLines.append("已生成 \(aligned.count) 句转写文本。")
                    }
                    self.analysisCompletionMessage = msgLines.joined(separator: "\n")
                }
            } catch is CancellationError {
                AppLog.warn("Offline transcription cancelled: meeting=\(meetingId)")
                await MainActor.run {
                    self.safeUpdateStatus(id: meetingId, status: .pendingDiarization)
                }
            } catch {
                // 如果消费者已收到回调产出的段，不算完全失败
                let existingCount = await MainActor.run { self.transcriptSegments.count }
                if existingCount > 0 {
                    AppLog.warn("Offline transcription timed out but has \(existingCount) existing segments, using partial results")
                    await MainActor.run {
                        self.saveSegmentsToDatabase(meetingId: meetingId)
                        let allLabeled = self.transcriptSegments.filter { $0.isFinal }.allSatisfy { !$0.speakerLabel.isEmpty && $0.speakerLabel != "?" }
                        self.safeUpdateStatus(id: meetingId, status: allLabeled ? .completed : .pendingDiarization)
                    }
                } else {
                    AppLog.error("Offline transcription failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.errorAlert = "\(loc("err_offline_transcribe_failed"))\n\n\(error.localizedDescription)"
                        self.saveSegmentsToDatabase(meetingId: meetingId)
                        self.safeUpdateStatus(id: meetingId, status: .pendingDiarization)
                    }
                }
            }
        }
    }

    /// 从音频文件元数据提取录制日期
    /// 支持: WAV(BWF bext) / M4A(QuickTime) / MP3(ID3v2) / FLAC(Vorbis Comment)
    private func extractAudioRecordingDate(from url: URL) async -> Date? {
        // 0) WAV: 优先尝试 BWF bext chunk 二进制解析（AVAsset 不暴露 bext）
        if url.pathExtension.lowercased() == "wav",
           let bwfDate = extractBWFOriginationDate(from: url) {
            return bwfDate
        }

        let asset = AVAsset(url: url)

        // 1) 通用元数据（commonMetadata 比 metadata 更可靠）
        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                if item.commonKey == .commonKeyCreationDate,
                   let date = try? await item.load(.dateValue) {
                    AppLog.info("[Import] 从 commonMetadata.creationDate 提取到录制时间: \(date)")
                    return date
                }
            }
        }

        // 2) 遍历所有可用元数据格式（不假定固定格式名）
        if let allFormats = try? await asset.load(.availableMetadataFormats) {
            for format in allFormats {
                let items = try? await asset.loadMetadata(for: format)
                for item in items ?? [] {
                    // 按 commonKey 匹配
                    if item.commonKey == .commonKeyCreationDate,
                       let date = try? await item.load(.dateValue) {
                        AppLog.info("[Import] 从格式 \(format) 的 creationDate 提取到录制时间: \(date)")
                        return date
                    }
                    // 按 key 字符串匹配录制时间键名
                    let keyStr = (item.key as? String) ?? ""
                    let lowerKey = keyStr.lowercased()
                    // QuickTime / iTunes / 通用
                    if lowerKey.hasPrefix("creationdate") || lowerKey.hasPrefix("creation_date")
                        || lowerKey.contains("recordingdate") || lowerKey.contains("recording_date")
                        || lowerKey.contains("recordeddate") || lowerKey.contains("recorded_date")
                        || keyStr == "©day" || keyStr == "date"
                        // ID3v2: TDRC(RecordingTime), TDAT(Date), TYER(Year), TDRL(ReleaseTime)
                        || lowerKey == "tdrc" || lowerKey == "tdat"
                        || lowerKey == "tyer" || lowerKey == "tdrl"
                        // Vorbis Comment (FLAC): DATE, YEAR, DATE_RECORDED, RECORDING_DATE
                        || lowerKey == "date" || lowerKey == "year"
                        || lowerKey == "date_recorded" || lowerKey == "recording_date" {
                        if let date = try? await item.load(.dateValue) {
                            AppLog.info("[Import] 从格式 \(format) key=\(keyStr) 提取到录制时间: \(date)")
                            return date
                        }
                        // 有些元数据把日期存为字符串
                        if let dateStr = try? await item.load(.stringValue) {
                            AppLog.info("[Import] 从格式 \(format) key=\(keyStr) 得到字符串: \(dateStr)")
                            if let parsed = parseDateString(dateStr) {
                                AppLog.info("[Import] 字符串解析为日期: \(parsed)")
                                return parsed
                            }
                        }
                    }
                }
            }
        }

        // 诊断：元数据不存在时打印所有已知键帮助排查
        AppLog.info("[Import] 未提取到录制时间，文件 \(url.lastPathComponent) 的元数据摘要:")
        if let allFormats = try? await asset.load(.availableMetadataFormats) {
            for format in allFormats {
                let items = (try? await asset.loadMetadata(for: format)) ?? []
                for item in items {
                    let keyStr = (item.key as? String) ?? (item.key != nil ? String(describing: item.key!) : "nil")
                    let valPreview: String
                    if let d = try? await item.load(.dateValue) { valPreview = "Date(\(d))" }
                    else if let s = try? await item.load(.stringValue) { valPreview = "\"\(s.prefix(50))\"" }
                    else if let n = try? await item.load(.numberValue) { valPreview = "\(n)" }
                    else {
                        if let v = try? await item.load(.value) {
                            valPreview = "\(String(describing: v).prefix(50))"
                        } else {
                            valPreview = "nil"
                        }
                    }
                    AppLog.info("[Import]   格式=\(format) key=\(keyStr) value=\(valPreview)")
                }
            }
        }

        // 3) 元数据无录制日期，兜底用文件系统创建日期
        if let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
           let creationDate = attrs.creationDate {
            AppLog.info("[Import] 元数据无录制时间，使用文件系统创建日期: \(creationDate)")
            return creationDate
        }

        return nil
    }

    /// 尝试将常见日期字符串格式解析为 Date
    private func parseDateString(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // ISO 8601 全格式
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: trimmed) { return d }
        // 常见自定义格式
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss",
                     "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
                     "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    /// 从 BWF/WAV 的 bext chunk 解析录制日期 (Broadcast Wave Format)
    /// bext 是 RIFF/WAV 的可选扩展 chunk，存储 OriginationDate("yyyy-mm-dd") + OriginationTime("hh-mm-ss")
    private func extractBWFOriginationDate(from url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 读取 RIFF 头: "RIFF"(4) + fileSize(4) + "WAVE"(4)
        guard let riffHeader = try? handle.read(upToCount: 12),
              riffHeader.count == 12,
              String(data: riffHeader[0..<4], encoding: .ascii) == "RIFF",
              String(data: riffHeader[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }

        // 扫描 chunk，找到 "bext"
        while true {
            guard let chunkHeader = try? handle.read(upToCount: 8),
                  chunkHeader.count == 8 else { break }
            let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii) ?? ""
            let chunkSize = chunkHeader.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }

            if chunkID == "bext" {
                // bext 固定字段起始偏移:
                // Description(256) + Originator(32) + OriginatorRef(32) = 320
                // OriginationDate: offset 320, 10 bytes ("yyyy-mm-dd")
                // OriginationTime: offset 330, 8 bytes ("hh-mm-ss")
                guard chunkSize >= 602,
                      let bextData = try? handle.read(upToCount: Int(chunkSize)),
                      bextData.count >= 338 else { return nil }

                let dateStr = String(data: bextData[320..<330], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
                let timeStr = String(data: bextData[330..<338], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""

                // OriginationDate: "yyyy-mm-dd", OriginationTime: "hh-mm-ss" 或 "hh:mm:ss"
                let timeNormalized = timeStr.replacingOccurrences(of: "-", with: ":")
                let combined = "\(dateStr)T\(timeNormalized)"

                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                if let date = df.date(from: combined) {
                    AppLog.info("[Import] 从 BWF bext chunk 提取到录制时间: \(date) (日期=\(dateStr) 时间=\(timeStr))")
                    return date
                }
                // 只有日期没有时间时，用 00:00:00
                df.dateFormat = "yyyy-MM-dd"
                if let date = df.date(from: dateStr) {
                    AppLog.info("[Import] 从 BWF bext chunk 提取到录制日期(无时间): \(date)")
                    return date
                }
                return nil
            }

            // 跳过非 bext chunk (chunk 大小按偶数对齐)
            let skipSize = Int(chunkSize) + (Int(chunkSize) % 2)
            try? handle.seek(toOffset: handle.offset() + UInt64(skipSize))
        }

        return nil
    }

    /// 选音频文件后立即调用：从元数据提取真实录制时间覆盖表单日期
    func updateFormDateFromAudioFile(at url: URL) {
        Task { @MainActor in
            if let recordingDate = await extractAudioRecordingDate(from: url) {
                self.formCreatedAt = recordingDate
                AppLog.info("[Import] 音频录制时间已提取: \(recordingDate)")
            }
        }
    }

    func importAudioFile(from sourceURL: URL, title: String? = nil, location: String? = nil) async {
        let meetingId = UUID().uuidString
        let ext = sourceURL.pathExtension.lowercased()
        let allowedExts = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "caf"]
        guard allowedExts.contains(ext) else {
            errorAlert = "\(loc("err_unsupported_audio_format")): .\(ext)"
            return
        }

        let destDir = SettingsManager.shared.dataDirectory
        let destURL = destDir.appendingPathComponent("audio_\(meetingId).\(ext)")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            errorAlert = "\(loc("err_file_copy_failed")): \(error.localizedDescription)"
            return
        }

        // 探测音频实际时长
        var audioDuration = 0
        if let player = try? AVAudioPlayer(contentsOf: destURL) {
            audioDuration = Int(player.duration)
        }

        let fileName = sourceURL.lastPathComponent
        let fileBaseName = fileName.replacingOccurrences(
            of: ".\(ext)", with: "",
            options: .caseInsensitive
        )
        let meetingTitle = title ?? "\(fileBaseName) \(formattedDate)"
        AppLog.info("importAudioFile title: param=\(title ?? "nil"), fileBaseName=\(fileBaseName), formattedDate=\(formattedDate), result=\(meetingTitle)")

        var parentId: String? = nil
        if shouldExtendLastMeeting {
            parentId = selectedParentMeetingId
        }

        let meeting = Meeting(
            id: meetingId,
            parentMeetingId: parentId,
            title: meetingTitle,
            location: location ?? loc("external_import"),
            audioPath: destURL.path,
            duration: audioDuration,
            status: .pendingDiarization,
            summary: nil,
            createdAt: formCreatedAt,
            updatedAt: formCreatedAt,
            attendees: formAttendees.isEmpty ? nil : formAttendees
        )

        do {
            try databaseManager.createMeeting(meeting)
        } catch {
            errorAlert = "\(loc("err_create_meeting_failed")): \(error.localizedDescription)"
            do {
                try FileManager.default.removeItem(at: destURL)
            } catch {
                AppLog.warn("Failed to clean up imported file dest=\(destURL.lastPathComponent): \(error.localizedDescription)")
            }
            return
        }

        currentMeeting = meeting
        audioPlayer.duration = TimeInterval(audioDuration)
        audioPlayer.currentTime = 0
        transcriptSegments = []
        segmentCount = 0
        offlineTotalSegments = 0
        offlineProgressFraction = 0
        meetingStatus = .reviewing

        runOfflineTranscription(for: meetingId, audioURL: destURL)
    }

    /// 更新当前会议的元数据并写入数据库 (非模态修改用)
    /// 注意：对于声纹分析自动识别的新发言人（Speaker_前缀），仅创建内存 Contact，不立即写入数据库。
    /// 退出会议时根据发言记录数决定是否保存。
    func addAttendee(_ name: String) {
        guard var meeting = currentMeeting else {
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "?" else { return }
        let current = meeting.attendees ?? ""
        var list = current.isEmpty ? [] : current.split(separator: " ").map(String.init)
        guard !list.contains(trimmed) else { return }
        list.append(trimmed)
        let newList = list.joined(separator: " ")
        meeting.attendees = newList
        currentMeeting = meeting

        // 仅对声纹分析自动识别的临时发言人（Speaker_前缀）在内存中创建，不立即写库
        if trimmed.hasPrefix("Speaker_") {
            if pendingNewContacts[trimmed] == nil {
                pendingNewContacts[trimmed] = Contact.create(name: trimmed)
            }
            return
        }

        // 已存在于数据库的联系人：仅更新会议元数据，不重复创建
        if databaseManager.fetchContact(byName: trimmed) != nil {
            do {
                try databaseManager.updateMeetingInfo(
                    id: meeting.id,
                    title: meeting.title,
                    location: meeting.location,
                    createdAt: meeting.createdAt,
                    attendees: newList
                )
            } catch {
                AppLog.error("addAttendee update meeting info failed meeting=\(meeting.id): \(error.localizedDescription)")
            }
            return
        }

        // 非 Speaker_ 前缀的全新联系人：暂存内存，退出时统一确认保存
        let contact = Contact.create(name: trimmed)
        pendingNewContacts[trimmed] = contact
        AppLog.info("addAttendee: new contact '\(trimmed)' deferred to exit confirmation")
        do {
            try databaseManager.updateMeetingInfo(
                id: meeting.id,
                title: meeting.title,
                location: meeting.location,
                createdAt: meeting.createdAt,
                attendees: newList
            )
        } catch {
            AppLog.error("addAttendee update meeting info failed meeting=\(meeting.id): \(error.localizedDescription)")
        }
    }

    /// 获取或创建内存中的临时联系人（仅 Speaker_ 前缀的声纹分析新发言人）
    /// - Returns: 内存 Contact（同时记录声纹向量用于比对）
    func getOrCreateMemoryContact(for label: String, embedding: [Float]? = nil) -> Contact {
        if let existing = pendingNewContacts[label] {
            if let emb = embedding, !emb.isEmpty {
                pendingNewEmbeddings[label] = emb
            }
            return existing
        }
        let contact = Contact.create(name: label)
        pendingNewContacts[label] = contact
        if let emb = embedding, !emb.isEmpty {
            pendingNewEmbeddings[label] = emb
        }
        return contact
    }

    /// 将声纹向量合并到指定联系人（加权平均，不覆盖已有声纹）
    func saveEmbeddingForSpeaker(speakerLabel: String, contactId: String) {
        // 优先级：pendingNewEmbeddings（会议整理中暂存）> lastDiarEmbeddings（声纹完成回调）> DB 存档
        var embeddings = pendingNewEmbeddings
        if embeddings.isEmpty {
            embeddings = lastDiarEmbeddings ?? [:]
        }
        if embeddings.isEmpty, let meetingId = currentMeeting?.id {
            embeddings = databaseManager.fetchMeetingEmbeddings(meetingId: meetingId)
        }
        guard !embeddings.isEmpty else {
            AppLog.info("saveEmbeddingForSpeaker: no embedding found for \(speakerLabel)")
            return
        }
        // 计算该发言人在本次会议中的总发言时长，用于时长加权
        let totalDuration = transcriptSegments
            .filter { $0.speakerLabel == speakerLabel }
            .reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        if let emb = embeddings[speakerLabel] {
            do {
                try databaseManager.mergeContactEmbedding(contactId: contactId, newEmbedding: emb, newDuration: Float(totalDuration))
                AppLog.info("saveEmbeddingForSpeaker merged \(speakerLabel) -> \(contactId), duration=\(String(format: "%.1f", totalDuration))s")
            } catch {
                AppLog.error("saveEmbeddingForSpeaker failed speaker=\(speakerLabel): \(error.localizedDescription)")
            }
        } else {
            AppLog.warn("saveEmbeddingForSpeaker failed: no embedding found for \(speakerLabel)")
        }
    }

    func updateMeetingMetadata(title: String, location: String?, createdAt: Date, attendees: String, hotwordCategories: String? = nil, duration: Int? = nil) {
        guard var meeting = currentMeeting else { return }
        meeting.title = title
        meeting.location = location
        meeting.createdAt = createdAt
        meeting.attendees = attendees
        meeting.hotwordCategories = hotwordCategories
        if let d = duration {
            meeting.duration = d
        }
        
        do {
            try databaseManager.updateMeetingInfo(
                id: meeting.id,
                title: title,
                location: location,
                createdAt: createdAt,
                attendees: attendees,
                hotwordCategories: hotwordCategories,
                duration: duration
            )
            currentMeeting = meeting
        } catch {
            AppLog.error("updateMeetingMetadata failed meeting=\(meeting.id): \(error.localizedDescription)")
        }
    }
    
    // MARK: - 持久化与加载
    
    /// 从数据库加载历史转写记录
    func loadSegmentsFromDatabase(meetingId: String) {
        let clips = databaseManager.fetchSpeechClips(meetingId: meetingId)
        AppLog.info("[Load] loadSegmentsFromDatabase meeting=\(meetingId) clips=\(clips.count)")
        // 打印前 5 个 clip 的 speakerLabel/contactId 用于诊断
        for (i, clip) in clips.prefix(5).enumerated() {
            AppLog.info("[Load]   clip[\(i)] speakerLabel='\(clip.speakerLabel)' contactId=\(clip.contactId ?? "nil")")
        }
        transcriptSegments = clips.map { clip in
            TranscriptSegment(
                id: clip.id,
                startTime: clip.startTime,
                endTime: clip.endTime,
                text: clip.originalText,
                speakerLabel: clip.speakerLabel,
                contactId: clip.contactId,
                isFinal: true
            )
        }
        // 修正历史数据：若状态为 completed 但实际段未全部标注，回退为 pendingDiarization
        if let meeting = currentMeeting, meeting.status == .completed {
            let allLabeled = transcriptSegments.allSatisfy { !$0.speakerLabel.isEmpty && $0.speakerLabel != "?" }
            if !allLabeled {
                safeUpdateStatus(id: meetingId, status: .pendingDiarization)
            }
        }
    }
    
    /// 将指定的片段持久化到数据库（使用事务确保原子性，设计为可在后台线程运行）
    func saveSegmentsToDatabase(meetingId: String, segments: [TranscriptSegment]? = nil) {
        let segmentsToSave = segments ?? self.transcriptSegments
        
        Task { @MainActor in
            guard self.databaseManager.meetingExists(id: meetingId) else {
                AppLog.info("saveSegmentsToDatabase: meeting \(meetingId) no longer exists, skipping")
                return
            }
            let count = segmentsToSave.count
            AppLog.info("[Save] saveSegmentsToDatabase meeting=\(meetingId) segments=\(count)")

            if count == 0 {
                let existingCount = self.databaseManager.fetchSpeechClipsCount(meetingId: meetingId)
                if existingCount > 0 {
                    AppLog.warn("[Save] Refusing to overwrite \(existingCount) existing DB clips with 0 in-memory segments for meeting \(meetingId)")
                    return
                }
            }

            do {
                try self.databaseManager.beginTransaction()
                do {
                    try self.databaseManager.deleteSpeechClips(meetingId: meetingId)
                    var savedCount = 0
                    for segment in segmentsToSave {
                        let clip = SpeechClip(
                            id: segment.id,
                            meetingId: meetingId,
                            speakerLabel: segment.speakerLabel,
                            contactId: segment.contactId,
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            originalText: segment.text,
                            cleanedText: nil,
                            audioClipPath: nil,
                            isKeyClip: false
                        )
                        try self.databaseManager.saveSpeechClip(clip)
                        savedCount += 1
                    }
                    try self.databaseManager.commitTransaction()
                    AppLog.info("[Save] Saved \(savedCount)/\(count) segments to DB meeting=\(meetingId)")
                } catch {
                    try self.databaseManager.rollbackTransaction()
                    AppLog.error("[Save] Transaction rolled back for meeting \(meetingId): \(error.localizedDescription)")
                }
            } catch {
                AppLog.error("Failed to save transcript segments meeting=\(meetingId): \(error.localizedDescription)")
            }
        }
    }

    /// 更新片段文本
    func updateSegmentText(id: String, newText: String) {
        if let index = transcriptSegments.firstIndex(where: { $0.id == id }) {
            transcriptSegments[index].text = newText
        }
    }

    func mergeWithPrevious(segmentId: String) {
        guard let index = transcriptSegments.firstIndex(where: { $0.id == segmentId }), index > 0 else { return }
        let current = transcriptSegments[index]
        let previous = transcriptSegments[index - 1]
        guard current.speakerLabel == previous.speakerLabel else { return }

        let merged = TranscriptSegment(
            id: previous.id,
            startTime: previous.startTime,
            endTime: current.endTime,
            text: previous.text + "\n" + current.text,
            speakerLabel: previous.speakerLabel,
            contactId: previous.contactId,
            isFinal: true
        )
        transcriptSegments[index - 1] = merged
        transcriptSegments.remove(at: index)
    }

    func updateLocalSpeakerLabel(id: String, newLabel: String) {
        guard let index = transcriptSegments.firstIndex(where: { $0.id == id }) else { return }
        var contact = databaseManager.fetchContact(byName: newLabel)
        if contact == nil {
            let newContact = Contact.create(name: newLabel)
            do {
                try databaseManager.saveContact(newContact)
                contact = newContact
            } catch {
                AppLog.warn("updateLocalSpeakerLabel create contact failed name=\(newLabel): \(error.localizedDescription)")
            }
        }
        transcriptSegments[index].speakerLabel = newLabel
        transcriptSegments[index].contactId = contact?.id
    }

    /// 拆分气泡片段并分配说话人
    func splitSegment(id: String, text1: String, text2: String, newSpeakerForPart2: String? = nil) {
        guard let index = transcriptSegments.firstIndex(where: { $0.id == id }) else { return }
        let original = transcriptSegments[index]
        
        let totalDuration = original.endTime - original.startTime
        let totalChars = max(1, text1.count + text2.count)
        let ratio = Double(text1.count) / Double(totalChars)
        let splitTime = original.startTime + totalDuration * ratio
        
        var speaker2 = original.speakerLabel
        var contactId2 = original.contactId
        
        if let newSpeaker = newSpeakerForPart2?.trimmingCharacters(in: .whitespaces), !newSpeaker.isEmpty {
            speaker2 = newSpeaker
            var contact = databaseManager.fetchContact(byName: newSpeaker)
            if contact == nil {
                let newContact = Contact.create(name: newSpeaker)
                do {
                    try databaseManager.saveContact(newContact)
                    contact = newContact
                } catch {
                    AppLog.warn("splitSegment create contact failed name=\(newSpeaker): \(error.localizedDescription)")
                }
            }
            contactId2 = contact?.id
        }
        
        let seg1 = TranscriptSegment(
            id: UUID().uuidString,
            startTime: original.startTime,
            endTime: splitTime,
            text: text1,
            speakerLabel: original.speakerLabel,
            contactId: original.contactId,
            isFinal: original.isFinal
        )
        
        let seg2 = TranscriptSegment(
            id: UUID().uuidString,
            startTime: splitTime,
            endTime: original.endTime,
            text: text2,
            speakerLabel: speaker2,
            contactId: contactId2,
            isFinal: original.isFinal
        )
        
        // 更新内存数组
        transcriptSegments.remove(at: index)
        transcriptSegments.insert(seg2, at: index)
        transcriptSegments.insert(seg1, at: index)
        
        // 同步持久化到数据库
        if let meetingId = currentMeeting?.id {
            // 转为 SpeechClip 进行更新
            let clip1 = SpeechClip(id: seg1.id, meetingId: meetingId, speakerLabel: seg1.speakerLabel, contactId: seg1.contactId, startTime: seg1.startTime, endTime: seg1.endTime, originalText: seg1.text, cleanedText: nil, audioClipPath: nil, isKeyClip: false)
            let clip2 = SpeechClip(id: seg2.id, meetingId: meetingId, speakerLabel: seg2.speakerLabel, contactId: seg2.contactId, startTime: seg2.startTime, endTime: seg2.endTime, originalText: seg2.text, cleanedText: nil, audioClipPath: nil, isKeyClip: false)
            
            do {
                try databaseManager.splitSpeechClip(oldClipId: original.id, newClip1: clip1, newClip2: clip2)
            } catch {
                AppLog.error("splitSpeechClip failed oldClip=\(original.id): \(error.localizedDescription)")
            }
        }
    }

    /// 获取当前所有片段中出现的不重复说话人列表
    var uniqueSpeakers: [String] {
        var speakers = Set<String>()
        for segment in transcriptSegments {
            if !segment.speakerLabel.isEmpty && segment.speakerLabel != "?" {
                speakers.insert(segment.speakerLabel)
            }
        }
        return Array(speakers).sorted()
    }

    /// 全局重命名说话人（并同步更新所有相关片段）
    func globalRenameSpeaker(oldName: String, newName: String, contactId: String? = nil) {
        guard oldName != newName else { return }
        var cid = contactId
        if cid == nil, let contact = databaseManager.fetchContact(byName: newName) {
            cid = contact.id
        } else if cid == nil {
            let contact = Contact.create(name: newName)
            do {
                try databaseManager.saveContact(contact)
                cid = contact.id
            } catch {
                AppLog.warn("globalRenameSpeaker create contact failed name=\(newName): \(error.localizedDescription)")
            }
        }
        // 先保存声纹（此时 transcriptSegments 中 speakerLabel 仍为 oldName，时长计算正确）
        if let id = cid {
            saveEmbeddingForSpeaker(speakerLabel: oldName, contactId: id)
        }
        // 再将所有段的标签改为新名称
        for i in 0..<transcriptSegments.count {
            if transcriptSegments[i].speakerLabel == oldName {
                transcriptSegments[i].speakerLabel = newName
                if let id = cid {
                    transcriptSegments[i].contactId = id
                }
            }
        }

        // 记录待持久化的重命名：退出会议时统一写入 DB
        if let id = cid {
            pendingSpeakerRenames[oldName] = (newName: newName, contactId: id)
        }
        
        // 实时同步到数据库
        if let meeting = currentMeeting {
            let meetingId = meeting.id
            Task { @MainActor in
                self.addAttendee(newName)
                self.saveSegmentsToDatabase(meetingId: meetingId)
            }
        }
    }

    /// 更新片段发言人标签
    func updateSpeakerLabel(id: String, newLabel: String) {
        if let index = transcriptSegments.firstIndex(where: { $0.id == id }) {
            let oldLabel = transcriptSegments[index].speakerLabel
            globalRenameSpeaker(oldName: oldLabel, newName: newLabel)
        }
    }

    /// 返回首页（含新发言人保存确认逻辑）
    func finishReview() {
        AppLog.info("[Exit] finishReview called, pendingNewContacts=\(pendingNewContacts.count), transcriptSegments=\(transcriptSegments.count)")
        for (label, contact) in pendingNewContacts {
            let clipCount = transcriptSegments.filter { $0.contactId == contact.id }.count
            AppLog.info("[Exit] pendingNewContacts['\(label)'] id=\(contact.id) clips=\(clipCount)")
        }
        transcriptionTask?.cancel()
        if let meeting = currentMeeting {
            saveSegmentsToDatabase(meetingId: meeting.id)
            // 保存实际音频时长到数据库
            let actualDuration = Int(audioPlayer.duration)
            if actualDuration > 0 && actualDuration != meeting.duration {
                do {
                    try databaseManager.updateMeetingInfo(
                        id: meeting.id,
                        title: meeting.title,
                        location: meeting.location,
                        createdAt: meeting.createdAt,
                        attendees: meeting.attendees,
                        duration: actualDuration
                    )
                } catch {
                    AppLog.warn("Failed to update audio duration meeting=\(meeting.id): \(error.localizedDescription)")
                }
            }
        }

        // 检查临时新发言人的发言记录数
        let newContactsWithClips = pendingNewContacts.filter { (label, contact) in
            let clipCount = transcriptSegments.filter { $0.contactId == contact.id }.count
            return clipCount > 0
        }
        let contactsWithNoClips = pendingNewContacts.filter { (label, contact) in
            let clipCount = transcriptSegments.filter { $0.contactId == contact.id }.count
            return clipCount == 0
        }

        // 发言记录为 0 的自动清理，不写入数据库
        for (label, _) in contactsWithNoClips {
            pendingNewContacts.removeValue(forKey: label)
            pendingNewEmbeddings.removeValue(forKey: label)
            AppLog.info("[Exit] Auto-discard new speaker '\(label)' (0 speech clips)")
        }

        // 有发言记录的新发言人 → 弹窗确认
        if !newContactsWithClips.isEmpty {
            AppLog.info("[Exit] Showing SaveNewContactsSheet with \(newContactsWithClips.count) new speakers")
            pendingNewContactsToPrompt = Array(newContactsWithClips.values)
            selectedPendingContactIds = Set(pendingNewContactsToPrompt.map(\.id))
            showSaveNewContactsAlert = true
            return // 暂停退出，等用户选择
        }

        AppLog.info("[Exit] No new contacts with clips, finalizing exit")
        // 无待确认的新发言人 → 直接退出
        finalizeExit()
    }

    /// 用户确认保存勾选的新发言人（不传参时用 selectedPendingContactIds 过滤）
    func confirmSaveNewContacts(_ contacts: [Contact] = []) {
        let toSave = contacts.isEmpty
            ? pendingNewContactsToPrompt.filter { selectedPendingContactIds.contains($0.id) }
            : contacts
        for contact in toSave {
            do {
                try databaseManager.saveContact(contact)
                AppLog.info("[Exit] Saved new contact '\(contact.name)' to database")
            } catch {
                AppLog.error("[Exit] Failed to save new contact '\(contact.name)': \(error.localizedDescription)")
            }
            // 同时保存声纹向量
            if let emb = pendingNewEmbeddings[contact.name], !emb.isEmpty {
                do {
                    try databaseManager.saveContactEmbedding(contactId: contact.id, embedding: emb)
                } catch {
                    AppLog.warn("[Exit] Failed to save embedding for '\(contact.name)': \(error.localizedDescription)")
                }
            }
        }
        // 已保存的联系人：将 contactId 回写到对应 speakerLabel 的发言片段
        if !toSave.isEmpty, let meetingId = currentMeeting?.id {
            let nameToId: [String: String] = Dictionary(uniqueKeysWithValues: toSave.map { ($0.name, $0.id) })
            let clips = databaseManager.fetchSpeechClips(meetingId: meetingId)
            var backfillCount = 0
            for clip in clips {
                if let cid = nameToId[clip.speakerLabel], clip.contactId == nil {
                    try? databaseManager.updateSpeechClipContact(
                        clipId: clip.id,
                        speakerLabel: clip.speakerLabel,
                        contactId: cid
                    )
                    backfillCount += 1
                }
            }
            AppLog.info("[Exit] confirmSaveNewContacts: backfilled contactId for \(backfillCount)/\(clips.count) clips")
        }
        // 未勾选的联系人：保留可读名称到 speakerLabel，清除 contactId
        let discardedIds = Set(pendingNewContactsToPrompt.map(\.id)).subtracting(Set(toSave.map(\.id)))
        if !discardedIds.isEmpty, let meetingId = currentMeeting?.id {
            let nameMap: [String: String] = Dictionary(uniqueKeysWithValues:
                pendingNewContactsToPrompt.filter { discardedIds.contains($0.id) }.map { ($0.id, $0.name) }
            )
            AppLog.info("[Exit] confirmSaveNewContacts: discardedIds=\(discardedIds), nameMap=\(nameMap)")
            let clips = databaseManager.fetchSpeechClips(meetingId: meetingId)
            AppLog.info("[Exit] confirmSaveNewContacts: fetched \(clips.count) clips from DB for meeting \(meetingId)")
            var updatedCount = 0
            for clip in clips {
                if let cid = clip.contactId, discardedIds.contains(cid),
                   let readableName = nameMap[cid] {
                    try? databaseManager.updateSpeechClipContact(
                        clipId: clip.id,
                        speakerLabel: readableName,
                        contactId: nil
                    )
                    updatedCount += 1
                }
            }
            AppLog.info("[Exit] confirmSaveNewContacts: updated \(updatedCount)/\(clips.count) clips for discarded speakers")
        }
        showSaveNewContactsAlert = false
        selectedPendingContactIds = []
        pendingNewContactsToPrompt = []
        finalizeExit()
    }

    /// 用户放弃保存新发言人：将发言片段的 speakerLabel 更新为联系人名称，并清除 contactId
    func discardNewContacts() {
        guard let meetingId = currentMeeting?.id else {
            showSaveNewContactsAlert = false
            selectedPendingContactIds = []
            pendingNewContactsToPrompt = []
            finalizeExit()
            return
        }
        // 建立 pending contact id → 可读名称的映射
        let nameMap: [String: String] = Dictionary(uniqueKeysWithValues:
            pendingNewContactsToPrompt.map { ($0.id, $0.name) }
        )
        let discardedIds = Set(pendingNewContactsToPrompt.map(\.id))
        AppLog.info("[Exit] discardNewContacts: discardedIds=\(discardedIds), nameMap=\(nameMap)")
        let clips = databaseManager.fetchSpeechClips(meetingId: meetingId)
        AppLog.info("[Exit] discardNewContacts: fetched \(clips.count) clips from DB for meeting \(meetingId)")
        var updatedCount = 0
        for clip in clips {
            if let cid = clip.contactId, discardedIds.contains(cid),
               let readableName = nameMap[cid] {
                do {
                    // 保留可读名称到 speakerLabel，清除 contactId
                    try databaseManager.updateSpeechClipContact(
                        clipId: clip.id,
                        speakerLabel: readableName,
                        contactId: nil
                    )
                    updatedCount += 1
                } catch {
                    AppLog.warn("[Exit] Failed to update clip \(clip.id): \(error.localizedDescription)")
                }
            }
        }
        AppLog.info("[Exit] Discarded \(discardedIds.count) new speakers, updated \(updatedCount)/\(clips.count) clips, preserved readable labels")
        showSaveNewContactsAlert = false
        selectedPendingContactIds = []
        pendingNewContactsToPrompt = []
        finalizeExit()
    }

    /// 最终清理并返回首页
    private func finalizeExit() {
        // 取消正在运行的后台分析任务，并等待其安全结束，再释放 ONNX 模型
        // 避免 sherpa-onnx C API 中模型创建/销毁与 ONNX Runtime 全局状态竞态导致崩溃
        let task = transcriptionTask
        transcriptionTask = nil
        task?.cancel()
        
        // 统一持久化：退出前将发言人重命名写回 speech_clips 和 meeting.attendees
        if let meeting = currentMeeting, !pendingSpeakerRenames.isEmpty {
            let clips = databaseManager.fetchSpeechClips(meetingId: meeting.id)
            for clip in clips {
                if let rename = pendingSpeakerRenames[clip.speakerLabel] {
                    try? databaseManager.updateSpeechClipContact(
                        clipId: clip.id, speakerLabel: rename.newName, contactId: rename.contactId
                    )
                }
            }
            // 更新 meeting.attendees：将新名字加入参会列表
            var attendees = (meeting.attendees ?? "").components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for rename in pendingSpeakerRenames.values {
                if !attendees.contains(rename.newName) {
                    attendees.append(rename.newName)
                }
            }
            if attendees != (meeting.attendees ?? "").components(separatedBy: .whitespaces).filter({ !$0.isEmpty }) {
                try? databaseManager.updateMeetingInfo(
                    id: meeting.id, title: meeting.title, location: meeting.location,
                    createdAt: meeting.createdAt,
                    attendees: attendees.joined(separator: " "),
                    duration: meeting.duration
                )
            }
            AppLog.info("[Exit] Persisted \(pendingSpeakerRenames.count) speaker renames")
        }
        
        // 确保会议状态持久化到数据库
        if let meeting = currentMeeting {
            safeUpdateStatus(id: meeting.id, status: .completed)
            AppLog.info("[Exit] finalizeExit: meeting \(meeting.id) status → completed, returning to home")
        }
        pendingNewContacts = [:]
        pendingNewEmbeddings = [:]
        pendingNewContactsToPrompt = []
        pendingSpeakerRenames = [:]
        audioChunks = []
        audioPlayer.stop()
        meetingStatus = .idle
        currentMeeting = nil
        transcriptSegments = []
        recordingDuration = 0
        lastDiarEmbeddings = [:]

        // 释放 sherpa-onnx ONNX 会话 (~500MB-1GB)，下次分析时按需重新加载
        // 先等待已取消的后台任务安全结束，避免与 ONNX Runtime 全局状态竞态
        Task {
            if let t = task {
                _ = await t.value  // 等待 detached task 自然结束（已 cancel，会在下一个 suspension 点抛出）
            }
            await FunASRService.shared.reset()
            await DiarizationService.shared.reset()
        }
    }

    // MARK: - 格式化

    var formattedDuration: String {
        let mins = Int(recordingDuration) / 60
        let secs = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var currentAmplitude: Float {
        audioRecorder.currentAmplitude
    }

    // MARK: - 私有方法

    /// 安全更新会议状态，失败时记录警告而非崩溃
    private func safeUpdateStatus(id: String, status: Meeting.Status, duration: Int? = nil) {
        do {
            try databaseManager.updateMeetingStatus(id: id, status: status, duration: duration)
        } catch {
            AppLog.warn("updateMeetingStatus failed meeting=\(id) status=\(status.rawValue): \(error.localizedDescription)")
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// 实时更新 AudioChunk 的文本（用户手动编辑）
    func updateChunkText(chunkId: String, newText: String) {
        if let idx = audioChunks.firstIndex(where: { $0.id == chunkId }) {
            audioChunks[idx].text = newText
        }
        // 同步到 AudioRecorder 内部状态
        audioRecorder.updateChunkText(chunkId: chunkId, newText: newText)
    }

    private func resetForm() {
        formTitle = ""
        formLocation = ""
        formAttendees = ""
        shouldExtendLastMeeting = false
        selectedParentMeetingId = nil
        formCreatedAt = Date()
        recordingMode = .liveRecording
        formSpeechLang = UserDefaults.standard.string(forKey: "speech_language") ?? "zh"
        formHotwordCategories = []
    }
}

/// 将新区间 (start, end) 合并到已排序无重叠的区间列表中，返回新的并集
private func mergeInterval(_ intervals: [(Double, Double)], _ new: (Double, Double)) -> [(Double, Double)] {
    var result = intervals
    result.append(new)
    result.sort { $0.0 < $1.0 }
    var merged: [(Double, Double)] = []
    for interval in result {
        if let last = merged.last, last.1 >= interval.0 {
            merged[merged.count - 1].1 = max(last.1, interval.1)
        } else {
            merged.append(interval)
        }
    }
    return merged
}
