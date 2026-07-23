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

        // 兜底：对仍未匹配的 "?" 段，用时间最近邻声纹段赋值
        // 解决首句因与声纹段边界偏差（<0.15s 重叠）而漏标的问题
        results = fallbackNearestNeighbor(transcripts: results, diarization: diarization)

        return results
    }

    /// 最近邻兜底对齐：对 speakerLabel 为 "?" 的段，分配到时间上最近的声纹段
    private static func fallbackNearestNeighbor(
        transcripts: [TranscriptSegment],
        diarization: [DiarizedSegment]
    ) -> [TranscriptSegment] {
        var results = transcripts
        for i in 0..<results.count where results[i].speakerLabel == "?" {
            let seg = results[i]
            let segMid = (seg.startTime + seg.endTime) / 2.0
            var bestDist = Double.infinity
            var bestSpeaker: String?
            for d in diarization {
                let dMid = (d.startTime + d.endTime) / 2.0
                let dist = abs(segMid - dMid)
                if dist < bestDist {
                    bestDist = dist
                    bestSpeaker = d.speakerId
                }
            }
            if let speaker = bestSpeaker {
                results[i].speakerLabel = speaker
                AppLog.info("[Alignment] Fallback nearest-neighbor: segment \(seg.id) (t=\(String(format: "%.2f", seg.startTime))-\(String(format: "%.2f", seg.endTime))) → \(speaker) (dist=\(String(format: "%.2f", bestDist))s)")
            }
        }
        return results
    }
}
