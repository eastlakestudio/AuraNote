import SwiftUI

/// 录音进行中的主界面
struct RecordingView: View {
    @Bindable var viewModel: RecordingViewModel
    @State private var showInspector = false
    @State private var dummyFilter: String? = nil
    @State private var dummyAttendees: String = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                recordingHeader
                transcriptList
                controlBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(uiColor: .systemGroupedBackground))
            #endif

            if showInspector {
                Divider()
                MeetingInfoSidebar(viewModel: viewModel, filterSpeaker: $dummyFilter, attendeesString: $dummyAttendees, showSpeakerSections: false)
                    .frame(width: 260)
                    .onAppear {
                        dummyAttendees = viewModel.currentMeeting?.attendees ?? ""
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showInspector ? .purple : .secondary)
                }
                .frame(width: 32)
                .help(loc("meeting_info"))
            }
        }
    }

    // MARK: - 录音状态栏

    private var recordingHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(.red.opacity(0.4), lineWidth: 3)
                            .scaleEffect(1.5)
                            .opacity(viewModel.currentAmplitude > 0.01 ? 1 : 0.3)
                            .animation(.easeInOut(duration: 0.3), value: viewModel.currentAmplitude)
                    )
                Text(loc("recording"))
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
                Text(viewModel.formattedDuration)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.medium)
            }
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(min(viewModel.currentAmplitude * 5, 1.0)), height: 4)
                    .animation(.easeOut(duration: 0.1), value: viewModel.currentAmplitude)
            }
            .frame(height: 4)
            if let meeting = viewModel.currentMeeting {
                HStack {
                    Text(meeting.title).font(.subheadline).foregroundStyle(.secondary)
                    if let location = meeting.location {
                        Spacer()
                        Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - 转写列表

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 已有切割片段（AudioChunk）
                    ForEach(viewModel.audioChunks) { chunk in
                        AudioChunkRow(chunk: chunk)
                            .id(chunk.id)
                    }
                    
                    // 底部：始终显示聆听中指示器（整个录音期间）
                    if viewModel.meetingStatus == .recording {
                        ListeningIndicator()
                            .id("listening")
                    }
                    
                    // 完全空状态（还没切割出任何片段）
                    if viewModel.audioChunks.isEmpty {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(loc("listening")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity)
            .onChange(of: viewModel.audioChunks.count) { _, _ in
                withAnimation { proxy.scrollTo("listening", anchor: .bottom) }
            }
        }
    }

    // MARK: - 底部控制栏

    private var controlBar: some View {
        HStack {
            Spacer()
            Button {
                viewModel.stopRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text(loc("stop_recording"))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(.red, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.bottom, 12)
    }
}

// MARK: - 转写气泡

struct TranscriptBubble: View {
    let segment: TranscriptSegment
    var isActive: Bool = false
    var attendees: [String] = []
    var contacts: [String] = []
    var onTextChange: ((String) -> Void)? = nil
    var onSpeakerChange: ((String) -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var onSplit: ((String, String, String?) -> Void)? = nil
    var onMerge: (() -> Void)? = nil

    @State private var editedText: String
    @State private var showRenamePopover = false
    @State private var newSpeakerTempName = ""

    private var otherContacts: [String] {
        contacts.filter { !attendees.contains($0) }
    }

    init(segment: TranscriptSegment, isActive: Bool = false, attendees: [String] = [], contacts: [String] = [], onTextChange: ((String) -> Void)? = nil, onSpeakerChange: ((String) -> Void)? = nil, onPlay: (() -> Void)? = nil, onSplit: ((String, String, String?) -> Void)? = nil, onMerge: (() -> Void)? = nil) {
        self.segment = segment
        self.isActive = isActive
        self.attendees = attendees
        self.contacts = contacts
        self.onTextChange = onTextChange
        self.onSpeakerChange = onSpeakerChange
        self.onPlay = onPlay
        self.onSplit = onSplit
        self.onMerge = onMerge
        self._editedText = State(initialValue: segment.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            speakerBadge

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(segment.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let onPlay = onPlay {
                        Button(action: onPlay) {
                            Image(systemName: "play.circle.fill").font(.caption).foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    if let onMerge = onMerge {
                        Button(action: onMerge) {
                            Image(systemName: "arrow.up.and.person.rectangle.turn.left")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(loc("merge_prev"))
                    }
                    if !segment.isFinal {
                        ProgressView().scaleEffect(0.5)
                    }
                }

                if onTextChange != nil {
                    TextEditor(text: $editedText)
                        .font(.body)
                        .lineSpacing(6)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 24)
                        .onChange(of: editedText) { _, newValue in
                            if newValue.contains("\n") {
                                let parts = newValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                                if parts.count >= 2 {
                                    let t1 = parts[0], t2 = parts[1]
                                    editedText = parts[0]
                                    onSplit?(t1, t2, nil)
                                } else {
                                    editedText = newValue.replacingOccurrences(of: "\n", with: "")
                                }
                            } else {
                                onTextChange?(newValue)
                            }
                        }
                } else {
                    Text("\(segment.speakerLabel): \(segment.text)")
                        .font(.body)
                        .lineSpacing(6)
                        .foregroundStyle(segment.isFinal ? .primary : .secondary)
                        .opacity(segment.isFinal ? 1 : 0.7)
                        .frame(minHeight: 20, alignment: .topLeading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.purple.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .onChange(of: segment.text) { _, newText in
            editedText = newText
        }
    }

    // MARK: - 说话人标签

    private var speakerBadge: some View {
        Group {
            if onSpeakerChange != nil {
                Menu {
                    if !attendees.isEmpty {
                        Section(loc("attendees_section")) {
                            ForEach(attendees, id: \.self) { p in Button(p) { onSpeakerChange?(p) } }
                        }
                    }
                    if !otherContacts.isEmpty {
                        Section(loc("global_staff")) {
                            ForEach(otherContacts, id: \.self) { n in Button(n) { onSpeakerChange?(n) } }
                        }
                    }
                    Section { Button(loc("new_speaker_ellipsis")) { newSpeakerTempName = ""; showRenamePopover = true } }
                } label: {
                    Text(segment.speakerLabel)
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(speakerColor, in: Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .popover(isPresented: $showRenamePopover) {
                    VStack(spacing: 8) {
                        Text(loc("new_voiceprint")).font(.caption).foregroundStyle(.secondary)
                        TextField(loc("name"), text: $newSpeakerTempName).textFieldStyle(.roundedBorder)
                            .onSubmit { confirmNewSpeaker() }
                        HStack {
                            Spacer()
                            Button(loc("cancel")) { showRenamePopover = false }
                            Button(loc("confirm")) { confirmNewSpeaker() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding().frame(width: 200)
                }
            } else {
                Text(segment.speakerLabel)
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(speakerColor, in: Capsule())
            }
        }
        .frame(width: 64, alignment: .leading)
        .padding(.top, 2)
    }

    private var speakerColor: Color {
        let c: [Color] = [.purple, .blue, .orange, .green, .pink, .teal, .indigo, .mint]
        return c[abs(segment.speakerLabel.hashValue) % c.count]
    }

    private func confirmNewSpeaker() {
        let name = newSpeakerTempName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { onSpeakerChange?(name); showRenamePopover = false }
    }
}

// MARK: - 聆听中指示器

/// 实时录音时底部显示的聆听状态气泡，带脉冲动画
struct ListeningIndicator: View {
    @State private var isPulsing = false
    @State private var listeningDuration: TimeInterval = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            // 麦克风图标
            Circle()
                .fill(.red.opacity(0.3))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                )
                .frame(width: 64, alignment: .leading)

            // 脉冲红点 + 文本 + 计时
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing ? 1.8 : 0.8)
                    .opacity(isPulsing ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                Text("聆听中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatDuration(listeningDuration))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
        )
        .onAppear {
            isPulsing = true
        }
        .onReceive(timer) { _ in
            listeningDuration += 0.1
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        }
        return String(format: "%ds", secs)
    }
}

// MARK: - 音频片段行

/// 实时录音时列表中每个音频片段的展示行
struct AudioChunkRow: View {
    let chunk: AudioChunk

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 时间标签
            VStack(spacing: 2) {
                Text(chunk.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(chunk.formattedDuration)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .frame(width: 48, alignment: .leading)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                // 说话人标签（声纹匹配完成后显示）
                if let speaker = chunk.speakerLabel {
                    Text(speaker)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.purple)
                }
                if chunk.isTranscribing {
                    // 转写中
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("识别中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let text = chunk.text, !text.isEmpty {
                    // 转写完成，有实质文本
                    Text(text)
                        .font(.body)
                        .lineSpacing(6)
                        .foregroundStyle(.primary)
                } else if chunk.text != nil {
                    // 已处理但无语音内容（纯静默片段）——显示空白
                    Text("无语音内容")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                } else {
                    // 等待转写（已切割但尚未投递识别）
                    Text("等待识别...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(chunk.text != nil ? Color.primary.opacity(0.05) : Color.secondary.opacity(0.03))
        )
        .animation(.easeInOut(duration: 0.3), value: chunk.isTranscribing)
        .animation(.easeInOut(duration: 0.3), value: chunk.text)
    }
}
