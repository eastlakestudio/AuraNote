import Foundation

/// 声纹匹配结果
struct SpeakerMatchResult {
    /// 高置信度匹配：speakerId → (contactName, contactId, score)
    let highConfidence: [String: (name: String, contactId: String, score: Float)]
    /// 所有匹配（包括低置信度）
    let allMatches: [String: (contactId: String, contactName: String, score: Float)]
    /// 已匹配的 speaker ID 集合
    let matchedSpeakerIds: Set<String>
}

/// 声纹匹配服务：将声纹分离得到的 speaker embeddings 与已知联系人库进行比对
enum SpeakerMatcher {

    /// 执行声纹匹配并返回结果
    /// - Parameters:
    ///   - embeddings: 声纹分离产生的 speaker embedding 字典
    ///   - knownContacts: 数据库中已有声纹向量的联系人
    /// - Returns: 匹配结果，包含高置信度自动绑定和全部匹配
    static func match(
        embeddings: [String: [Float]],
        against knownContacts: [(id: String, name: String, embedding: [Float])]
    ) -> SpeakerMatchResult {
        guard !knownContacts.isEmpty else {
            return SpeakerMatchResult(highConfidence: [:], allMatches: [:], matchedSpeakerIds: [])
        }

        let allMatches = DiarizationService.matchSpeakers(
            newEmbeddings: embeddings,
            knownContacts: knownContacts
        )

        let threshold = SettingsManager.shared.highConfidenceThreshold
        let highConfidence = allMatches
            .filter { $0.value.score > threshold }
            .reduce(into: [String: (name: String, contactId: String, score: Float)]()) { dict, entry in
                dict[entry.key] = (name: entry.value.contactName, contactId: entry.value.contactId, score: entry.value.score)
            }

        let matchedIds = Set(highConfidence.keys)
        let uniqueContacts = Set(highConfidence.values.map(\.name))
        AppLog.info("Voiceprint matching result: \(highConfidence.count) high-confidence matches → \(uniqueContacts.count) unique contacts (\(uniqueContacts.sorted().joined(separator: ", ")))")

        return SpeakerMatchResult(
            highConfidence: highConfidence,
            allMatches: allMatches,
            matchedSpeakerIds: matchedIds
        )
    }
}
