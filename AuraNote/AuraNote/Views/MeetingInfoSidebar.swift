import SwiftUI

/// 共享的会议信息编辑侧边栏（RecordingView / ReviewingView 共用）
struct MeetingInfoSidebar: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(DatabaseManager.self) private var databaseManager

    @State private var editedTitle = ""
    @State private var editedLocation = ""
    @State private var editedCreatedAt = Date()
    @State private var editedEndedAt = Date()
    @Binding var filterSpeaker: String?
    @Binding var attendeesString: String
    @State private var renamePerson = ""
    @State private var showRenameAttendeePopover = false
    @State private var renameTarget = ""
    @State private var settings = SettingsManager.shared
    @State private var showContactPicker = false
    @State private var attendeeSearchText = ""
    @State private var showNewContactSheet = false
    @State private var showMultiSelectPopover = false
    @State private var editedHotwordCategories: Set<String> = []
    @State private var showPresetPicker = false   // 热词词库选择弹窗

    /// 已选热词组数量展示（空格分隔每个组的热词数）
    private var hotwordCountsDisplay: String {
        let manager = HotwordPresetsManager.shared
        var counts: [String] = []
        for cat in manager.categories {
            if editedHotwordCategories.contains(cat.id) {
                counts.append("\(cat.words.count)")
            }
        }
        if editedHotwordCategories.contains("__custom__") {
            let customStr = SettingsManager.shared.hotwords.trimmingCharacters(in: .whitespaces)
            let words = customStr.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            counts.append("\(words.count)")
        }
        return counts.joined(separator: " ")
    }

    var showSpeakerSections: Bool = true

    private var editedAttendeesList: [String] {
        if attendeesString.isEmpty { return [] }
        return attendeesString.split(separator: " ").map(String.init)
    }

    private var speakerStats: [(speaker: String, count: Int, duration: Double)] {
        var stats = [String: (count: Int, duration: Double)]()

        // 优先从 transcriptSegments 统计（离线回顾模式）
        let segmentsWithLabels = viewModel.transcriptSegments.filter({ $0.isFinal && !$0.speakerLabel.isEmpty && $0.speakerLabel != "?" })
        if !segmentsWithLabels.isEmpty {
            for segment in segmentsWithLabels {
                let current = stats[segment.speakerLabel] ?? (0, 0.0)
                let segDur = max(0, segment.endTime - segment.startTime)
                stats[segment.speakerLabel] = (current.0 + 1, current.1 + segDur)
            }
        } else {
            // 实时录音模式下 transcriptSegments 为空，从 audioChunks 统计
            for chunk in viewModel.audioChunks {
                guard let label = chunk.speakerLabel, label != "?", !label.isEmpty else { continue }
                let current = stats[label] ?? (0, 0.0)
                let segDur = max(0, chunk.endTime - chunk.startTime)
                stats[label] = (current.0 + 1, current.1 + segDur)
            }
        }
        // 按每个 speaker 首次发言时间升序排列
        var firstTimes = [String: Double]()
        for segment in viewModel.transcriptSegments.filter({ $0.isFinal && !$0.speakerLabel.isEmpty && $0.speakerLabel != "?" }) {
            let label = segment.speakerLabel
            firstTimes[label] = min(firstTimes[label] ?? Double.greatestFiniteMagnitude, segment.startTime)
        }
        // 实时录音：从 audioChunks 补充首次出现时间
        if firstTimes.isEmpty {
            for chunk in viewModel.audioChunks {
                guard let label = chunk.speakerLabel, label != "?", !label.isEmpty else { continue }
                firstTimes[label] = min(firstTimes[label] ?? Double.greatestFiniteMagnitude, chunk.startTime)
            }
        }
        return stats.map { ($0.key, $0.value.count, $0.value.duration) }
            .sorted { (firstTimes[$0.0] ?? Double.greatestFiniteMagnitude) < (firstTimes[$1.0] ?? Double.greatestFiniteMagnitude) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc("meeting_properties")).font(.headline).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    startTimeField
                    endTimeField
                    locationField
                    pickupSensitivityField
                    hotwordsField
                    attendeeField
                    if showSpeakerSections {
                        speakerStatsSection
                    }
                }.padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .onAppear { loadMetadata() }
        .onChange(of: viewModel.currentMeeting) { _, _ in loadMetadata() }
        .popover(isPresented: $showRenameAttendeePopover) {
            VStack(spacing: 8) {
                Text(loc("rename_attendee")).font(.caption).foregroundStyle(.secondary)
                TextField(loc("new_name"), text: $renamePerson).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer(); Button(loc("cancel")) { showRenameAttendeePopover = false }
                    Button(loc("confirm")) {
                        let newName = renamePerson.trimmingCharacters(in: .whitespaces)
                        if !newName.isEmpty && newName != renameTarget {
                            viewModel.globalRenameSpeaker(oldName: renameTarget, newName: newName)
                            var list = editedAttendeesList
                            if let idx = list.firstIndex(of: renameTarget) { list[idx] = newName }
                            attendeesString = list.joined(separator: " ")
                            if filterSpeaker == renameTarget {
                                filterSpeaker = newName
                            }
                        }
                        showRenameAttendeePopover = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding().frame(width: 220)
        }
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("topic")).font(.caption).foregroundStyle(.secondary)
            TextField(loc("enter_topic"), text: $editedTitle).textFieldStyle(.roundedBorder).onSubmit { saveMetadata() }
        }
    }

    private var startTimeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("start_time")).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: $editedCreatedAt, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .onChange(of: editedCreatedAt) { _, _ in saveMetadata() }
        }
    }

    private var endTimeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("end_time")).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: $editedEndedAt, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .onChange(of: editedEndedAt) { _, _ in saveMetadata() }
        }
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("location_label")).font(.caption).foregroundStyle(.secondary)
            TextField(loc("meeting_place"), text: $editedLocation).textFieldStyle(.roundedBorder).onSubmit { saveMetadata() }
        }
    }
    
    private var pickupSensitivityField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("拾音灵敏度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Map 0.05...0.5 to 100...0
                let percentage = Int((0.5 - settings.vadThreshold) / 0.45 * 100)
                let label: String = {
                    switch percentage {
                    case 0..<25:  return "稳定"
                    case 25..<50: return "偏稳定"
                    case 50..<75: return "偏灵敏"
                    default:      return "灵敏"
                    }
                }()
                Text("\(percentage)%  \(label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(0.5 - settings.vadThreshold) / 0.45 },
                    set: { settings.vadThreshold = Float(0.5 - ($0 * 0.45)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .help("调节会议录音时的拾音灵敏度：向右更灵敏（能拾取小声说话），向左更稳定（过滤环境底噪）。")
            // 两端说明标签
            HStack {
                Label("过滤底噪", systemImage: "speaker.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()
                Label("拾取小声", systemImage: "ear")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
    }

    private var hotwordsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("热词设定").font(.caption).foregroundStyle(.secondary)

            // 行业词库选择——摘要行 + 弹窗
            Button {
                showPresetPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    if editedHotwordCategories.isEmpty {
                        Text("预设行业词库：未选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("预设行业词库：\(hotwordCountsDisplay)")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(editedHotwordCategories.isEmpty
                              ? Color.primary.opacity(0.05)
                              : Color.purple.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(editedHotwordCategories.isEmpty
                                ? Color.primary.opacity(0.1)
                                : Color.purple.opacity(0.25),
                                lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPresetPicker) {
                HotwordPresetPickerSheet(
                    selectedIds: $editedHotwordCategories,
                    onDismiss: { saveMetadata() }
                )
            }
        }
    }

    private var attendeeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("attendees")).font(.caption).foregroundStyle(.secondary)
            let list = editedAttendeesList
            if !list.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(list, id: \.self) { person in
                        HStack(spacing: 4) {
                            Text(person).font(.subheadline)
                            Button { removeAttendee(person) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.purple.opacity(0.1)).clipShape(Capsule())
                    }
                }.padding(.bottom, 4)
            }

            // 搜索输入 → 筛选结果
            HStack {
                TextField(loc("search_person"), text: $attendeeSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = attendeeSearchText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            let matches = filteredContacts
                            if let first = matches.first {
                                addAttendeeByName(first.name)
                            }
                        }
                    }
                Button { showNewContactSheet = true } label: {
                    Image(systemName: "person.badge.plus").foregroundStyle(.purple)
                }.buttonStyle(.plain).help(loc("new_personnel"))

                Button { showMultiSelectPopover = true } label: {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.purple)
                }.buttonStyle(.plain).help(loc("select_from_db"))
                .popover(isPresented: $showMultiSelectPopover) {
                    MultiSelectContactPicker(
                        selectedNames: Set(editedAttendeesList),
                        onConfirm: { names in
                            let current = editedAttendeesList
                            var all = current
                            for name in names where !current.contains(name) {
                                all.append(name)
                            }
                            saveMetadata(updatedAttendees: all.joined(separator: " "))
                            showMultiSelectPopover = false
                        }
                    )
                }
            }

            // 搜索结果下拉
            if !attendeeSearchText.isEmpty {
                let matches = filteredContacts
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches.prefix(6), id: \.id) { contact in
                            Button {
                                addAttendeeByName(contact.name)
                                attendeeSearchText = ""
                            } label: {
                                HStack {
                                    Text(contact.name).font(.subheadline)
                                    if let c = contact.company { Text("· \(c)").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if let r = contact.role { Text(r).font(.caption2).foregroundStyle(.purple) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if contact.id != matches.prefix(6).last?.id { Divider() }
                        }
                    }
                    .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .sheet(isPresented: $showNewContactSheet) {
            NewContactSheet { contact in
                try? databaseManager.saveContact(contact)
                addAttendeeByName(contact.name)
                showNewContactSheet = false
            } onCancel: { showNewContactSheet = false }
        }
    }

    private var filteredContacts: [Contact] {
        let text = attendeeSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return [] }
        let all = databaseManager.fetchAllContacts()
        return all.filter {
            $0.name.lowercased().contains(text)
            || ($0.company?.lowercased().contains(text) ?? false)
            || ($0.role?.lowercased().contains(text) ?? false)
        }
    }

    private func addAttendeeByName(_ name: String) {
        guard !name.isEmpty, name != "?" else { return }
        var list = editedAttendeesList
        if !list.contains(name) { list.append(name) }
        saveMetadata(updatedAttendees: list.joined(separator: " "))
    }

    // MARK: - 发言统计

    private var speakerStatsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text(loc("speech_stats")).font(.caption).foregroundStyle(.secondary)
            let stats = speakerStats
            if stats.isEmpty {
                Text(loc("no_data")).font(.subheadline).foregroundStyle(.tertiary)
            } else {
                ForEach(stats, id: \.speaker) { item in
                    HStack {
                        Button {
                            filterSpeaker = (filterSpeaker == item.speaker) ? nil : item.speaker
                        } label: {
                            HStack {
                                Text(item.speaker)
                                    .font(.subheadline).lineLimit(1)
                                    .fontWeight(filterSpeaker == item.speaker ? .bold : .regular)
                                    .foregroundStyle(filterSpeaker == item.speaker ? .purple : .primary)
                                Spacer()
                                Text("\(String(format: loc("sentences_count_fmt"), item.count)) | \(formatDuration(item.duration))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(filterSpeaker == item.speaker ? Color.purple.opacity(0.15) : Color.clear)
                            )
                        }.buttonStyle(.plain)

                        Menu {
                            if !editedAttendeesList.isEmpty {
                                Section(loc("reassign")) {
                                    ForEach(editedAttendeesList.filter { $0 != item.speaker }, id: \.self) { person in
                                        Button(person) {
                                            viewModel.globalRenameSpeaker(oldName: item.speaker, newName: person)
                                            if filterSpeaker == item.speaker {
                                                filterSpeaker = person
                                            }
                                        }
                                    }
                                }
                            }
                            Button(loc("rename")) {
                                renameTarget = item.speaker; renamePerson = item.speaker
                                showRenameAttendeePopover = true
                            }
                            if editedAttendeesList.contains(item.speaker) {
                                Button(loc("remove_from_attendees"), role: .destructive) {
                                    removeAttendee(item.speaker)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.tertiary)
                        }
                        .menuStyle(.borderlessButton).buttonStyle(.plain).frame(width: 16)
                    }
                }
            }
        }
    }

    // MARK: - 辅助

    private func loadMetadata() {
        if let meeting = viewModel.currentMeeting {
            editedTitle = meeting.title
            editedLocation = meeting.location ?? ""
            editedCreatedAt = meeting.createdAt
            editedEndedAt = meeting.createdAt.addingTimeInterval(TimeInterval(meeting.duration))
            if let cats = meeting.hotwordCategories, !cats.isEmpty {
                editedHotwordCategories = Set(cats.split(separator: ",").map(String.init))
            } else {
                editedHotwordCategories = []
            }
        }
    }

    private func saveMetadata(updatedAttendees: String? = nil) {
        let title = editedTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let locationText = editedLocation.trimmingCharacters(in: .whitespaces)
        let location = locationText.isEmpty ? nil : locationText
        let attendeesStr = updatedAttendees ?? attendeesString
        // 新增参会人时同步创建全局联系人
        if let updated = updatedAttendees {
            let before = Set(attendeesString.split(separator: " ").map(String.init))
            let after = Set(updated.split(separator: " ").map(String.init))
            for name in after.subtracting(before) where !name.isEmpty && name != "?" && databaseManager.fetchContact(byName: name) == nil {
                try? databaseManager.saveContact(Contact.create(name: name))
            }
        }
        let duration = max(0, Int(editedEndedAt.timeIntervalSince(editedCreatedAt)))
        if updatedAttendees != nil { attendeesString = attendeesStr }
        let catStr = editedHotwordCategories.isEmpty ? nil : Array(editedHotwordCategories).sorted().joined(separator: ",")
        viewModel.updateMeetingMetadata(
            title: title, location: location, createdAt: editedCreatedAt,
            attendees: attendeesStr, hotwordCategories: catStr, duration: duration
        )
    }

    private func removeAttendee(_ name: String) {
        var list = editedAttendeesList
        list.removeAll { $0 == name }
        saveMetadata(updatedAttendees: list.joined(separator: " "))
    }

    /// 将秒数格式化为 H:MM:SS 或 MM:SS
    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct NewContactSheet: View {
    var onSave: (Contact) -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var role = ""
    @State private var company = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(loc("new_personnel")).font(.headline)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("person_name")).font(.caption).foregroundStyle(.secondary)
                    TextField(loc("name_required"), text: $name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("role")).font(.caption).foregroundStyle(.secondary)
                    TextField(loc("role_hint"), text: $role).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("org")).font(.caption).foregroundStyle(.secondary)
                    TextField(loc("org_hint"), text: $company).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                Button(loc("cancel")) { onCancel() }.controlSize(.large)
                Spacer()
                Button(loc("create")) {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    let contact = Contact(
                        id: UUID().uuidString,
                        name: n,
                        role: role.trimmingCharacters(in: .whitespaces).isEmpty ? nil : role.trimmingCharacters(in: .whitespaces),
                        company: company.trimmingCharacters(in: .whitespaces).isEmpty ? nil : company.trimmingCharacters(in: .whitespaces),
                        avatarUrl: nil, createdAt: Date(), updatedAt: Date()
                    )
                    onSave(contact)
                }
                .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding().frame(width: 360)
    }
}

struct MultiSelectContactPicker: View {
    @Environment(DatabaseManager.self) private var db
    @State private var contacts: [Contact] = []
    @State private var selectedNames: Set<String>
    @State private var searchText = ""
    @State private var showNewContactInPicker = false
    let onConfirm: (Set<String>) -> Void

    init(selectedNames: Set<String>, onConfirm: @escaping (Set<String>) -> Void) {
        self._selectedNames = State(initialValue: selectedNames)
        self.onConfirm = onConfirm
    }

    private var filteredContacts: [Contact] {
        let text = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return contacts }
        return contacts.filter {
            $0.name.lowercased().contains(text)
            || ($0.company?.lowercased().contains(text) ?? false)
            || ($0.role?.lowercased().contains(text) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc("select_attendees")).font(.headline)
                Spacer()
            }.padding()

            TextField(loc("search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Divider().padding(.vertical, 4)

            if filteredContacts.isEmpty {
                Text(loc("no_match")).font(.subheadline).foregroundStyle(.secondary).padding()
            } else {
                List(filteredContacts, id: \.id) { contact in
                    Button {
                        if selectedNames.contains(contact.name) {
                            selectedNames.remove(contact.name)
                        } else {
                            selectedNames.insert(contact.name)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedNames.contains(contact.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedNames.contains(contact.name) ? .purple : .secondary)
                            Text(contact.name).font(.subheadline)
                            if let company = contact.company {
                                Text(company).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let role = contact.role {
                                Text(role).font(.caption2).foregroundStyle(.purple)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 12) {
                Button { showNewContactInPicker = true } label: {
                    Label(loc("new"), systemImage: "person.badge.plus").font(.caption)
                }.buttonStyle(.borderless)
                Text(String(format: loc("selected_count"), selectedNames.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(loc("cancel")) { onConfirm([]) }.buttonStyle(.borderless)
                Button(loc("confirm_btn")) { onConfirm(selectedNames) }
                    .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
            }.padding()
        }
        .frame(width: 300, height: 400)
        .onAppear { contacts = db.fetchAllContacts() }
        .sheet(isPresented: $showNewContactInPicker) {
            NewContactSheet(
                onSave: { contact in
                    try? db.saveContact(contact)
                    selectedNames.insert(contact.name)
                    contacts = db.fetchAllContacts()
                    showNewContactInPicker = false
                },
                onCancel: { showNewContactInPicker = false }
            )
        }
    }
}
