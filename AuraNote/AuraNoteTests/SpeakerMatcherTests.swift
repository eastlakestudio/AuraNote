import XCTest
@testable import AuraNote

final class SpeakerMatcherTests: XCTestCase {

    func testCosineSimilarity() {
        let vecA: [Float] = [1.0, 0.0, 0.0]
        let vecB: [Float] = [1.0, 0.0, 0.0]
        let vecC: [Float] = [0.0, 1.0, 0.0]

        let simSame = DiarizationService.cosineSimilarity(vecA, vecB)
        let simOrthogonal = DiarizationService.cosineSimilarity(vecA, vecC)

        XCTAssertEqual(simSame, 1.0, accuracy: 0.0001, "相同向量的余弦相似度应为 1.0")
        XCTAssertEqual(simOrthogonal, 0.0, accuracy: 0.0001, "正交向量的余弦相似度应为 0.0")
    }

    func testSpeakerMatcherWithKnownContacts() {
        let emb1: [Float] = [0.9, 0.1, 0.0]
        let emb2: [Float] = [0.0, 0.1, 0.9]

        let knownContacts: [(id: String, name: String, embedding: [Float])] = [
            (id: "c1", name: "UnitTest_UserA", embedding: [0.91, 0.09, 0.0]),
            (id: "c2", name: "UnitTest_UserB", embedding: [0.01, 0.08, 0.92])
        ]

        let newEmbeddings: [String: [Float]] = [
            "Speaker_0": emb1,
            "Speaker_1": emb2
        ]

        let result = SpeakerMatcher.match(embeddings: newEmbeddings, against: knownContacts)

        XCTAssertEqual(result.highConfidence.count, 2, "应成功匹配出 2 个高置信度联系人")
        XCTAssertEqual(result.highConfidence["Speaker_0"]?.name, "UnitTest_UserA")
        XCTAssertEqual(result.highConfidence["Speaker_1"]?.name, "UnitTest_UserB")
        XCTAssertTrue(result.matchedSpeakerIds.contains("Speaker_0"))
        XCTAssertTrue(result.matchedSpeakerIds.contains("Speaker_1"))
    }

    func testSpeakerMatcherWithPriorEmbeddings() {
        let embNew: [Float] = [0.8, 0.2, 0.1]

        let profiles: [VoiceprintProfile] = [
            VoiceprintProfile(id: "c1", name: "UnitTest_UserC", embedding: [0.1, 0.9, 0.0], sourceType: .contact),
            VoiceprintProfile(id: "spk_prev", name: "UnitTest_UserD", embedding: [0.82, 0.18, 0.1], sourceType: .priorSession)
        ]

        let newEmbeddings: [String: [Float]] = [
            "Speaker_New": embNew
        ]

        let result = SpeakerMatcher.match(embeddings: newEmbeddings, against: profiles)

        XCTAssertEqual(result.highConfidence.count, 1)
        XCTAssertEqual(result.highConfidence["Speaker_New"]?.name, "UnitTest_UserD")
        XCTAssertEqual(result.highConfidence["Speaker_New"]?.contactId, "spk_prev")
    }
}
