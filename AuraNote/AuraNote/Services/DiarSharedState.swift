import Foundation

/// 声纹分离结果共享状态，用于离线转写的生产者-消费者模式中安全传递数据
/// 替代 UnsafeMutablePointer，消除内存泄漏和数据竞争风险
actor DiarSharedState {
    var diarSegments: [DiarizedSegment]? = nil
    var speakerMap: [String: (name: String, contactId: String)]? = nil
    var embeddings: [String: [Float]]? = nil
    var matchedSpeakerIds: Set<String> = []

    func setDiarization(_ segments: [DiarizedSegment], embeddings: [String: [Float]]) {
        self.diarSegments = segments
        self.embeddings = embeddings
    }

    func setSpeakerMap(_ map: [String: (name: String, contactId: String)]) {
        self.speakerMap = map
    }

    func setMatchedSpeakerIds(_ ids: Set<String>) {
        self.matchedSpeakerIds = ids
    }

    func getDiarSegments() -> [DiarizedSegment]? { diarSegments }
    func getSpeakerMap() -> [String: (name: String, contactId: String)]? { speakerMap }
    func getEmbeddings() -> [String: [Float]]? { embeddings }
    func getMatchedSpeakerIds() -> Set<String> { matchedSpeakerIds }
}
