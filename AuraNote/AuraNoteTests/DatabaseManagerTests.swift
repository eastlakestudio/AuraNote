import XCTest
@testable import AuraNote

@MainActor
final class DatabaseManagerTests: XCTestCase {

    // 注意：完整的 DatabaseManager 测试需要在 Xcode 中运行
    // 这里提供测试骨架，后续补充具体测试用例

    func testMeetingCreation() throws {
        let db = DatabaseManager()
        let meeting = Meeting.create(title: "测试会议", location: "会议室 A")

        try db.createMeeting(meeting)

        let meetings = db.fetchAllMeetings()
        XCTAssertFalse(meetings.isEmpty)
        let found = meetings.first { $0.id == meeting.id }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "测试会议")
        XCTAssertEqual(found?.location, "会议室 A")
        XCTAssertEqual(found?.status, .recording)
    }

    func testMeetingStatusUpdate() throws {
        let db = DatabaseManager()
        let meeting = Meeting.create(title: "状态测试")
        try db.createMeeting(meeting)

        try db.updateMeetingStatus(id: meeting.id, status: .completed, duration: 120)

        let meetings = db.fetchAllMeetings()
        let updated = meetings.first { $0.id == meeting.id }
        XCTAssertEqual(updated?.status, .completed)
        XCTAssertEqual(updated?.duration, 120)
    }

    func testSplitSpeechClip() throws {
        let db = DatabaseManager()
        let meeting = Meeting.create(title: "拆分测试")
        try db.createMeeting(meeting)
        
        let oldClip = SpeechClip(
            id: UUID().uuidString,
            meetingId: meeting.id,
            speakerLabel: "Speaker_S1",
            contactId: nil,
            startTime: 0.0,
            endTime: 10.0,
            originalText: "这是一句很长的话我想把它拆开",
            cleanedText: nil,
            audioClipPath: nil,
            isKeyClip: false
        )
        try db.saveSpeechClip(oldClip)
        
        let newClip1 = SpeechClip(
            id: UUID().uuidString,
            meetingId: meeting.id,
            speakerLabel: "Speaker_S1",
            contactId: nil,
            startTime: 0.0,
            endTime: 5.0,
            originalText: "这是一句很长的话",
            cleanedText: nil,
            audioClipPath: nil,
            isKeyClip: false
        )
        
        let newClip2 = SpeechClip(
            id: UUID().uuidString,
            meetingId: meeting.id,
            speakerLabel: "lmh",
            contactId: nil,
            startTime: 5.0,
            endTime: 10.0,
            originalText: "我想把它拆开",
            cleanedText: nil,
            audioClipPath: nil,
            isKeyClip: false
        )
        
        try db.splitSpeechClip(oldClipId: oldClip.id, newClip1: newClip1, newClip2: newClip2)
        
        let clips = db.fetchSpeechClips(meetingId: meeting.id)
        
        // 验证旧片段已被删除，且成功保存了两个新片段
        XCTAssertEqual(clips.count, 2)
        XCTAssertFalse(clips.contains { $0.id == oldClip.id })
        XCTAssertTrue(clips.contains { $0.id == newClip1.id })
        XCTAssertTrue(clips.contains { $0.id == newClip2.id })
        
        // 验证第二段的说话人已按指定的值（lmh）保存
        let clip2 = clips.first { $0.id == newClip2.id }
        XCTAssertEqual(clip2?.speakerLabel, "lmh")
    }

    func testSaveOrUpdateSpeakerContact() throws {
        let db = DatabaseManager()
        
        // 1. 测试裸 Speaker_ 开头的标签应被拦截不存入通讯录
        let nakedSpkId = "Speaker_Test_99"
        let emb: [Float] = [0.1, 0.5, 0.9]
        try db.saveOrUpdateSpeakerContact(speakerId: nakedSpkId, name: nakedSpkId, embedding: emb)
        let contacts1 = db.fetchContactsWithEmbeddings()
        XCTAssertFalse(contacts1.contains { $0.id == nakedSpkId })

        // 2. 测试带会议 ID 前缀的临时说话人可以正常存入通讯录
        let tempSpkId = "M101_Speaker_A"
        let tempName = "周报会议_Speaker_A"
        try db.saveOrUpdateSpeakerContact(speakerId: tempSpkId, name: tempName, embedding: emb)
        let contacts2 = db.fetchContactsWithEmbeddings()
        XCTAssertTrue(contacts2.contains { $0.id == tempSpkId && $0.name == tempName && $0.embedding.count == 3 })
    }
}
