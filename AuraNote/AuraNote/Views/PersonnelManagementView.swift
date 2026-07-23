import SwiftUI

struct PersonGroupedClips: Identifiable {
    let id = UUID()
    let meeting: Meeting
    let clips: [SpeechClip]
}

struct PersonnelManagementView: View {
    @Environment(DatabaseManager.self) private var db
    @State private var contacts: [Contact] = []
    @State private var showAddSheet = false
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: Contact?
    @State private var editContact: Contact?
    @State private var selectedContact: Contact?
    @State private var groupedClips: [PersonGroupedClips] = []
    @State private var collapsedGroups: Set<UUID> = []   // 折叠的会议分组
    @State private var pendingReassignClip: SpeechClip?   // 待分配片段（新增联系人后自动绑定）
    @State private var editingAttrName = ""
    @State private var editingAttrRole = ""
    @State private var editingAttrCompany = ""
    @State private var isDirty = false
    @State private var lastLoadedContactId: String?
    @State private var clipPlayer = AudioPlayer()

    // 发言删除确认
    @State private var showDeleteClipConfirm = false
    @State private var deleteClipTarget: SpeechClip?
    @State private var showDeleteMeetingClipsConfirm = false
    @State private var deleteMeetingClipsTarget: PersonGroupedClips?
    @State private var showClearAllConfirm = false
    
    // 声纹重置
    @State private var showResetVoiceprintConfirm = false
    @State private var resetVoiceprintTarget: Contact?
    @State private var showResetAllVoiceprintsConfirm = false
    @State private var embeddingContactIds: Set<String> = []

    // 批量选择删除（右列 — 发言记录）
    @State private var batchSelectMode = false
    @State private var selectedClipIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    // 批量选择删除（左列 — 发言人）
    @State private var batchContactMode = false
    @State private var selectedContactIds: Set<String> = []
    @State private var showBatchDeleteContactsConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            // 左列：人员列表 + 属性
            leftColumn
                .frame(width: 280)

            Divider()

            // 右列：发言记录
            rightColumn
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            contacts = db.fetchAllContacts()
            embeddingContactIds = Set(db.fetchContactsWithEmbeddings().map { $0.id })
        }
        .sheet(isPresented: $showAddSheet) {
            ContactEditView(onSave: { contact in
                try? db.saveContact(contact)
                contacts = db.fetchAllContacts()
                // 如果有待分配的片段，自动绑定到新创建的联系人
                if let clip = pendingReassignClip {
                    reassignClip(clip, to: contact)
                    pendingReassignClip = nil
                }
                showAddSheet = false
            }, onCancel: {
                pendingReassignClip = nil
                showAddSheet = false
            })
        }
        .sheet(item: $editContact) { contact in
            ContactEditView(existing: contact, onSave: { updated in
                try? db.saveContact(updated)
                contacts = db.fetchAllContacts()
                editContact = nil
            }, onCancel: { editContact = nil })
        }
        .alert(loc("confirm_delete_person"), isPresented: $showDeleteConfirm) {
            Button(loc("cancel"), role: .cancel) { deleteTarget = nil }
            Button(loc("delete"), role: .destructive) {
                if let contact = deleteTarget {
                    try? db.deleteContact(id: contact.id)
                    contacts = db.fetchAllContacts()
                    if selectedContact?.id == contact.id { selectedContact = nil }
                    deleteTarget = nil
                }
            }
        } message: {
            if let contact = deleteTarget {
                Text(String(format: loc("confirm_delete_person_msg"), contact.name))
            }
        }
        .alert(loc("delete_speech_clip"), isPresented: $showDeleteClipConfirm) {
            Button(loc("cancel"), role: .cancel) { deleteClipTarget = nil }
            Button(loc("delete"), role: .destructive) {
                if let clip = deleteClipTarget {
                    try? db.deleteSpeechClip(id: clip.id)
                    refreshClips()
                    deleteClipTarget = nil
                }
            }
        } message: {
            Text(loc("delete_speech_clip_msg"))
        }
        .alert(loc("delete_meeting_clips"), isPresented: $showDeleteMeetingClipsConfirm) {
            Button(loc("cancel"), role: .cancel) { deleteMeetingClipsTarget = nil }
            Button(loc("delete"), role: .destructive) {
                if let group = deleteMeetingClipsTarget {
                    try? db.deleteClips(forMeeting: group.meeting.id)
                    refreshClips()
                    deleteMeetingClipsTarget = nil
                }
            }
        } message: {
            if let group = deleteMeetingClipsTarget {
                Text(String(format: loc("delete_meeting_clips_msg"), group.meeting.title, group.clips.count))
            }
        }
        .alert(loc("clear_all_clips"), isPresented: $showClearAllConfirm) {
            Button(loc("cancel"), role: .cancel) { }
            Button(loc("delete"), role: .destructive) {
                try? db.clearAllSpeechClips()
                refreshClips()
            }
        } message: {
            Text(loc("clear_all_clips_msg"))
        }
        .alert(loc("clear_voiceprint"), isPresented: $showResetVoiceprintConfirm) {
            Button(loc("cancel"), role: .cancel) { resetVoiceprintTarget = nil }
            Button(loc("clear_voiceprint"), role: .destructive) {
                if let contact = resetVoiceprintTarget {
                    try? db.clearContactEmbedding(contactId: contact.id)
                    embeddingContactIds.remove(contact.id)
                    resetVoiceprintTarget = nil
                }
            }
        } message: {
            if let contact = resetVoiceprintTarget {
                Text(String(format: loc("clear_voiceprint_msg"), contact.name))
            }
        }
        .alert(loc("clear_all_voiceprints"), isPresented: $showResetAllVoiceprintsConfirm) {
            Button(loc("cancel"), role: .cancel) { }
            Button(loc("clear_voiceprint"), role: .destructive) {
                try? db.clearAllContactEmbeddings()
                embeddingContactIds = []
            }
        } message: {
            Text(loc("clear_all_voiceprints_msg"))
        }
        .alert(loc("batch_delete_clips"), isPresented: $showBatchDeleteConfirm) {
            Button(loc("cancel"), role: .cancel) { }
            Button(loc("delete"), role: .destructive) {
                for clipId in selectedClipIds {
                    try? db.deleteSpeechClip(id: clipId)
                }
                selectedClipIds = []
                batchSelectMode = false
                refreshClips()
            }
        } message: {
            Text(String(format: loc("batch_delete_clips_msg"), selectedClipIds.count))
        }
        .alert(loc("batch_delete_contacts"), isPresented: $showBatchDeleteContactsConfirm) {
            Button(loc("cancel"), role: .cancel) { }
            Button(loc("delete"), role: .destructive) {
                for contactId in selectedContactIds {
                    try? db.deleteContact(id: contactId)
                }
                if let selected = selectedContact, selectedContactIds.contains(selected.id) {
                    selectedContact = nil
                }
                selectedContactIds = []
                batchContactMode = false
                contacts = db.fetchAllContacts()
            }
        } message: {
            Text(String(format: loc("batch_delete_contacts_msg"), selectedContactIds.count))
        }
    }

    // MARK: - 左列

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack {
                if batchContactMode {
                    Button(loc("select_all")) {
                        selectedContactIds = Set(contacts.map { $0.id })
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if !selectedContactIds.isEmpty {
                        Button(role: .destructive) {
                            showBatchDeleteContactsConfirm = true
                        } label: {
                            Label(String(format: loc("batch_delete_count"), selectedContactIds.count),
                                  systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    Button(loc("done")) {
                        batchContactMode = false
                        selectedContactIds = []
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                } else {
                    Text(loc("personnel_list")).font(.headline)
                    Spacer()
                    Button { showAddSheet = true } label: {
                        Image(systemName: "person.badge.plus").foregroundStyle(.purple)
                    }.buttonStyle(.plain).help(loc("add_person"))
                    if !contacts.isEmpty {
                        Button {
                            batchContactMode = true
                            selectedContactIds = []
                        } label: {
                            Text(loc("batch_select")).font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.leading, 4)
                    }
                }
            }.padding()

            Divider()

            if contacts.isEmpty {
                VStack(spacing: 8) {
                    Text(loc("no_personnel")).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxHeight: .infinity)
            } else {
                List(contacts, id: \.id) { contact in
                    let isSelected = selectedContactIds.contains(contact.id)
                    Button {
                        if batchContactMode {
                            if isSelected {
                                selectedContactIds.remove(contact.id)
                            } else {
                                selectedContactIds.insert(contact.id)
                            }
                        } else {
                            selectedContact = contact
                            editingAttrName = contact.name
                            editingAttrRole = contact.role ?? ""
                            editingAttrCompany = contact.company ?? ""
                            isDirty = false
                            let items = db.fetchSpeechClipsGroupedByMeeting(forContact: contact.id)
                            groupedClips = items.map { PersonGroupedClips(meeting: $0.meeting, clips: $0.clips) }
                            collapsedGroups = Set(groupedClips.map { $0.id })  // 默认全部折叠
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if batchContactMode {
                                let iconName = isSelected ? "checkmark.circle.fill" : "circle"
                                let iconColor: Color = isSelected ? .purple : .secondary
                                Image(systemName: iconName)
                                    .foregroundStyle(iconColor)
                            }
                            Circle()
                                .fill(personColor(contact.name))
                                .frame(width: 24, height: 24)
                                .overlay(Text(String(contact.name.prefix(1))).font(.caption2).foregroundStyle(.white))
                            Text(contact.name).font(.subheadline)
                                .foregroundStyle(selectedContact?.id == contact.id ? .purple : .primary)
                            Spacer()
                            if let company = contact.company {
                                Text(company).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !batchContactMode {
                            Button { editContact = contact } label: {
                                Label(loc("edit"), systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                deleteTarget = contact
                                showDeleteConfirm = true
                            } label: {
                                Label(loc("delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            // 属性面板
            if let contact = selectedContact {
                Divider()
                attributePanel(contact)
            }
        }
        .background(.regularMaterial)
    }

    private func attributePanel(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("person_attributes")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // 预留固定高度按钮区域，避免面板抖动
                ZStack {
                    if isDirty {
                        Button(loc("save")) {
                            saveAttrs(contact)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.small)
                        .disabled(editingAttrName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(height: 22)
            }
            VStack(spacing: 6) {
                HStack {
                    Text(loc("name")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    TextField("", text: $editingAttrName)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .onChange(of: editingAttrName) { _, _ in setDirtyIfChanged(contact) }
                        .onKeyPress(.return) { saveAttrs(contact); return .handled }
                    }
                    HStack {
                        Text(loc("role")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $editingAttrRole)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onChange(of: editingAttrRole) { _, _ in setDirtyIfChanged(contact) }
                            .onKeyPress(.return) { saveAttrs(contact); return .handled }
                    }
                    HStack {
                        Text(loc("org")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        TextField("", text: $editingAttrCompany)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onChange(of: editingAttrCompany) { _, _ in setDirtyIfChanged(contact) }
                            .onKeyPress(.return) { saveAttrs(contact); return .handled }
                }
            }
            
            // 声纹状态（始终显示，避免面板抖动）
            HStack {
                if embeddingContactIds.contains(contact.id) {
                    Image(systemName: "waveform.badge.checkmark").font(.caption).foregroundStyle(.green)
                    Text(loc("voiceprint_registered")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "waveform.badge.exclamationmark").font(.caption).foregroundStyle(.tertiary)
                    Text(loc("voiceprint_not_registered")).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if embeddingContactIds.contains(contact.id) {
                    Button(role: .destructive) {
                        resetVoiceprintTarget = contact
                        showResetVoiceprintConfirm = true
                    } label: {
                        Text(loc("clear_voiceprint")).font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .frame(height: 20)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - 右列

    private var rightColumn: some View {
        VStack(spacing: 0) {
            if let contact = selectedContact {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name).font(.headline)
                        if let role = contact.role {
                            Text(role).font(.caption).foregroundStyle(.purple)
                        }
                    }
                    Spacer()
                    if !groupedClips.isEmpty {
                        if batchSelectMode {
                            // 批量选择工具栏
                            HStack(spacing: 8) {
                                Button(loc("select_all")) {
                                    selectedClipIds = Set(groupedClips.flatMap { $0.clips.map { $0.id } })
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                if !selectedClipIds.isEmpty {
                                    Button(role: .destructive) {
                                        showBatchDeleteConfirm = true
                                    } label: {
                                        Label(String(format: loc("batch_delete_count"), selectedClipIds.count),
                                              systemImage: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                Button(loc("done")) {
                                    batchSelectMode = false
                                    selectedClipIds = []
                                }
                                .font(.caption)
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .controlSize(.small)
                            }
                        } else {
                            Button {
                                batchSelectMode = true
                            } label: {
                                Text(loc("batch_select")).font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }.padding()
            } else {
                // 未选人时显示统计信息
                VStack(spacing: 16) {
                    HStack {
                        Text(loc("personnel_overview")).font(.headline)
                        Spacer()
                    }
                    
                    let total = contacts.count
                    let companies = companyStats
                    
                    VStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text(loc("total")).font(.title2).foregroundStyle(.secondary)
                            Text("\(total)").font(.largeTitle).fontWeight(.bold).foregroundStyle(.purple)
                            Text(loc("people_unit")).font(.title2).foregroundStyle(.secondary)
                        }
                        
                        if !companies.isEmpty {
                            Divider()
                            VStack(spacing: 8) {
                                ForEach(companies.sorted(by: { $0.value > $1.value }).prefix(8), id: \.key) { company, count in
                                    HStack {
                                        Image(systemName: "building.2.fill").font(.callout).foregroundStyle(.blue)
                                        Text(company).font(.callout).lineLimit(1).frame(width: 120, alignment: .leading)
                                        Spacer()
                                        Text(String(format: loc("people_count_fmt"), count)).font(.title3).fontWeight(.medium).foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    if !embeddingContactIds.isEmpty {
                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                showResetAllVoiceprintsConfirm = true
                            } label: {
                                Label(loc("clear_all_voiceprints"), systemImage: "waveform.badge.exclamationmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }.padding()
            }

            Divider()

            if groupedClips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.quaternary)
                    Text(loc("no_speech_records")).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxHeight: .infinity)
            } else {
                // 全部清空按钮
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Label(loc("clear_all_clips"), systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedClips.enumerated()), id: \.element.id) { _, group in
                            VStack(alignment: .leading, spacing: 0) {
                                // 会议标题头（可点击折叠）
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if collapsedGroups.contains(group.id) {
                                            collapsedGroups.remove(group.id)
                                        } else {
                                            collapsedGroups.insert(group.id)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .frame(width: 12)
                                        let title = group.meeting.title
                                        let clipCount = group.clips.count
                                        let dateStr = formatDate(group.meeting.createdAt)
                                        Image(systemName: "calendar")
                                            .font(.caption).foregroundStyle(.purple)
                                        Text(title)
                                            .font(.subheadline).fontWeight(.semibold)
                                        Spacer()
                                        Text(String(format: loc("speech_count_fmt_short"), clipCount))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                        Text(dateStr)
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.purple.opacity(0.06))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteMeetingClipsTarget = group
                                        showDeleteMeetingClipsConfirm = true
                                    } label: {
                                        Label(loc("delete_meeting_clips"), systemImage: "trash")
                                    }
                                }

                                // 该会议的发言片段（折叠时隐藏）
                                if !collapsedGroups.contains(group.id) {
                                    ForEach(Array(group.clips.enumerated()), id: \.element.id) { _, clip in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(alignment: .top, spacing: 6) {
                                            // 批量选择复选框
                                            if batchSelectMode {
                                                let isSelected = selectedClipIds.contains(clip.id)
                                                let iconName = isSelected ? "checkmark.circle.fill" : "circle"
                                                let iconColor: Color = isSelected ? .purple : .secondary
                                                Button {
                                                    if isSelected {
                                                        selectedClipIds.remove(clip.id)
                                                    } else {
                                                        selectedClipIds.insert(clip.id)
                                                    }
                                                } label: {
                                                    Image(systemName: iconName)
                                                        .foregroundStyle(iconColor)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(clip.cleanedText ?? clip.originalText)
                                                    .font(.body)
                                        HStack {
                                            Button {
                                                playClip(clip, meeting: group.meeting)
                                            } label: {
                                                Image(systemName: clipPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                                    .font(.caption).foregroundStyle(.blue)
                                            }
                                            .buttonStyle(.plain)
                                            Text(formatTime(clip.startTime))
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text("· \(String(format: "%.1f", clip.endTime - clip.startTime))s")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                            if !batchSelectMode {
                                            // 删除该条发言
                                            Button {
                                                deleteClipTarget = clip
                                                showDeleteClipConfirm = true
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.caption).foregroundStyle(.red.opacity(0.5))
                                            }
                                            .buttonStyle(.plain)
                                            .help(loc("delete_speech_clip"))
                                            }
                                            // 重新分配说话人
                                            Menu {
                                                ForEach(contacts) { contact in
                                                    Button {
                                                        reassignClip(clip, to: contact)
                                                    } label: {
                                                        Text(clip.contactId == contact.id ? "✓  \(contact.name)" : "     \(contact.name)")
                                                    }
                                                }
                                                Divider()
                                                Button {
                                                    reassignClipToNewSpeaker(clip)
                                                } label: {
                                                    Text("+ \(loc("add_person"))")
                                                }
                                            } label: {
                                                Image(systemName: "person.fill.questionmark")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            .menuStyle(.borderlessButton)
                                            .frame(width: 20)
                                        }
                                            } // inner VStack (text + controls)
                                        } // outer HStack (checkbox + inner)
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 6)
                                    Divider().padding(.leading, 20)
                                }
                                }  // closes if !collapsedGroups
                            }
                            .background(.regularMaterial.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    private var companyStats: [String: Int] {
        var stats: [String: Int] = [:]
        var noCompany = 0
        for c in contacts {
            if let company = c.company, !company.isEmpty {
                stats[company, default: 0] += 1
            } else {
                noCompany += 1
            }
        }
        if noCompany > 0 { stats[loc("no_company")] = noCompany }
        return stats
    }

    private func personColor(_ name: String) -> Color {
        let c: [Color] = [.purple, .blue, .orange, .green, .pink, .teal, .indigo, .mint]
        return c[abs(name.hashValue) % c.count]
    }

    private func saveAttrs(_ contact: Contact) {
        let name = editingAttrName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let updated = Contact(
            id: contact.id,
            name: name,
            role: editingAttrRole.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editingAttrRole.trimmingCharacters(in: .whitespaces),
            company: editingAttrCompany.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editingAttrCompany.trimmingCharacters(in: .whitespaces),
            avatarUrl: contact.avatarUrl,
            createdAt: contact.createdAt,
            updatedAt: Date()
        )
        try? db.saveContact(updated)
        selectedContact = updated
        contacts = db.fetchAllContacts()
        isDirty = false
    }

    private func setDirtyIfChanged(_ contact: Contact) {
        guard selectedContact?.id == contact.id else { return }
        let nameChanged = editingAttrName.trimmingCharacters(in: .whitespaces) != contact.name
        let roleChanged = editingAttrRole.trimmingCharacters(in: .whitespaces) != (contact.role ?? "")
        let companyChanged = editingAttrCompany.trimmingCharacters(in: .whitespaces) != (contact.company ?? "")
        isDirty = nameChanged || roleChanged || companyChanged
    }

    private func playClip(_ clip: SpeechClip, meeting: Meeting) {
        let url = meeting.localAudioURL
        clipPlayer.playbackEndTime = clip.endTime
        clipPlayer.seek(to: clip.startTime)
        if !clipPlayer.hasPlayer {
            clipPlayer.startPlaying(url: url)
            // 等播放器初始化后再 seek 一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                clipPlayer.playbackEndTime = clip.endTime
                clipPlayer.seek(to: clip.startTime)
                if !clipPlayer.isPlaying { clipPlayer.resume() }
            }
        } else if !clipPlayer.isPlaying {
            clipPlayer.resume()
        }
    }

    private func reassignClip(_ clip: SpeechClip, to contact: Contact) {
        do {
            try db.updateSpeechClipContact(clipId: clip.id, speakerLabel: contact.name, contactId: contact.id)
            // 将原发言人的声纹合并到目标联系人，持续优化声纹档案
            let clipDuration = Float(max(0, clip.endTime - clip.startTime))
            try? db.mergeSpeakerEmbeddingToContact(
                meetingId: clip.meetingId,
                speakerLabel: clip.speakerLabel,
                contactId: contact.id,
                duration: clipDuration
            )
            refreshClips()
        } catch {
            AppLog.warn("reassignClip failed clip=\(clip.id): \(error.localizedDescription)")
        }
    }

    private func reassignClipToNewSpeaker(_ clip: SpeechClip) {
        // 弹出新增联系人弹窗，保存后自动分配
        showAddSheet = true
        // 记录待分配的 clip，在 onAppear 刷新联系人列表后处理
        pendingReassignClip = clip
    }

    private func formatTime(_ t: Double) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func refreshClips() {
        guard let selected = selectedContact else { return }
        let items = db.fetchSpeechClipsGroupedByMeeting(forContact: selected.id)
        groupedClips = items.map { PersonGroupedClips(meeting: $0.meeting, clips: $0.clips) }
    }
}

struct ContactEditView: View {
    var existing: Contact?
    var onSave: (Contact) -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var role = ""
    @State private var company = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(existing != nil ? loc("edit") : loc("add_person")).font(.headline)
            TextField(loc("name"), text: $name).textFieldStyle(.roundedBorder)
            TextField(loc("role_hint"), text: $role).textFieldStyle(.roundedBorder)
            TextField(loc("org_hint"), text: $company).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button(loc("cancel")) { onCancel() }.controlSize(.large); Spacer()
                Button(loc("save")) {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    onSave(Contact(id: existing?.id ?? UUID().uuidString, name: n,
                        role: role.trimmingCharacters(in: .whitespaces).isEmpty ? nil : role.trimmingCharacters(in: .whitespaces),
                        company: company.trimmingCharacters(in: .whitespaces).isEmpty ? nil : company.trimmingCharacters(in: .whitespaces),
                        avatarUrl: existing?.avatarUrl, createdAt: existing?.createdAt ?? Date(), updatedAt: Date()))
                }.buttonStyle(.borderedProminent).tint(.purple).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).controlSize(.large)
            }
        }.padding().frame(width: 320)
        .onAppear { if let c = existing { name = c.name; role = c.role ?? ""; company = c.company ?? "" } }
    }
}
