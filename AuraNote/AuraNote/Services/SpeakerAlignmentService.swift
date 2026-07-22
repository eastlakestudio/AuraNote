import Foundation

/// 声纹-转写时间轴对齐服务
/// 双模态对齐聚类算法：将声纹分离出的纯时间区间，匹配到带有文字的转写时间区间上
enum SpeakerAlignmentService {

    /// 将声纹分离的时间区间标注到转写片段上
    /// - Parameters:
    ///   - transcripts: 待标注的转写片段列表
    ///   - diarization: 声纹分离结果（说话人 + 时间区间）
    /// - Returns: 标注了 speakerLabel 的转写片段
    static func align(transcripts: [TranscriptSegment], diarization: [DiarizedSegment]) -> [TranscriptSegment] {
        guard !diarization.isEmpty else { return transcripts }
        var results = transcripts

        for i in 0..<results.count {
            let tSegment = results[i]
            let dur = max(0.1, tSegment.endTime - tSegment.startTime)
            
            // 提纯核心说话区间：消除句首句尾 15% 容易与上一句擦边的边缘噪点
            let trim = dur * 0.15
            let coreStart = tSegment.startTime + trim
            let coreEnd = tSegment.endTime - trim
            let midPoint = (tSegment.startTime + tSegment.endTime) / 2.0

            var bestSpeaker: String?
            var maxWeightedScore: Double = -1.0

            for dSegment in diarization {
                // 1. 核心区间重叠
                let cOverlapStart = max(coreStart, dSegment.startTime)
                let cOverlapEnd = min(coreEnd, dSegment.endTime)
                let coreOverlap = max(0.0, cOverlapEnd - cOverlapStart)

                // 2. 中心点命中 (Midpoint Containment)
                let hitsMidpoint = (midPoint >= dSegment.startTime && midPoint <= dSegment.endTime) ? 1.0 : 0.0

                // 3. 全区间重叠
                let fOverlapStart = max(tSegment.startTime, dSegment.startTime)
                let fOverlapEnd = min(tSegment.endTime, dSegment.endTime)
                let fullOverlap = max(0.0, fOverlapEnd - fOverlapStart)

                // 综合评分：核心区重叠权重 2.0，中点命中权重 0.5 * dur，全区重叠权重 0.5
                let score = coreOverlap * 2.0 + (hitsMidpoint * 0.5 * dur) + fullOverlap * 0.5

                if score > maxWeightedScore && fullOverlap >= 0.15 {
                    maxWeightedScore = score
                    bestSpeaker = dSegment.speakerId
                }
            }

            if let speaker = bestSpeaker {
                results[i].speakerLabel = speaker
            }
        }

        return results
    }
}
