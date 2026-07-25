import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

/// 录音结束后的回顾页面
struct ReviewingView: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(DatabaseManager.self) private var databaseManager
    @State private var activeSegmentId: String? = nil
    @State private var showInspector = true
    @State private var filterSpeaker: String? = nil
    @State private var attendeesString: String = ""
    @State private var showDebugLog = false
    @State private var showRetryConfirm = false
    @State private var pendingRetryAction: (() -> Void)?
    @State private var queuedSegments: [TranscriptSegment] = []
    @State private var queueIndex = 0
    @State private var activeSegmentDebounceTask: Task<Void, Never>?
    @State private var pendingActiveSegmentId: String?
    @State private var playingSegmentId: String?
    @State private var scrollToId: String?
    @State private var flashSegmentId: String?

    // 搜索
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var searchResults: [TranscriptSegment] = []
    @State private var searchIndex = 0
    @FocusState private var isSearchFocused: Bool

    // 语言切换
    @State private var langRefresh = 0

    // 本地桥接 ViewModel 的 showSaveNewContactsAlert，确保 sheet 可靠弹出
    @State private var showSaveSheet = false

    private var retryButtonLabel: String {
        if viewModel.isTranscribingOffline { return loc("analyzing") }
        if viewModel.transcriptSegments.isEmpty { return loc("reanalyze") }
        if diarizationProgressDone { return loc("reanalyze") }
        return loc("continue_analysis")
    }
    
    private var retryButtonIcon: String {
        viewModel.isTranscribingOffline ? "hourglass" : "waveform.badge.magnifyingglass"
    }

    private var analysisStatsText: String? {
        guard !viewModel.transcriptSegments.isEmpty else { return nil }
        let finals = viewModel.transcriptSegments.filter { $0.isFinal }
        let sentences = finals.count
        let speakers = Set(finals.map { $0.speakerLabel }).count
        return "\(sentences)\(loc("sentences_unit")) · \(speakers)\(loc("people_unit"))"
    }
    
    private var diarizationProgressDone: Bool {
        guard !viewModel.transcriptSegments.isEmpty else { return false }
        if viewModel.isTranscribingOffline { return false }
        let finals = viewModel.transcriptSegments.filter { $0.isFinal }
        return finals.allSatisfy { !$0.speakerLabel.isEmpty }
    }
    
    private func formatTimeMMSS(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - 语言切换

    private var langButtonLabel: String {
        switch SettingsManager.shared.langSetting {
        case "zh-Hans": return "简体中文"
        case "en":       return "English"
        default:         return loc("follow_system")
        }
    }

    private var langBadge: String {
        switch SettingsManager.shared.langSetting {
        case "zh-Hans": return "中"
        case "en":       return "EN"
        default:         return "SYS"
        }
    }

    private func cycleLanguage() {
        let current = SettingsManager.shared.langSetting
        if current.isEmpty {
            SettingsManager.shared.langSetting = "zh-Hans"
        } else if current == "zh-Hans" {
            SettingsManager.shared.langSetting = "en"
        } else {
            SettingsManager.shared.langSetting = ""
        }
        SettingsManager.shared.save()
        langRefresh += 1
    }

    private var transcriptionPercent: Int? {
        if viewModel.isTranscribingOffline {
            let pct = Int(viewModel.offlineProgressFraction * 100)
            return max(0, min(99, pct))
        }
        if viewModel.offlineTotalSegments > 0 { return 100 }
        return nil
    }
    
    private var transcriptionProgressText: String {
        let total = viewModel.offlineTotalSegments
        if total > 0 && !viewModel.isTranscribingOffline {
            return String(format: loc("transcribing_segments_done"), viewModel.segmentCount, total, 100)
        }
        let procStr = formatTimeMMSS(viewModel.processedDiarizationDuration)
        let totalStr = formatTimeMMSS(viewModel.totalAudioDuration)
        
        if let pct = transcriptionPercent {
            if viewModel.totalAudioDuration > 0 {
                return String(format: loc("transcribing_segments_with_time"), viewModel.segmentCount, procStr, totalStr, pct)
            } else {
                return String(format: loc("transcribing_segments"), viewModel.segmentCount, pct)
            }
        }
        return loc("transcribing_progress")
    }
    
    @ViewBuilder
    private var reviewToolbar: some View {
        VStack(spacing: 10) {
            // 第一行：继续分析（左对齐）+ 进度数字（右对齐）
            HStack(spacing: 12) {
                if let meeting = viewModel.currentMeeting, meeting.audioFileExists {
                    HStack(spacing: 6) {
                        Button {
                            let url = meeting.localAudioURL
                            if viewModel.transcriptSegments.isEmpty {
                                // 无段 → 直接完整转写
                                viewModel.retryOfflineTranscription(for: meeting.id, audioURL: url)
                            } else if diarizationProgressDone {
                                // 声纹分离已完成 → 弹确认框后重新完整转写
                                pendingRetryAction = { [weak viewModel] in
                                    viewModel?.retryOfflineTranscription(for: meeting.id, audioURL: url)
                                }
                                showRetryConfirm = true
                            } else {
                                // 声纹分离未完成 → 仅继续声纹分离（不重新转写）
                                viewModel.continueOfflineDiarization(for: meeting.id, audioURL: url)
                            }
                        } label: {
                            Label(retryButtonLabel, systemImage: retryButtonIcon)
                                .font(.body)
                                .fontWeight(.medium)
                        }
                        .disabled(viewModel.isTranscribingOffline)
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .controlSize(.regular)
                    }
                }
                Spacer()
                if let text = analysisStatsText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(diarizationProgressDone ? Color.secondary : Color.orange)
                }
            }
            
            // 第二行：导出音频 / 导出纪要 / 拷贝纪要（双图标，紧凑排列）
            HStack(spacing: 8) {
                Button {
                    exportAudioFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.regular)
                .help(loc("export_audio"))
                
                Button {
                    exportMeetingRecord()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext")
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.regular)
                .help(loc("export"))
                
                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.plaintext")
                        Image(systemName: "doc.on.doc")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.regular)
                .help(loc("copy_hint"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var editedAttendeesList: [String] {
        let s = viewModel.currentMeeting?.attendees ?? ""
        if s.isEmpty { return [] }
        return s.split(separator: " ").map(String.init)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !showInspector {
                        meetingSummaryCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    playbackControlPanel

                    if viewModel.isTranscribingOffline && viewModel.transcriptSegments.isEmpty {
                        transcriptionLoadingView
                    } else if !viewModel.isTranscribingOffline && viewModel.transcriptSegments.isEmpty, let meeting = viewModel.currentMeeting {
                        emptyTranscriptView(meeting: meeting)
                    } else {
                        if viewModel.isTranscribingOffline {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text(transcriptionProgressText)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(.blue.opacity(0.06))
                        }
                        transcriptList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    Divider()
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { showInspector = false }
                            } label: {
                                Image(systemName: "sidebar.left")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("关闭属性面板")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        MeetingInfoSidebar(viewModel: viewModel, filterSpeaker: $filterSpeaker, attendeesString: $attendeesString, showSpeakerSections: true)
                            .frame(maxHeight: .infinity)

                        Divider()

                        reviewToolbar
                    }
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
                }
            }
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
            .navigationTitle(loc("review_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.finishReview()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(loc("back"))
                }
                ToolbarItemGroup(placement: .primaryAction) {
#if DEBUG
                    Button {
                        showDebugLog = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .help(loc("debug_log"))
#endif
                    // 搜索按钮
                    Button {
                        withAnimation { showSearch.toggle() }
                        if showSearch {
                            isSearchFocused = true
                        } else {
                            searchText = ""; searchResults = []
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(showSearch ? .purple : .secondary)
                    }
                    .frame(width: 32)
                    .help("搜索")

                    // 向导/帮助（新增，不可用——向导是首页功能）
                    Button {
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .frame(width: 32, height: 32)
                    .help(loc("wizard_help"))
                    .disabled(true)
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                    .frame(width: 32)
                    .help(loc("settings"))

                    // 热词管理（新增）
                    NavigationLink(destination: HotwordsManagementView()) {
                        Image(systemName: "text.book.closed")
                    }
                    .frame(width: 32)
                    .help(loc("wizard_hotwords_title"))

                    NavigationLink(destination: PersonnelManagementView()) {
                        Image(systemName: "person.2")
                    }
                    .frame(width: 32)
                    .help(loc("personnel_voiceprint_help"))

                    // 新建会议（新增，不可用——已在会议中）
                    Button {
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 32)
                    .help(loc("start_meeting"))
                    .disabled(true)

                    // 批量管理（新增，不可用——已在会议中）
                    Button {
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .frame(width: 32)
                    .help(loc("batch_manage"))
                    .disabled(true)

                    // 语言切换（新增）
                    Button {
                        cycleLanguage()
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "globe")
                                .font(.system(size: 15))
                            Text(langBadge)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(x: 4, y: 4)
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help("\(loc("follow_system")) / 简体中文 / English  (当前: \(langButtonLabel))")
                }
            }
            .onAppear {
                attendeesString = viewModel.currentMeeting?.attendees ?? ""
            }
            .onChange(of: viewModel.transcriptSegments.map(\.speakerLabel)) { _, labels in
                for label in labels {
                    let trimmed = label.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("Speaker_"), trimmed != "?" else { continue }
                    addAttendeeFromLabel(trimmed)
                }
            }
            .onChange(of: viewModel.audioPlayer.currentTime) { _, time in
                // 多段时间重叠时，选当前时间离段中点最近的（避开边界歧义）
                let matching = viewModel.transcriptSegments.filter { $0.startTime <= time && $0.endTime >= time }
                let best: TranscriptSegment?
                if matching.count == 1 {
                    best = matching[0]
                } else {
                    best = matching.min(by: { a, b in
                        let midA = (a.startTime + a.endTime) / 2
                        let midB = (b.startTime + b.endTime) / 2
                        return abs(time - midA) < abs(time - midB)
                    })
                }
                guard let targetId = best?.id else { return }
                // 已激活或已在等待中，跳过
                guard targetId != activeSegmentId, targetId != pendingActiveSegmentId else { return }
                // 防抖：延迟 0.15s 再切换底色，吞掉瞬时跳变
                activeSegmentDebounceTask?.cancel()
                pendingActiveSegmentId = targetId
                activeSegmentDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    activeSegmentId = targetId
                    pendingActiveSegmentId = nil
                }
            }
            .onChange(of: viewModel.audioPlayer.isPlaying) { _, playing in
                if !playing && !queuedSegments.isEmpty {
                    // 当前段播完，自动播放下一个
                    playNextQueued()
                }
            }
            .onChange(of: filterSpeaker) { _, _ in
                // 切换/清除说话人过滤时，清空播放队列
                queuedSegments = []
                viewModel.audioPlayer.playbackEndTime = nil
            }
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogView()
        }
        .alert(loc("confirm_retranscribe"), isPresented: $showRetryConfirm) {
            Button(loc("cancel"), role: .cancel) { pendingRetryAction = nil }
            Button(loc("confirm"), role: .destructive) {
                pendingRetryAction?()
                pendingRetryAction = nil
            }
        } message: {
            Text(String(format: loc("confirm_retranscribe_msg"), viewModel.transcriptSegments.count))
        }
        .onChange(of: viewModel.showSaveNewContactsAlert) { _, newValue in
            AppLog.info("[Exit] showSaveNewContactsAlert changed to \(newValue), syncing showSaveSheet")
            showSaveSheet = newValue
        }
        .onChange(of: showSaveSheet) { _, newValue in
            if !newValue && viewModel.showSaveNewContactsAlert {
                AppLog.info("[Exit] Sheet dismissed externally, syncing back to ViewModel")
                viewModel.showSaveNewContactsAlert = false
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveNewContactsSheet(viewModel: viewModel)
        }
        .alert(
            "分析完成",
            isPresented: Binding(
                get: { viewModel.analysisCompletionMessage != nil },
                set: { if !$0 { viewModel.analysisCompletionMessage = nil } }
            )
        ) {
            Button(loc("confirm"), role: .cancel) { viewModel.analysisCompletionMessage = nil }
        } message: {
            Text(viewModel.analysisCompletionMessage ?? "")
        }
    }

    private func addAttendeeFromLabel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "?" else { return }
        let current = attendeesString
        var list = current.isEmpty ? [] : current.split(separator: " ").map(String.init)
        guard !list.contains(trimmed) else {
            return
        }
        list.append(trimmed)
        let newList = list.joined(separator: " ")
        attendeesString = newList
        viewModel.addAttendee(trimmed)
    }

    // MARK: - 空白文本加载视图
    private var transcriptionLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(loc("transcribing_hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyTranscriptView(meeting: Meeting) -> some View {
        VStack(spacing: 12) {
            if viewModel.isTranscribingOffline {
                ProgressView()
                    .controlSize(.large)
                Text(loc("transcribing_progress"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.quaternary)
                if meeting.status == .pendingDiarization || meeting.status == .completed || meeting.status == .processingLlm {
                    Text(loc("transcript_missing"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(loc("transcript_missing_hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if meeting.audioFileExists {
                        Button(loc("rerun_transcription")) {
                            viewModel.isTranscribingOffline = true
                            let url = meeting.localAudioURL
                            viewModel.retryOfflineTranscription(for: meeting.id, audioURL: url)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    } else {
                        Text(loc("audio_file_not_found"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(loc("no_transcript"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Button(loc("load_from_db")) {
                    viewModel.loadSegmentsFromDatabase(meetingId: meeting.id)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.loadSegmentsFromDatabase(meetingId: meeting.id)
        }
    }

    private var transcriptList: some View {
        ZStack(alignment: .topTrailing) {
            UnifiedTranscriptEditor(
                segments: $viewModel.transcriptSegments,
                filterSpeaker: $filterSpeaker,
                activeSegmentId: $activeSegmentId,
                meetingAttendees: $attendeesString,
                scrollToId: $scrollToId,
                searchQuery: searchText,
                flashSegmentId: flashSegmentId,
                onFlashDone: { flashSegmentId = nil },
                contacts: databaseManager.fetchAllContacts().map { $0.name },
                onPlaySegment: { seg in playSegment(seg) },
                onSpeakerChanged: { segId, newSpeaker in
                        // 若是临时发言人，则全局替换；否则仅修改当前这一句的错误归属
                        if let idx = viewModel.transcriptSegments.firstIndex(where: { $0.id == segId }) {
                            let oldLabel = viewModel.transcriptSegments[idx].speakerLabel
                            var contact = databaseManager.fetchContact(byName: newSpeaker)
                            if contact == nil {
                                contact = Contact.create(name: newSpeaker)
                                try? databaseManager.saveContact(contact!)
                            }
                            
                            if oldLabel.hasPrefix("Speaker_") {
                                viewModel.globalRenameSpeaker(oldName: oldLabel, newName: newSpeaker, contactId: contact?.id)
                                // 仅在全局重命名时（旧代号不再存在），才同步切换过滤条件
                                if filterSpeaker == oldLabel {
                                    filterSpeaker = newSpeaker
                                }
                            } else {
                                viewModel.transcriptSegments[idx].speakerLabel = newSpeaker
                                viewModel.transcriptSegments[idx].contactId = contact?.id
                                try? databaseManager.updateSpeechClipContact(
                                    clipId: segId, speakerLabel: newSpeaker, contactId: contact?.id
                                )
                                // 实时同步到数据库
                                if let meetingId = viewModel.currentMeeting?.id {
                                    let segs = viewModel.transcriptSegments
                                    Task { @MainActor in
                                        viewModel.saveSegmentsToDatabase(meetingId: meetingId, segments: segs)
                                    }
                                }
                            }
                        }
                        addAttendeeFromLabel(newSpeaker)
                },
                onTextChanged: { segId, newText in
                    try? databaseManager.updateSpeechClipText(clipId: segId, text: newText)
                }
            )

            // 浮动搜索栏
            if showSearch {
                searchBar
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding()
        .overlay {
            Button("") {
                if let seg = viewModel.transcriptSegments.first(where: { $0.id == activeSegmentId }) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(seg.text, forType: .string)
                }
            }
            .keyboardShortcut("c", modifiers: [.command])
            .opacity(0.001)
            .frame(width: 1, height: 1)
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文本…", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .focused($isSearchFocused)
                .onChange(of: searchText) { _, q in
                    performSearch(q)
                }
                .onSubmit { navigateSearch(1) }

            if !searchResults.isEmpty {
                Text("\(searchIndex + 1)/\(searchResults.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    navigateSearch(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(searchResults.count <= 1)

                Button {
                    navigateSearch(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(searchResults.count <= 1)
            }

            Button {
                showSearch = false
                searchText = ""
                searchResults = []
                isSearchFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    private func performSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            searchResults = []
            searchIndex = 0
            return
        }
        searchResults = viewModel.transcriptSegments
            .filter { $0.isFinal && $0.text.lowercased().contains(q) }
        searchIndex = 0
        if let first = searchResults.first {
            scrollToId = first.id
        }
    }

    private func navigateSearch(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        let seg = searchResults[searchIndex]
        scrollToId = seg.id
        flashSegmentId = seg.id
    }

    // MARK: - 会议信息卡片

    private var meetingSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting = viewModel.currentMeeting {
                HStack {
                    Text(meeting.title)
                        .font(.title3)
                        .fontWeight(.bold)
                    Spacer()
                    Button {
                        withAnimation { showInspector = true }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(loc("meeting_inspector"))
                }
                HStack(spacing: 16) {
                    Label(formatCreatedAt(meeting.createdAt), systemImage: "calendar")
                    if let location = meeting.location {
                        Label(location, systemImage: "mappin")
                    }
                    Label(String(format: loc("segments_count"), viewModel.transcriptSegments.filter { $0.isFinal }.count), systemImage: "text.bubble")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - 音频播放

    private var playbackControlPanel: some View {
        HStack(spacing: 8) {
            Button {
                if viewModel.audioPlayer.isPlaying {
                    viewModel.audioPlayer.pause()
                } else {
                    if let meeting = viewModel.currentMeeting {
                        let url = meeting.localAudioURL
                        if viewModel.audioPlayer.currentTime >= viewModel.audioPlayer.duration - 0.1 || !viewModel.audioPlayer.hasPlayer {
                            viewModel.audioPlayer.startPlaying(url: url)
                        } else {
                            viewModel.audioPlayer.resume()
                        }
                    }
                }
            } label: {
                Image(systemName: viewModel.audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)

            Text(formatTime(viewModel.audioPlayer.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Slider(value: Binding(
                get: { viewModel.audioPlayer.currentTime },
                set: { viewModel.audioPlayer.seek(to: $0) }
            ), in: 0...max(viewModel.audioPlayer.duration, 1.0))
            .tint(.purple)

            Text(formatTime(viewModel.audioPlayer.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            HStack(spacing: 4) {
                Image(systemName: viewModel.audioPlayer.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: Binding(
                    get: { viewModel.audioPlayer.volume },
                    set: { viewModel.audioPlayer.volume = $0 }
                ), in: 0...1.0)
                .frame(width: 80)
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // MARK: - 辅助

    private func exportAudioFile() {
        guard let meeting = viewModel.currentMeeting else { return }
        let sourceURL = meeting.localAudioURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.title = loc("export_audio")
        let ext = sourceURL.pathExtension
        savePanel.nameFieldStringValue = "\(meeting.title).\(ext)"
        if !ext.isEmpty {
            savePanel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .audio]
        }
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let destURL = savePanel.url {
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
        #endif
    }

    private func copyToClipboard() {
        guard let meeting = viewModel.currentMeeting else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let notSpec = loc("not_specified")
        var text = """
        \(String(format: loc("copy_topic"), meeting.title))
        \(String(format: loc("copy_location"), meeting.location ?? notSpec))
        \(String(format: loc("copy_time"), f.string(from: meeting.createdAt)))
        \(String(format: loc("copy_attendees"), meeting.attendees ?? notSpec))

        """

        for seg in viewModel.transcriptSegments.filter({ $0.isFinal }) {
            let time = formatTime(seg.startTime)
            text += "[\(time)] \(seg.speakerLabel): \(seg.text)\n"
        }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatCreatedAt(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func exportMeetingRecord() {
        guard let meeting = viewModel.currentMeeting else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let notSpec = loc("not_specified")

        var text = """
        \(String(format: loc("copy_topic"), meeting.title))
        \(String(format: loc("copy_location"), meeting.location ?? notSpec))
        \(String(format: loc("copy_time"), formatter.string(from: meeting.createdAt)))
        \(String(format: loc("record_duration_fmt"), formatDuration(TimeInterval(meeting.duration))))
        \(String(format: loc("copy_attendees"), meeting.attendees ?? notSpec))
        
        ========================================
        \(loc("export_record_title"))
        ========================================
        
        """

        let segments = viewModel.transcriptSegments.filter { $0.isFinal }
        for seg in segments {
            let time = formatTime(seg.startTime)
            text += "[\(time)] \(seg.speakerLabel): \(seg.text)\n\n"
        }

        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.title = loc("export_meeting_record")
        savePanel.nameFieldStringValue = "\(meeting.title).txt"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let mins = Int(t)/60, secs = Int(t)%60
        return String(format: loc("duration_min_sec"), mins, secs)
    }

    private func playSegment(_ segment: TranscriptSegment) {
        // 同一段再次点击 → 暂停
        if playingSegmentId == segment.id && viewModel.audioPlayer.isPlaying {
            viewModel.audioPlayer.pause()
            return
        }
        playingSegmentId = segment.id
        
        if let meeting = viewModel.currentMeeting {
            let url = meeting.localAudioURL
            if !viewModel.audioPlayer.hasPlayer {
                viewModel.audioPlayer.startPlaying(url: url)
            }
        }
        
        // 如果当前按说话人过滤，构建该说话人的连续播放队列
        if let speaker = filterSpeaker {
            let sameSpeaker = viewModel.transcriptSegments
                .filter { $0.speakerLabel == speaker && $0.isFinal }
                .sorted { $0.startTime < $1.startTime }
            if let idx = sameSpeaker.firstIndex(where: { $0.id == segment.id }) {
                queuedSegments = Array(sameSpeaker.dropFirst(idx + 1))
                queueIndex = 0
            } else {
                queuedSegments = []
            }
        } else {
            queuedSegments = []
        }
        
        viewModel.audioPlayer.playbackEndTime = segment.endTime
        viewModel.audioPlayer.seek(to: segment.startTime)
        if !viewModel.audioPlayer.isPlaying {
            viewModel.audioPlayer.resume()
        }
    }
    
    private func playNextQueued() {
        guard queueIndex < queuedSegments.count else {
            queuedSegments = []
            playingSegmentId = nil
            return
        }
        let seg = queuedSegments[queueIndex]
        queueIndex += 1
        playingSegmentId = seg.id
        // 短暂延迟，让音频引擎完成上一段的停止状态转换
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak viewModel] in
            viewModel?.audioPlayer.playbackEndTime = seg.endTime
            viewModel?.audioPlayer.seek(to: seg.startTime)
            if viewModel?.audioPlayer.isPlaying == false {
                viewModel?.audioPlayer.resume()
            }
        }
    }

}

// MARK: - 退出会议保存新联系人弹窗

struct SaveNewContactsSheet: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(loc("save_new_speakers_title"))
                    .font(.headline)
                Spacer()
                Button(loc("save_new_speakers_discard")) {
                    viewModel.discardNewContacts()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Divider()

            // 说明文字
            Text(String(format: loc("save_new_speakers_msg"), viewModel.pendingNewContactsToPrompt.count, ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            // 全选
            HStack(spacing: 0) {
                let allSelected = viewModel.selectedPendingContactIds.count == viewModel.pendingNewContactsToPrompt.count
                Button {
                    if allSelected {
                        viewModel.selectedPendingContactIds = []
                    } else {
                        viewModel.selectedPendingContactIds = Set(viewModel.pendingNewContactsToPrompt.map(\.id))
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(allSelected ? .purple : .secondary)
                        Text(loc("select_all"))
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(String(format: loc("selected_count_fmt"), viewModel.selectedPendingContactIds.count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 20)

            // 联系人列表
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.pendingNewContactsToPrompt) { contact in
                        let isSelected = viewModel.selectedPendingContactIds.contains(contact.id)
                        Button {
                            if isSelected {
                                viewModel.selectedPendingContactIds.remove(contact.id)
                            } else {
                                viewModel.selectedPendingContactIds.insert(contact.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? .purple : .secondary)
                                Circle()
                                    .fill(personColor(contact.name))
                                    .frame(width: 28, height: 28)
                                    .overlay(Text(String(contact.name.prefix(1))).font(.caption2).foregroundStyle(.white))
                                Text(contact.name)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)

                        if contact.id != viewModel.pendingNewContactsToPrompt.last?.id {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
            }

            Divider()

            // 底部按钮
            HStack {
                Button(loc("save_new_speakers_discard")) {
                    viewModel.discardNewContacts()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                Button(loc("save_new_speakers_save_selected")) {
                    viewModel.confirmSaveNewContacts()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(viewModel.selectedPendingContactIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 400, height: 480)
    }

    private func personColor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .pink, .teal, .indigo, .cyan, .mint]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
