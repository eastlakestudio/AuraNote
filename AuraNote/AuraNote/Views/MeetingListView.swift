import SwiftUI
#if os(macOS)
import AppKit
#endif
import AVFoundation

/// 会议列表页（首页）
struct MeetingListView: View {
    @Bindable var recordingVM: RecordingViewModel
    @Environment(DatabaseManager.self) private var databaseManager
    @State private var listVM: MeetingListViewModel?
    @State private var showPermissionAlert = false
    @State private var permissionAlertMessage = ""
    @State private var showDeleteSheet = false
    @State private var deleteGroupMeetings: [Meeting] = []
    @State private var deleteGroupClipCounts: [String: Int] = [:]
    @State private var downloadStateVersion = 0

    // 批量管理
    @State private var batchSelectMode = false
    @State private var selectedMeetingIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    // 引导向导：nil = 不显示, 0/1/2 = 当前高亮步骤
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var wizardStep: Int? = nil
    // 语言刷新触发器（@Observable 单例静态属性变化不自动触发视图重绘）
    @State private var langRefresh = 0

    private var langButtonLabel: String {
        switch SettingsManager.shared.langSetting {
        case "zh-Hans":
            return "简体中文"
        case "en":
            return "English"
        default:
            return loc("follow_system")
        }
    }

    /// 按钮上显示的短标记（中 / EN / SYS）
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
        langRefresh += 1   // 强制视图重绘
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                    .id(downloadStateVersion)

                if batchSelectMode, let vm = listVM {
                    batchToolbar(allMeetings: vm.meetings)
                }

                engineAlertBanner
                    .id(downloadStateVersion)

                if let vm = listVM {
                    if vm.meetings.isEmpty {
                        emptyState
                    } else {
                        meetingList(vm.groupedMeetings)
                    }
                } else {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                }
            }
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
            .navigationTitle(loc("app_title"))
            .id(langRefresh)   // 语言切换时强制整棵视图树重建
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        // 手动触发向导（允许重复查看）
                        wizardStep = 0
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .frame(width: 32, height: 32)
                    .help(loc("wizard_help"))

                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                    .frame(width: 32, height: 32)
                    .help(loc("settings"))
                    .popover(isPresented: wizardBinding(for: 0), arrowEdge: .bottom) {
                        WizardPopoverContent(
                            step: 0, totalSteps: 5,
                            icon: "gearshape",
                            title: loc("wizard_settings_title"),
                            desc: loc("wizard_settings_desc"),
                            onNext: { wizardStep = 1 },
                            onSkip: finishOnboarding
                        )
                    }

                    NavigationLink(destination: HotwordsManagementView()) {
                        Image(systemName: "text.book.closed")
                    }
                    .frame(width: 32, height: 32)
                    .help(loc("wizard_hotwords_title"))
                    .popover(isPresented: wizardBinding(for: 1), arrowEdge: .bottom) {
                        WizardPopoverContent(
                            step: 1, totalSteps: 5,
                            icon: "text.book.closed",
                            title: loc("wizard_hotwords_title"),
                            desc: loc("wizard_hotwords_desc"),
                            onNext: { wizardStep = 2 },
                            onSkip: finishOnboarding
                        )
                    }

                    NavigationLink(destination: PersonnelManagementView()) {
                        Image(systemName: "person.2")
                    }
                    .frame(width: 32, height: 32)
                    .help(loc("personnel_voiceprint_help"))
                    .popover(isPresented: wizardBinding(for: 2), arrowEdge: .bottom) {
                        WizardPopoverContent(
                            step: 2, totalSteps: 5,
                            icon: "person.2",
                            title: loc("wizard_personnel_title"),
                            desc: loc("wizard_personnel_desc"),
                            onNext: { wizardStep = 3 },
                            onSkip: finishOnboarding
                        )
                    }

                    // 创建会议按钮：可用时 Accent Color 填充高亮
                    Button {
                        recordingVM.onTapStartRecording()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(SettingsManager.shared.isModelAvailable
                                          ? Color.accentColor
                                          : Color.clear)
                            )
                            .foregroundStyle(SettingsManager.shared.isModelAvailable
                                             ? Color.white
                                             : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .help(loc("start_meeting"))
                    .disabled(!SettingsManager.shared.isModelAvailable)
                    .popover(isPresented: wizardBinding(for: 3), arrowEdge: .bottom) {
                        WizardPopoverContent(
                            step: 3, totalSteps: 5,
                            icon: "pencil.and.list.clipboard",
                            title: loc("wizard_meeting_title"),
                            desc: loc("wizard_meeting_desc"),
                            onNext: { wizardStep = 4 },
                            onSkip: finishOnboarding
                        )
                    }

                    Button {
                        batchSelectMode.toggle()
                        if !batchSelectMode { selectedMeetingIds = [] }
                    } label: {
                        Image(systemName: batchSelectMode ? "checkmark.circle.fill" : "checklist")
                    }
                    .frame(width: 32, height: 32)
                    .help(batchSelectMode ? loc("done") : loc("batch_manage"))
                    .disabled(listVM?.meetings.isEmpty ?? true)
                    .popover(isPresented: wizardBinding(for: 4), arrowEdge: .bottom) {
                        WizardPopoverContent(
                            step: 4, totalSteps: 5,
                            icon: "checklist",
                            title: loc("wizard_batch_title"),
                            desc: loc("wizard_batch_desc"),
                            onNext: {},
                            onSkip: finishOnboarding
                        )
                    }

                    // 语言三态切换按钮：显示当前语言标记
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
            .sheet(isPresented: $recordingVM.showNewMeetingSheet) {
                NewMeetingSheet(viewModel: recordingVM)
            }
            .sheet(isPresented: $showDeleteSheet) {
                DeleteMeetingSheet(
                    meetings: deleteGroupMeetings,
                    speechClipCounts: deleteGroupClipCounts,
                    onDelete: {
                        for m in deleteGroupMeetings {
                            try? databaseManager.deleteMeeting(id: m.id)
                        }
                        listVM?.loadMeetings()
                    },
                    onExportFile: { filePath in
                        exportAudioFile(filePath)
                    }
                )
            }
            .alert(loc("permission_insufficient"), isPresented: $showPermissionAlert) {
                Button(loc("confirm"), role: .cancel) { }
            } message: {
                Text("\(permissionAlertMessage)\n\n\(loc("permission_hint"))")
            }
            .alert(loc("batch_delete_meetings"), isPresented: $showBatchDeleteConfirm) {
                Button(loc("cancel"), role: .cancel) { }
                Button(loc("delete"), role: .destructive) {
                    for id in selectedMeetingIds {
                        try? databaseManager.deleteMeeting(id: id)
                    }
                    selectedMeetingIds = []
                    batchSelectMode = false
                    listVM?.loadMeetings()
                }
            } message: {
                Text(String(format: loc("batch_delete_meetings_msg"), selectedMeetingIds.count))
            }
            .onAppear {
                // 首次启动自动弹出引导向导
                if !hasCompletedOnboarding {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        wizardStep = 0
                    }
                }

                // 检测已下载的 FunASR 模型版本
                let s = SettingsManager.shared
                if s.modelVersion.isEmpty, s.isModelAvailable {
                    s.modelVersion = "funasr-v1"
                }
                if listVM == nil {
                    listVM = MeetingListViewModel(databaseManager: databaseManager)
                }
                listVM?.loadMeetings()
            }
            .onChange(of: recordingVM.meetingStatus) { _, newStatus in
                if newStatus == .idle {
                    listVM?.loadMeetings()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsManager.downloadStateDidChangeNotification)) { _ in
                downloadStateVersion += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsManager.engineDidChangeNotification)) { _ in
                downloadStateVersion += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsManager.localModelStatusDidChangeNotification)) { _ in
                downloadStateVersion += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudModelManager.modelSelectionDidChangeNotification)) { _ in
                downloadStateVersion += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsManager.settingsDidChangeNotification)) { _ in
                downloadStateVersion += 1
            }
        }
    }

    // MARK: - 子视图

    /// 根据当前所选转写引擎自适应展示异常与配置引导横幅
    @ViewBuilder
    private var engineAlertBanner: some View {
        if SettingsManager.shared.transcriptionEngine == .cloudModel {
            if !TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady {
                cloudKeyMissingBanner
            }
        } else {
            if !SettingsManager.shared.isFunASROfflineAvailable && !SettingsManager.shared.currentModelDownloading {
                modelDownloadBanner
            }
        }
    }

    /// 云端大模型未配置 API Key 时的引导横幅（引导前往设置输入 Key）
    private var cloudKeyMissingBanner: some View {
        NavigationLink(destination: SettingsView()) {
            HStack(spacing: 14) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("cloud_key_missing_banner_title"))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(loc("cloud_key_missing_banner_desc"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color.purple, Color.purple.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .buttonStyle(.plain)
    }

    /// 模型未下载时的引导横幅（非阻塞，引导用户前往设置下载）
    private var modelDownloadBanner: some View {
        NavigationLink(destination: SettingsView()) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("model_not_downloaded_banner_title"))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(loc("model_not_downloaded_banner_desc"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color.orange.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var statusHeader: some View {
        let settings = SettingsManager.shared

        return HStack {
            Image(systemName: "bolt.fill").foregroundStyle(.green)
            Text(loc("status_ready")).font(.subheadline).foregroundStyle(.secondary)
            Spacer()

            switch settings.transcriptionEngine {
            case .cloudModel:
                if let active = TranscriptionEngineCoordinator.shared.getActiveCloudTranscriptionModel() {
                    Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.purple)
                    Text("\(active.model.name) \(loc("model_ready_suffix"))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    Text(loc("cloud_model_not_ready")).font(.caption).foregroundStyle(.orange)
                }
            case .localFunASR:
                if settings.currentModelDownloading {
                    ProgressView().scaleEffect(0.7)
                    Text("\(loc("model_downloading")) \(Int(settings.currentModelProgress * 100))%")
                        .font(.caption).foregroundStyle(.orange)
                } else if !settings.isFunASROfflineAvailable {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    Text(loc("voice_model_not_ready")).font(.caption).foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Text("FunASR \(loc("model_ready_suffix"))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.quaternary)
            Text(loc("no_meetings"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(loc("start_meeting_hint"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - 批量管理

    private func batchToolbar(allMeetings: [Meeting]) -> some View {
        HStack(spacing: 12) {
            Button(loc("select_all")) {
                selectedMeetingIds = Set(allMeetings.map { $0.id })
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !selectedMeetingIds.isEmpty {
                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label(
                        String(format: loc("batch_delete_count"), selectedMeetingIds.count),
                        systemImage: "trash"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Text(String(format: loc("selected_count"), selectedMeetingIds.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func meetingList(_ groups: [MeetingGroup]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        HStack(spacing: 8) {
                            if batchSelectMode {
                                let isSelected = selectedMeetingIds.contains(meeting.id)
                                Button {
                                    if isSelected {
                                        selectedMeetingIds.remove(meeting.id)
                                    } else {
                                        selectedMeetingIds.insert(meeting.id)
                                    }
                                } label: {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? .purple : .secondary)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                guard !batchSelectMode else { return }
                                recordingVM.currentMeeting = meeting
                                let finalPath = meeting.localAudioURL.path
                                recordingVM.currentMeeting?.audioPath = finalPath

                                var duration = TimeInterval(meeting.duration)
                                if let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: finalPath)) {
                                    if player.duration > 0 {
                                        duration = player.duration
                                    }
                                }
                                recordingVM.audioPlayer.duration = duration
                                recordingVM.audioPlayer.currentTime = 0

                                recordingVM.loadSegmentsFromDatabase(meetingId: meeting.id)
                                recordingVM.meetingStatus = .reviewing
                            } label: {
                                MeetingRow(meeting: meeting)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteGroupMeetings = databaseManager.fetchMeetingGroup(id: meeting.id)
                                var counts: [String: Int] = [:]
                                for m in deleteGroupMeetings {
                                    counts[m.id] = databaseManager.fetchSpeechClipsCount(meetingId: m.id)
                                }
                                deleteGroupClipCounts = counts
                                showDeleteSheet = true
                            } label: {
                                Label(loc("delete_meeting"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(loc(group.group.localeKey))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 向导辅助

    /// 弹出层绑定：仅当向导处于指定步骤时展示对应按钮的 popover（\(.constant 阻止点击外部关闭）
    private func wizardBinding(for step: Int) -> Binding<Bool> {
        .constant(wizardStep == step)
    }

    /// 结束向导并标记已完成
    private func finishOnboarding() {
        wizardStep = nil
        hasCompletedOnboarding = true
    }

    private func exportAudioFile(_ sourcePath: String) {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourcePath) else { return }
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.title = loc("save_recording")
        savePanel.nameFieldStringValue = sourceURL.lastPathComponent
        savePanel.allowedContentTypes = [.audio]
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let destURL = savePanel.url {
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
        #endif
    }
}

// MARK: - 会议列表行

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 40, height: 40)
                .background(statusColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(formattedTimeRange, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let location = meeting.location {
                        Label(location, systemImage: "mappin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusBadge
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
                .padding(.leading, 64)
        }
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .foregroundStyle(statusColor)
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var iconName: String {
        switch meeting.status {
        case .recording: return "mic.fill"
        case .pendingDiarization: return "person.wave.2"
        case .processingLlm: return "brain"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording: return .red
        case .pendingDiarization: return .orange
        case .processingLlm: return .blue
        case .completed: return .green
        }
    }

    private var statusText: String {
        switch meeting.status {
        case .recording: return loc("status_recording")
        case .pendingDiarization: return loc("status_pending_diarization")
        case .processingLlm: return loc("status_processing_llm")
        case .completed: return loc("status_completed")
        }
    }

    private var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: meeting.createdAt)
        let end = formatter.string(from: meeting.createdAt.addingTimeInterval(Double(meeting.duration)))
        
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dayFormatter.string(from: meeting.createdAt)
        
        if meeting.duration > 0 {
            return "\(dateStr) \(start)-\(end)"
        } else {
            return "\(dateStr) \(start) - ..."
        }
    }

    private var formattedDuration: String {
        let mins = meeting.duration / 60
        let secs = meeting.duration % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 删除会议确认弹窗

struct DeleteMeetingSheet: View {
    let meetings: [Meeting]
    let speechClipCounts: [String: Int]
    let onDelete: () -> Void
    let onExportFile: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc("delete_meeting"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(loc("delete_confirm_detail"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(meetings, id: \.id) { meeting in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.purple)
                                Text(meeting.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                statusBadge(meeting)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    let fileName = URL(fileURLWithPath: meeting.audioPath).lastPathComponent
                                    Text("\(loc("audio_file_label")): \(fileName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        onExportFile(meeting.audioPath)
                                    } label: {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .help(loc("save_recording"))
                                }

                                let clipCount = speechClipCounts[meeting.id] ?? 0
                                HStack {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(loc("voice_clips_label")): \(clipCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text("\(loc("created_label")): \(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 24)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        if meeting.id != meetings.last?.id {
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(.purple.opacity(0.2))
                                    .frame(width: 2, height: 16)
                                    .padding(.leading, 30)
                                Text(loc("extend_label"))
                                    .font(.caption2)
                                    .foregroundStyle(.purple.opacity(0.6))
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Button(loc("cancel")) { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label(loc("confirm_delete"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private func statusBadge(_ meeting: Meeting) -> some View {
        Text(statusText(meeting))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor(meeting).opacity(0.12))
            .foregroundStyle(statusColor(meeting))
            .clipShape(Capsule())
    }

    private func statusText(_ meeting: Meeting) -> String {
        switch meeting.status {
        case .recording: return loc("status_recording")
        case .pendingDiarization: return loc("status_pending")
        case .processingLlm: return loc("status_ai_processing")
        case .completed: return loc("status_done")
        }
    }

    private func statusColor(_ meeting: Meeting) -> Color {
        switch meeting.status {
        case .recording: return .red
        case .pendingDiarization: return .orange
        case .processingLlm: return .blue
        case .completed: return .green
        }
    }
}

// MARK: - 向导气泡内容

/// 单个步骤的 popover 内容：步骤指示、图标、标题、描述、操作按钮
struct WizardPopoverContent: View {
    let step: Int
    let totalSteps: Int
    let icon: String
    let title: String
    let desc: String
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 步骤指示 + 跳过
            HStack {
                Text("\(step + 1) / \(totalSteps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
                Spacer()
                Button(loc("skip")) { onSkip() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 图标 + 标题
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
                Text(title)
                    .font(.headline)
            }

            // 描述文字
            Text(desc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 操作按钮
            HStack {
                Spacer()
                if step < totalSteps - 1 {
                    Button(loc("wizard_next")) { onNext() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.purple)
                } else {
                    Button(loc("start_using")) { onSkip() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.purple)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }
}
