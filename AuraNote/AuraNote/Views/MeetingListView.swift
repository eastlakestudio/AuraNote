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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader

                if !SettingsManager.shared.isModelAvailable && !SettingsManager.shared.currentModelDownloading {
                    modelDownloadBanner
                }

                if let vm = listVM {
                    if vm.meetings.isEmpty {
                        emptyState
                    } else {
                        meetingList(vm.meetings)
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                    .frame(width: 32)
                    .help(loc("settings"))

                    NavigationLink(destination: PersonnelManagementView()) {
                        Image(systemName: "person.2")
                    }
                    .frame(width: 32)
                    .help(loc("personnel_voiceprint_help"))

                    Button {
                        recordingVM.onTapStartRecording()
                    } label: {
                        Image(systemName: "pencil.and.list.clipboard")
                    }
                    .frame(width: 32)
                    .help(loc("start_meeting"))
                    .disabled(!SettingsManager.shared.isModelAvailable)
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
            .onAppear {
                // 检测已下载的模型版本
                let s = SettingsManager.shared
                if s.modelVersion.isEmpty {
                    let repoPath = URL(fileURLWithPath: s.modelPath)
                        .appendingPathComponent("models/argmaxinc/whisperkit-coreml").path
                    let check = URL(fileURLWithPath: repoPath).appendingPathComponent(SettingsManager.supportedModelID)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: check.path, isDirectory: &isDir), isDir.boolValue {
                        s.modelVersion = SettingsManager.supportedModelID
                    }
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
        }
    }

    // MARK: - 子视图

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
            if settings.currentModelDownloading {
                ProgressView().scaleEffect(0.7)
                Text("\(loc("model_downloading")) \(Int(settings.currentModelProgress * 100))%")
                    .font(.caption).foregroundStyle(.orange)
            } else if !settings.isModelAvailable {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                Text(loc("voice_model_not_ready")).font(.caption).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                Text("openai/whisper-large-v3 \(loc("model_ready_suffix"))").font(.caption).foregroundStyle(.secondary)
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

    private func meetingList(_ meetings: [Meeting]) -> some View {
        List(meetings) { meeting in
            Button {
                recordingVM.currentMeeting = meeting
                let finalPath = meeting.localAudioURL.path
                recordingVM.currentMeeting?.audioPath = finalPath

                // 探测音频实际时长
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .listStyle(.sidebar)
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
