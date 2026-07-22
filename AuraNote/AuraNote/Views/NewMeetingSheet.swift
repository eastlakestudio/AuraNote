import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct NewMeetingSheet: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(DatabaseManager.self) private var databaseManager

    @State private var locationSuggestions: [String] = []
    @State private var showLocationSuggestions = false
    @State private var attendees: [String] = []
    @State private var recentMeetings: [Meeting] = []
    @State private var tempSelectedAudioURL: URL? = nil
    @State private var originalAudioFileName: String = ""
    @State private var showDatePickerPopover = false

    @State private var showMultiSelectPopover = false

    private var formattedFormDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: viewModel.formCreatedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc("new_meeting"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // 1. 会议语言 与 会议主题 (共用一行)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("meeting_language"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("", selection: $viewModel.formSpeechLang) {
                            Text(loc("chinese")).tag("zh")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .padding(.vertical, 2)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("meeting_topic"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextField(loc("enter_topic"), text: $viewModel.formTitle)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // 2. 开始时间 与 会议地点 (共用一行)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("start_time"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button {
                            showDatePickerPopover = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.purple)
                                    .font(.subheadline)
                                Text(formattedFormDate)
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDatePickerPopover) {
                            DatePicker("", selection: $viewModel.formCreatedAt, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                                .padding(12)
                        }
                    }
                    .frame(maxWidth: 220)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("meeting_location"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        TextField(loc("enter_location"), text: $viewModel.formLocation)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: viewModel.formLocation) { _, _ in
                                showLocationSuggestions = !viewModel.formLocation.isEmpty
                            }
                            .onSubmit { showLocationSuggestions = false }
                    }
                }

                if showLocationSuggestions && !viewModel.formLocation.isEmpty {
                    let filtered = locationSuggestions.filter {
                        $0.lowercased().contains(viewModel.formLocation.lowercased())
                    }
                    if !filtered.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(filtered.prefix(8), id: \.self) { suggestion in
                                    Button {
                                        viewModel.formLocation = suggestion
                                        showLocationSuggestions = false
                                    } label: {
                                        Text(suggestion)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(.quaternary.opacity(0.5))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 440, idealWidth: 480)
        .background(.regularMaterial)
    }
                    }
                }

                // 3. 参会人（从全局人员库多选）
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc("attendees"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !attendees.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(attendees, id: \.self) { person in
                                HStack(spacing: 4) {
                                    Text(person).font(.caption)
                                    Button {
                                        attendees.removeAll { $0 == person }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").font(.caption2)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.purple.opacity(0.1)).clipShape(Capsule())
                            }
                        }
                    }

                    Button {
                        showMultiSelectPopover = true
                    } label: {
                        HStack {
                            Image(systemName: "person.3.sequence").font(.caption)
                            Text(loc("select_from_personnel"))
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showMultiSelectPopover) {
                        MultiSelectContactPicker(
                            selectedNames: Set(attendees),
                            onConfirm: { names in
                                attendees = Array(names)
                                showMultiSelectPopover = false
                            }
                        )
                    }
                }

                  // 4. 音频来源
                  VStack(alignment: .leading, spacing: 6) {
                      Text(loc("audio_source"))
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      
                      HStack(spacing: 16) {
                          HStack(spacing: 12) {
                              // 实时录音 RadioButton
                              Button {
                                  viewModel.recordingMode = .liveRecording
                              } label: {
                                  HStack(spacing: 6) {
                                      Image(systemName: viewModel.recordingMode == .liveRecording ? "largecircle.fill.circle" : "circle")
                                          .foregroundStyle(viewModel.recordingMode == .liveRecording ? .purple : .secondary)
                                      Text(loc("live_recording"))
                                          .font(.subheadline)
                                  }
                              }
                              .buttonStyle(.plain)
                              .contentShape(Rectangle())

                              // 音频文件 RadioButton
                              Button {
                                  viewModel.recordingMode = .importFile
                              } label: {
                                  HStack(spacing: 6) {
                                      Image(systemName: viewModel.recordingMode == .importFile ? "largecircle.fill.circle" : "circle")
                                          .foregroundStyle(viewModel.recordingMode == .importFile ? .purple : .secondary)
                                      Text(loc("audio_file"))
                                          .font(.subheadline)
                                  }
                              }
                              .buttonStyle(.plain)
                              .contentShape(Rectangle())
                          }
                          .frame(maxWidth: 220, alignment: .leading)
                          
                          // 如果选择音频文件，展示文件名框 and 选择按钮
                          if viewModel.recordingMode == .importFile {
                              HStack(spacing: 8) {
                                  // 文件名称框
                                  Text(originalAudioFileName.isEmpty ? loc("no_audio_selected") : originalAudioFileName)
                                      .font(.subheadline)
                                      .foregroundStyle(originalAudioFileName.isEmpty ? .secondary : .primary)
                                      .lineLimit(1)
                                      .padding(.horizontal, 10)
                                      .padding(.vertical, 6)
                                      .frame(maxWidth: .infinity, alignment: .leading)
                                      .background(.quaternary.opacity(0.4))
                                      .clipShape(RoundedRectangle(cornerRadius: 6))
                                  
                                  // 选择文件图标按钮
                                  Button {
                                      selectAudioFile()
                                  } label: {
                                      Image(systemName: "folder.badge.plus")
                                          .font(.title3)
                                          .foregroundStyle(.purple)
                                          .padding(6)
                                          .background(.purple.opacity(0.1))
                                          .clipShape(RoundedRectangle(cornerRadius: 6))
                                  }
                                  .buttonStyle(.plain)
                                  .help(loc("select_audio_file"))
                              }
                              .transition(.opacity)
                          } else {
                              Spacer()
                          }
                      }
                      .frame(height: 32)
                      
                  }

                // 5. 延续历史会议
                HStack(spacing: 16) {
                    Toggle(loc("extend_meeting"), isOn: $viewModel.shouldExtendLastMeeting)
                        .font(.subheadline)
                        .frame(maxWidth: 220, alignment: .leading)

                    if viewModel.shouldExtendLastMeeting && !recentMeetings.isEmpty {
                        Picker("", selection: $viewModel.selectedParentMeetingId) {
                            ForEach(recentMeetings, id: \.id) { meeting in
                                Text(meetingPickerTitle(for: meeting)).tag(String?.some(meeting.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()

            Divider()

            HStack(spacing: 12) {
                Button(loc("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                Spacer()

                Button {
                    viewModel.formAttendees = attendees.joined(separator: " ")
                    if viewModel.recordingMode == .liveRecording {
                        Task {
                            await viewModel.startRecording()
                        }
                    } else {
                        if let tempURL = tempSelectedAudioURL {
                            Task {
                                await viewModel.importAudioFile(
                                    from: tempURL,
                                    title: viewModel.formTitle.isEmpty ? nil : viewModel.formTitle,
                                    location: viewModel.formLocation.isEmpty ? nil : viewModel.formLocation
                                )
                                try? FileManager.default.removeItem(at: tempURL)
                                tempSelectedAudioURL = nil
                                await MainActor.run {
                                    dismiss()
                                }
                            }
                        }
                    }
                } label: {
                    Label(loc("start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.purple)
                .disabled(viewModel.recordingMode == .importFile && tempSelectedAudioURL == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 480)
        .onAppear {
            locationSuggestions = databaseManager.fetchDistinctLocations(excludeExternal: loc("external_import"))
            if !viewModel.formAttendees.isEmpty {
                attendees = viewModel.formAttendees
                    .split(separator: " ")
                    .map(String.init)
                    .filter { !$0.isEmpty }
            }
            recentMeetings = databaseManager.fetchAllMeetings()
            if viewModel.selectedParentMeetingId == nil {
                viewModel.selectedParentMeetingId = recentMeetings.first?.id
            }
        }
        .onDisappear {
            viewModel.formAttendees = attendees.joined(separator: " ")
            if let tempURL = tempSelectedAudioURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    private func meetingPickerTitle(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let start = formatter.string(from: meeting.createdAt)
        return "\(meeting.title) (\(start))"
    }

    private func selectAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.audio]
        
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            let gained = url.startAccessingSecurityScopedResource()
            defer {
                if gained {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("temp_import_\(UUID().uuidString).\(url.pathExtension)")
            try? FileManager.default.removeItem(at: tempURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                tempSelectedAudioURL = tempURL
                originalAudioFileName = url.lastPathComponent
            } catch {
                AppLog.error("Failed to copy audio file to temp directory: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 流式标签布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        let totalHeight = y + lineHeight
        return (CGSize(width: maxWidth, height: totalHeight), frames)
    }
}
