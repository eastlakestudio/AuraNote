import SwiftUI

/// 收集各段在 ScrollView 坐标系中的位置
struct SegmentFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct UnifiedTranscriptEditor: View {
    @Binding var segments: [TranscriptSegment]
    @Binding var filterSpeaker: String?
    @Binding var activeSegmentId: String?
    @Binding var meetingAttendees: String
    @Binding var scrollToId: String?
    var searchQuery: String = ""
    var flashSegmentId: String? = nil
    var onFlashDone: (() -> Void)? = nil
    var contacts: [String] = []
    var onPlaySegment: ((TranscriptSegment) -> Void)?
    var onSpeakerChanged: ((String, String) -> Void)?
    var onTextChanged: ((String, String) -> Void)?

    @State private var segmentFrames: [String: CGRect] = [:]
    @State private var scrollViewHeight: CGFloat = 0

    private var attendeeList: [String] {
        if meetingAttendees.isEmpty { return [] }
        return meetingAttendees.split(separator: " ").map(String.init)
    }

    private var allSpeakers: [String] {
        var seen = Set<String>()
        return segments.map { $0.speakerLabel }.filter { seen.insert($0).inserted }
    }

    private let speakerColors: [Color] = [.purple, .blue, .orange, .green, .pink, .teal, .indigo, .mint, .cyan, .brown, .yellow]

    private func colorForSpeaker(_ name: String) -> Color {
        guard let idx = allSpeakers.firstIndex(of: name) else { return .gray }
        return speakerColors[idx % speakerColors.count]
    }

    private var displayedSegments: [(Int, TranscriptSegment)] {
        segments.filter { $0.isFinal }.enumerated().compactMap { idx, seg in
            if let filter = filterSpeaker, seg.speakerLabel != filter { return nil }
            return (idx, seg)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let filter = filterSpeaker {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.purple)
                    Text(String(format: loc("filter_prefix"), filter)).font(.subheadline).foregroundStyle(.purple)
                    Spacer()
                    Button { filterSpeaker = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.purple.opacity(0.08))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedSegments, id: \.1.id) { displayedIdx, seg in
                            TranscriptRow(
                                segment: seg,
                                index: displayedIdx + 1,
                                isFirst: displayedIdx == 0,
                                isActive: seg.id == activeSegmentId,
                                searchQuery: searchQuery,
                                flashSegmentId: flashSegmentId,
                                existingSpeakers: allSpeakers.filter { $0 != seg.speakerLabel },
                                attendees: attendeeList,
                                speakerColor: colorForSpeaker(seg.speakerLabel),
                                onTextChange: { newText in
                                    if let si = segments.firstIndex(where: { $0.id == seg.id }) {
                                        segments[si].text = newText
                                        onTextChanged?(seg.id, newText)
                                    }
                                },
                                onSpeakerChange: { newSpeaker in
                                    onSpeakerChanged?(seg.id, newSpeaker)
                                },
                                onMergeUp: {
                                    if let si = segments.firstIndex(where: { $0.id == seg.id }) {
                                        mergeUp(si)
                                    }
                                },
                                onSplitAfter: { textAfter in
                                    if let si = segments.firstIndex(where: { $0.id == seg.id }) {
                                        splitAfter(si, text: textAfter)
                                    }
                                },
                                onPlay: { onPlaySegment?(seg) },
                                onFlashDone: { onFlashDone?() }
                            )
                            .id(seg.id)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: SegmentFrameKey.self,
                                        value: [seg.id: geo.frame(in: .named("ts"))]
                                    )
                                }
                            )
                            
                            // 淡分割线（非最后一项）
                            if displayedIdx != displayedSegments.last?.0 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.leading, 80)
                            }
                        }
                    }
                }
                .coordinateSpace(name: "ts")
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { scrollViewHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in scrollViewHeight = h }
                    }
                )
                .onPreferenceChange(SegmentFrameKey.self) { segmentFrames = $0 }
                .onChange(of: activeSegmentId) { _, newId in
                    guard let id = newId else { return }
                    // 底色先切换（即时生效，通过 isActive 绑定）
                    // 延迟滚动，确保高亮切换完成，再判断是否需要滚动
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let em: CGFloat = 18
                        let threshold: CGFloat = 6 * em
                        let shouldScroll: Bool
                        if let frame = segmentFrames[id], scrollViewHeight > 0 {
                            // 仅当段在可视区底部 6em 内或已滚出顶部时才触发滚动
                            shouldScroll = frame.minY > scrollViewHeight - threshold || frame.minY < -threshold
                        } else {
                            shouldScroll = true
                        }
                        if shouldScroll {
                            withAnimation(.easeOut(duration: 2.0)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: scrollToId) { _, targetId in
                    guard let id = targetId else { return }
                    // 搜索定位：立即滚动到目标段
                    withAnimation(.easeOut(duration: 0.5)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                    // 滚动完成后清除，避免重复触发
                    DispatchQueue.main.async { scrollToId = nil }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func splitAfter(_ idx: Int, text: String) {
        guard idx < segments.count else { return }
        let seg = segments[idx]
        // 基于文本长度比例估算新段时长，最少 1 秒
        let totalLen = max(1, seg.text.count + text.count)
        let estimatedDuration = max(1.0, Double(text.count) / Double(totalLen) * (seg.endTime - seg.startTime))
        segments.insert(TranscriptSegment(
            id: UUID().uuidString, startTime: seg.endTime, endTime: seg.endTime + estimatedDuration,
            text: text, speakerLabel: seg.speakerLabel, contactId: seg.contactId, isFinal: true
        ), at: idx + 1)
    }

    private func mergeUp(_ idx: Int) {
        guard idx > 0 else { return }
        let prev = segments[idx - 1], curr = segments[idx]
        guard prev.speakerLabel == curr.speakerLabel else { return }
        segments[idx - 1] = TranscriptSegment(
            id: prev.id, startTime: prev.startTime, endTime: curr.endTime,
            text: prev.text.isEmpty ? curr.text : prev.text + " " + curr.text,
            speakerLabel: prev.speakerLabel, contactId: prev.contactId, isFinal: true
        )
        segments.remove(at: idx)
    }
}

struct TranscriptRow: View {
    let segment: TranscriptSegment
    let index: Int
    let isFirst: Bool
    let isActive: Bool
    let searchQuery: String
    let flashSegmentId: String?
    let existingSpeakers: [String]
    let attendees: [String]
    let speakerColor: Color
    var onTextChange: (String) -> Void
    var onSpeakerChange: (String) -> Void
    var onMergeUp: () -> Void
    var onSplitAfter: (String) -> Void
    var onPlay: (() -> Void)?
    var onFlashDone: (() -> Void)?

    @State private var editText: String
    @State private var showRenamePopover = false
    @State private var newSpeakerName = ""
    @State private var skipNextNewlineCheck = false
    @State private var isHovered = false
    @State private var textEditorHeight: CGFloat = 44
    @State private var flashOpacity: Double = 0

    private var isSearchMatch: Bool {
        guard !searchQuery.isEmpty else { return false }
        return segment.text.lowercased().contains(searchQuery.lowercased())
    }

    private var isFlashTarget: Bool {
        guard let fid = flashSegmentId else { return false }
        return segment.id == fid
    }

    init(segment: TranscriptSegment, index: Int, isFirst: Bool, isActive: Bool, searchQuery: String = "", flashSegmentId: String? = nil, existingSpeakers: [String], attendees: [String], speakerColor: Color, onTextChange: @escaping (String) -> Void, onSpeakerChange: @escaping (String) -> Void, onMergeUp: @escaping () -> Void, onSplitAfter: @escaping (String) -> Void, onPlay: (() -> Void)? = nil, onFlashDone: (() -> Void)? = nil) {
        self.segment = segment; self.index = index; self.isFirst = isFirst; self.isActive = isActive
        self.searchQuery = searchQuery; self.flashSegmentId = flashSegmentId
        self.existingSpeakers = existingSpeakers; self.attendees = attendees; self.speakerColor = speakerColor
        self.onTextChange = onTextChange; self.onSpeakerChange = onSpeakerChange
        self.onMergeUp = onMergeUp; self.onSplitAfter = onSplitAfter; self.onPlay = onPlay
        self.onFlashDone = onFlashDone
        self._editText = State(initialValue: segment.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 第一行：序号 + 播放 + 时间 + 说话人 + 时长 + 合并
            HStack(spacing: 6) {
                Text("#\(index)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))

                Button(action: { onPlay?() }) {
                    Image(systemName: "play.circle.fill").font(.caption).foregroundStyle(.blue)
                }.buttonStyle(.plain).help(loc("play"))

                Text(formatTime(segment.startTime))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)

                Menu {
                    let otherAttendees = attendees.filter { $0 != segment.speakerLabel }
                    if !otherAttendees.isEmpty {
                        Section(loc("attendees_section")) {
                            ForEach(otherAttendees, id: \.self) { person in
                                Button(person) { onSpeakerChange(person) }
                            }
                        }
                    }
                    let otherSpeakers = existingSpeakers.filter { !attendees.contains($0) }
                    if !otherSpeakers.isEmpty {
                        Section(loc("other_speakers")) {
                            ForEach(otherSpeakers, id: \.self) { s in Button(s) { onSpeakerChange(s) } }
                        }
                    }
                    Divider()
                    Button(loc("new_ellipsis")) { newSpeakerName = ""; showRenamePopover = true }
                } label: {
                    Text(String(segment.speakerLabel.prefix(10)))
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(speakerColor, in: Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .popover(isPresented: $showRenamePopover) {
                    VStack(spacing: 8) {
                        Text(loc("new_speaker")).font(.caption).foregroundStyle(.secondary)
                        TextField(loc("name"), text: $newSpeakerName).textFieldStyle(.roundedBorder).onSubmit { confirmRename() }
                        HStack {
                            Spacer(); Button(loc("cancel")) { showRenamePopover = false }
                            Button(loc("confirm")) { confirmRename() }.buttonStyle(.borderedProminent)
                        }
                    }.padding().frame(width: 200)
                }

                let dur = max(0, segment.endTime - segment.startTime)
                Text(formatDuration(dur))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)

                Spacer()

                if !isFirst {
                    Button(action: onMergeUp) {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange.opacity(0.7))
                    }.buttonStyle(.plain).help(loc("merge"))
                }
            }
            .padding(.trailing, 16)  // 留出垂直滚动条空间，防止合并按钮被遮挡

            // 第二行：文本（左对齐说话人标签位置）
            HStack(alignment: .top, spacing: 0) {
                Spacer().frame(width: 32)  // # 序号标签宽度
                Spacer().frame(width: 22)  // ▶ 按钮宽度
                Spacer().frame(width: 42)  // 时间戳宽度
                if segment.isPlaceholder {
                    // 占位段：等待离线转写
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text(loc("transcribing_placeholder"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                } else if isSearchMatch && !searchQuery.isEmpty {
                    highlightedTextView
                } else {
                    TextEditor(text: $editText)
                        .font(.body)
                        .lineSpacing(6)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .frame(minHeight: 22, idealHeight: textEditorHeight, maxHeight: textEditorHeight)
                    .onChange(of: editText) { _, newValue in
                        recalcEditorHeight(newValue)
                        if skipNextNewlineCheck { skipNextNewlineCheck = false; return }
                        if newValue.contains("\n") {
                            let parts = newValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                            editText = parts[safe: 0] ?? ""
                            onSplitAfter(parts[safe: 1] ?? "")
                        } else { onTextChange(newValue) }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            isActive ? Color.purple.opacity(0.12) :
            flashOpacity > 0 ? Color.yellow.opacity(flashOpacity) :
            isSearchMatch ? Color.purple.opacity(0.10) :
            isHovered ? Color.blue.opacity(0.06) : Color.clear
        )
        .overlay(alignment: .leading) {
            Group {
                if isActive { Rectangle().fill(Color.purple.opacity(0.3)).frame(width: 3) }
                else if isHovered { Rectangle().fill(Color.blue.opacity(0.2)).frame(width: 3) }
            }
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { isHovered = h } }
        .onChange(of: segment.text) { _, newText in skipNextNewlineCheck = newText != editText; editText = newText }
        .onChange(of: flashSegmentId) { _, newId in
            if newId == segment.id { triggerFlash() }
        }
        .onAppear { recalcEditorHeight(editText) }
    }
    private func formatTime(_ t: Double) -> String {
        let m = Int(t)/60, s = Int(t)%60; return String(format: "%02d:%02d", m, s)
    }

    /// 搜索定位闪烁动画：黄色底色闪烁 3 次
    private func triggerFlash() {
        Task { @MainActor in
            for i in 0..<6 {
                withAnimation(.easeInOut(duration: 0.1)) {
                    flashOpacity = i % 2 == 0 ? 0.35 : 0
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
            flashOpacity = 0
            onFlashDone?()
        }
    }
    private func formatDuration(_ t: Double) -> String {
        if t < 1 { return "" }
        let m = Int(t)/60, s = Int(t)%60
        if m > 0 { return String(format: loc("duration_min_sec"), m, s) }
        return String(format: loc("duration_sec_only"), s)
    }
    /// 根据文本内容计算 TextEditor 需要的动态高度
    private func recalcEditorHeight(_ text: String) {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        // 估算可用宽度：假设行宽约 600pt（总宽 - 左侧留白 - 右侧padding）
        let estimatedWidth: CGFloat = 600
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let rect = attrStr.boundingRect(
            with: CGSize(width: estimatedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let newHeight = max(22, ceil(rect.height) + 10)
        if abs(newHeight - textEditorHeight) > 1 {
            textEditorHeight = newHeight
        }
    }
    private func confirmRename() {
        let name = newSpeakerName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { onSpeakerChange(name); showRenamePopover = false }
    }

    /// 将文本按搜索匹配拆分为高亮/非高亮片段
    private var highlightedAttributedText: AttributedString {
        var result = AttributedString(editText)
        let lower = editText.lowercased()
        let query = searchQuery.lowercased()
        guard !query.isEmpty else { return result }
        var searchStart = lower.startIndex
        while let range = lower[searchStart...].range(of: query) {
            guard let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { break }
            result[start..<end].backgroundColor = NSColor.yellow.withAlphaComponent(0.45)
            result[start..<end].font = .body.bold()
            searchStart = range.upperBound
        }
        return result
    }

    /// 带搜索高亮的只读文本视图
    private var highlightedTextView: some View {
        Text(highlightedAttributedText)
            .font(.body)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Array {
    subscript(safe idx: Int) -> Element? { indices.contains(idx) ? self[idx] : nil }
}
