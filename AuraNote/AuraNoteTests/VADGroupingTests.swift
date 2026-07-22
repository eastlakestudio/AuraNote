import XCTest
@testable import AuraNote

final class VADGroupingTests: XCTestCase {

    func testGroupBoundariesByMaxCount() {
        // 构造 25 个 0.5 秒的离散边界
        var boundaries: [(Double, Double)] = []
        for i in 0..<25 {
            let start = Double(i) * 0.6
            let end = start + 0.5
            boundaries.append((start, end))
        }

        let chunks = DiarizationService.groupBoundaries(boundaries, maxCount: 10, maxDuration: 20.0)

        // 预期分为 3 个 Chunk：10段, 10段, 5段
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].subBoundaries.count, 10)
        XCTAssertEqual(chunks[1].subBoundaries.count, 10)
        XCTAssertEqual(chunks[2].subBoundaries.count, 5)

        XCTAssertEqual(chunks[0].chunkStart, 0.0)
        XCTAssertEqual(chunks[0].chunkEnd, 9 * 0.6 + 0.5)
    }

    func testGroupBoundariesByMaxDuration() {
        // 构造 5 个 5 秒的边界 (总时长 25 秒)
        var boundaries: [(Double, Double)] = []
        for i in 0..<5 {
            let start = Double(i) * 5.0
            let end = start + 4.8
            boundaries.append((start, end))
        }

        let chunks = DiarizationService.groupBoundaries(boundaries, maxCount: 10, maxDuration: 20.0)

        // 4段累积时长 4.8*4 + 0.2*3 = 19.8s <= 20s; 第5段加入后超 20s，因此打断
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].subBoundaries.count, 4)
        XCTAssertEqual(chunks[1].subBoundaries.count, 1)
    }

    func testAssignSpeakerByOverlap() {
        let intervals = [
            DiarizedSegment(speakerId: "Speaker_A", startTime: 0.0, endTime: 2.5),
            DiarizedSegment(speakerId: "Speaker_B", startTime: 2.5, endTime: 6.0)
        ]

        // 测试段 [1.0s, 3.0s]:
        // 与 Speaker_A 重叠 [1.0, 2.5] (1.5s)
        // 与 Speaker_B 重叠 [2.5, 3.0] (0.5s)
        let spk1 = DiarizationService.assignSpeakerByOverlap(
            segStart: 1.0, segEnd: 3.0,
            speakerIntervals: intervals
        )
        XCTAssertEqual(spk1, "Speaker_A")

        // 测试段 [2.6s, 4.0s]:
        // 与 Speaker_B 重叠 [2.6, 4.0] (1.4s)
        let spk2 = DiarizationService.assignSpeakerByOverlap(
            segStart: 2.6, segEnd: 4.0,
            speakerIntervals: intervals
        )
        XCTAssertEqual(spk2, "Speaker_B")
    }
}
