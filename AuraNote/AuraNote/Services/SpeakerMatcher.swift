import Foundation

/// 声纹特征档案：可用于比对的人员声纹特征（来源于通讯录联系人或前面已分析出的声纹向量）
struct VoiceprintProfile {
    enum SourceType {
        case contact        // 通讯录联系人
        case priorSession   // 前面已分析出的声纹特征（如历史会议/已知 Speaker）
    }
    let id: String           // 联系人 ID 或 前面分析的 Speaker/Person ID
    let name: String         // 人员姓名或人员标签
    let embedding: [Float]   // 192 维声纹特征向量
    let sourceType: SourceType

    init(id: String, name: String, embedding: [Float], sourceType: SourceType = .contact) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sourceType = sourceType
    }
}

/// 声纹匹配结果
struct SpeakerMatchResult {
    /// 高置信度匹配：speakerId → (contactName, contactId, score)
    let highConfidence: [String: (name: String, contactId: String, score: Float)]
    /// 所有匹配（包括低置信度）
    let allMatches: [String: (contactId: String, contactName: String, score: Float)]
    /// 已匹配的 speaker ID 集合
    let matchedSpeakerIds: Set<String>
}

/// 声纹匹配服务：将声纹分离得到的 speaker embeddings 与已知特征库（包含通讯录与前面已分析出的向量）进行比对
enum SpeakerMatcher {

    /// 执行全量声纹匹配比对
    /// - Parameters:
    ///   - embeddings: 声纹分离产生的 speaker embedding 字典
    ///   - profiles: 已有参考声纹档案集合（通讯录 + 前面已分析出的声纹向量）
    /// - Returns: 匹配结果，包含高置信度同一个人判定和全部候选匹配
    static func match(
        embeddings: [String: [Float]],
        against profiles: [VoiceprintProfile]
    ) -> SpeakerMatchResult {
        guard !profiles.isEmpty, !embeddings.isEmpty else {
            return SpeakerMatchResult(highConfidence: [:], allMatches: [:], matchedSpeakerIds: [])
        }

        AppLog.info("[SpeakerMatcher] Starting voiceprint matching for \(embeddings.count) new speakers against \(profiles.count) reference profiles (contacts & prior embeddings)")

        let threshold = SettingsManager.shared.matchingThreshold
        let highThreshold = SettingsManager.shared.highConfidenceThreshold

        var candidates: [(speakerId: String, profile: VoiceprintProfile, score: Float)] = []

        for (speakerId, newEmb) in embeddings {
            for profile in profiles {
                // 跳过临时发言人特征档案，防止自我匹配（Speaker_X vs Speaker_X 得分 1.0）
                let isTempProfile = profile.name.hasPrefix("Speaker_") || profile.name.contains("_Speaker_") || profile.id.contains("Speaker_")
                if isTempProfile || speakerId == profile.name {
                    continue
                }

                let score = DiarizationService.cosineSimilarity(newEmb, profile.embedding)
                if score >= threshold {
                    AppLog.info("[SpeakerMatcher]   Candidate match: \(speakerId) vs '\(profile.name)' (type: \(profile.sourceType)): score=\(String(format: "%.4f", score)) >= threshold \(threshold)")
                    candidates.append((speakerId, profile, score))
                }
            }
        }

        // 按得分从高到低排序，进行贪心一比一分配
        candidates.sort { $0.score > $1.score }

        var assignedSpeakers = Set<String>()
        var assignedProfiles = Set<String>()
        var allMatches: [String: (contactId: String, contactName: String, score: Float)] = [:]
        var highConfidence: [String: (name: String, contactId: String, score: Float)] = [:]

        for c in candidates {
            guard !assignedSpeakers.contains(c.speakerId),
                  !assignedProfiles.contains(c.profile.id) else { continue }

            assignedSpeakers.insert(c.speakerId)
            assignedProfiles.insert(c.profile.id)

            allMatches[c.speakerId] = (contactId: c.profile.id, contactName: c.profile.name, score: c.score)

            if c.score >= highThreshold {
                highConfidence[c.speakerId] = (name: c.profile.name, contactId: c.profile.id, score: c.score)
                AppLog.info("[SpeakerMatcher]   => SAME PERSON CONFIRMED: \(c.speakerId) is SAME PERSON as '\(c.profile.name)' (score: \(String(format: "%.4f", c.score)) >= \(highThreshold))")
            } else {
                AppLog.info("[SpeakerMatcher]   => CANDIDATE MATCH: \(c.speakerId) matched '\(c.profile.name)' (score: \(String(format: "%.4f", c.score)) < highThreshold \(highThreshold))")
            }
        }

        let matchedIds = Set(highConfidence.keys)
        let matchedNames = Set(highConfidence.values.map(\.name))
        AppLog.info("[SpeakerMatcher] Voiceprint matching result: \(highConfidence.count) high-confidence matches → [\(matchedNames.sorted().joined(separator: ", "))]")

        return SpeakerMatchResult(
            highConfidence: highConfidence,
            allMatches: allMatches,
            matchedSpeakerIds: matchedIds
        )
    }

    /// 兼容旧版接口（只传 knownContacts 元组数组）
    static func match(
        embeddings: [String: [Float]],
        against knownContacts: [(id: String, name: String, embedding: [Float])]
    ) -> SpeakerMatchResult {
        let profiles = knownContacts.map {
            VoiceprintProfile(id: $0.id, name: $0.name, embedding: $0.embedding, sourceType: .contact)
        }
        return match(embeddings: embeddings, against: profiles)
    }
}

