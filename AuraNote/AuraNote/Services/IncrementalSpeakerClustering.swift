import Foundation

/// 增量声纹聚类组件，供实时录音和离线分析共用。
///
/// 维护运行中的聚类集合，每个新 embedding 加入时自动归入最近聚类或新建聚类。
/// 周期性重聚类防止质心漂移。
/// 阈值统一使用余弦距离（0~2，与 sherpa-onnx 一致）：距离 < threshold → 合并。
actor IncrementalSpeakerClustering {
    /// 聚类条目：id（Speaker_A 等）、质心向量、归入次数
    private var clusters: [(id: String, centroid: [Float], count: Int)] = []
    /// 已处理的 embedding 总数（用于触发周期性重聚类）
    private var embeddingCount = 0
    /// 新建聚类时的编号计数器
    private var clusterCounter = 0
    /// 合并阈值（余弦距离 0~2），距离 < 此值时合并为同一说话人
    private let mergeDistanceThreshold: Float

    /// 当前聚类数
    var speakerCount: Int { clusters.count }

    /// - Parameter mergeDistanceThreshold: 合并阈值（余弦距离 0~2），默认 0.30（等价余弦相似度 0.70）
    init(mergeDistanceThreshold: Float = SettingsManager.shared.incrementalClusteringDistance) {
        self.mergeDistanceThreshold = mergeDistanceThreshold
    }

    // MARK: - Public

    /// 加入一个声纹向量，返回对应的 speakerId
    func addEmbedding(_ embedding: [Float]) -> String {
        embeddingCount += 1

        // 查找距离最近的已有聚类（余弦距离越小越相似）
        var bestDist: Float = 2.0  // 余弦距离最大为 2
        var bestIndex: Int = -1
        for (i, cluster) in clusters.enumerated() {
            let dist = cosineDistance(embedding, cluster.centroid)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }

        if bestDist < mergeDistanceThreshold, bestIndex >= 0 {
            // 合并到已有聚类：仅在高自信度 (dist < 0.35) 时更新质心，防止边缘交界声音污染主质心致男女声混淆
            var cluster = clusters[bestIndex]
            let newCount = cluster.count + 1
            if bestDist < 0.35 {
                var newCentroid = cluster.centroid
                for i in 0..<newCentroid.count {
                    newCentroid[i] = (cluster.centroid[i] * Float(cluster.count) + embedding[i]) / Float(newCount)
                }
                clusters[bestIndex] = (id: cluster.id, centroid: newCentroid, count: newCount)
            } else {
                clusters[bestIndex] = (id: cluster.id, centroid: cluster.centroid, count: newCount)
            }

            AppLog.info("[Clustering] #\(embeddingCount) merged → \(cluster.id) (dist=\(String(format: "%.4f", bestDist)), clusterSize=\(newCount), totalClusters=\(clusters.count))")
            return cluster.id
        } else {
            // 新建聚类
            let label = speakerLabel(clusterCounter)
            clusterCounter += 1
            clusters.append((id: label, centroid: embedding, count: 1))
            AppLog.info("[Clustering] #\(embeddingCount) new → \(label) (bestDist=\(String(format: "%.4f", bestDist)), threshold=\(String(format: "%.4f", mergeDistanceThreshold)), totalClusters=\(clusters.count))")
            return label
        }
    }

    /// 批量聚类：重置后一次性加入所有 embedding，返回 key → speakerId 映射
    func clusterAll(_ embeddings: [String: [Float]]) -> [String: String] {
        reset()
        var labels: [String: String] = [:]
        for (key, emb) in embeddings {
            labels[key] = addEmbedding(emb)
        }
        return labels
    }

    /// 获取所有聚类的质心（供跨上下文传递）
    func getAllClusters() -> [(id: String, centroid: [Float])] {
        clusters.map { ($0.id, $0.centroid) }
    }

    /// 聚类级合并：在所有段处理完后，用各簇平均声纹互相对比，合并相似簇。
    /// 平均声纹比单段声纹更稳定，可容忍稍高阈值。
    /// - Parameter threshold: 合并阈值（余弦距离），默认使用 SettingsManager.clusterMergeDistance（独立于逐段阈值）
    /// - Returns: 标签重映射表 [旧标签 → 新标签]，未变化的标签不出现在映射中
    func mergeSimilarClusters(threshold: Float? = nil) -> [String: String] {
        let effectiveThreshold = threshold ?? SettingsManager.shared.clusterMergeDistance
        guard clusters.count > 1 else { return [:] }

        // 按 count 降序排列（大聚类优先保留标签）
        let sorted = clusters.sorted { $0.count > $1.count }
        var remap: [String: String] = [:]
        var used = Set<Int>()
        var merged: [(id: String, centroid: [Float], count: Int)] = []

        for i in 0..<sorted.count {
            guard !used.contains(i) else { continue }
            var current = sorted[i]
            used.insert(i)
            for j in (i + 1)..<sorted.count where !used.contains(j) {
                let dist = cosineDistance(current.centroid, sorted[j].centroid)
                if dist < effectiveThreshold {
                    // 合并 j → i：加权平均质心
                    let totalCount = current.count + sorted[j].count
                    var newCentroid = current.centroid
                    for k in 0..<newCentroid.count {
                        newCentroid[k] = (current.centroid[k] * Float(current.count) + sorted[j].centroid[k] * Float(sorted[j].count)) / Float(totalCount)
                    }
                    current = (id: current.id, centroid: newCentroid, count: totalCount)
                    used.insert(j)
                    remap[sorted[j].id] = current.id
                    AppLog.info("[Clustering] cluster merge: \(sorted[j].id) → \(current.id) (dist=\(String(format: "%.4f", dist)), mergedSize=\(totalCount))")
                }
            }
            merged.append(current)
        }

        // 更新内部聚类列表及标签
        clusters = merged.enumerated().map { (idx, c) in
            (id: speakerLabel(idx), centroid: c.centroid, count: c.count)
        }
        // 被合并的簇标签重映射到新标签
        var finalRemap: [String: String] = [:]
        let newLabels = clusters.map { $0.id }
        for i in 0..<merged.count {
            let oldId = merged[i].id
            let newId = newLabels[i]
            if oldId != newId {
                finalRemap[oldId] = newId
            }
            // 曾被映射到 oldId 的标签现在应指向 newId
            for (from, to) in remap where to == oldId {
                finalRemap[from] = newId
            }
        }
        // 未被合并的簇，标签若变化也记录
        for i in 0..<merged.count {
            let oldId = merged[i].id
            let newId = newLabels[i]
            if oldId != newId && finalRemap[oldId] == nil {
                finalRemap[oldId] = newId
            }
        }
        clusterCounter = merged.count

        if !finalRemap.isEmpty {
            AppLog.info("[Clustering] cluster merge result: \(finalRemap.count) labels remapped, final clusters=\(clusters.count)")
        }
        return finalRemap
    }

    /// 重置状态
    func reset() {
        clusters = []
        clusterCounter = 0
        embeddingCount = 0
    }

    // MARK: - Private

    /// 全量重聚类：按质心相似度重新归并，防止增量漂移
    private func recluster() {
        guard clusters.count > 1 else { return }
        // 按 count 降序排列（大聚类优先保留）
        let sorted = clusters.sorted { $0.count > $1.count }
        var merged: [(id: String, centroid: [Float], count: Int)] = []
        var used = Set<Int>()

        for i in 0..<sorted.count {
            guard !used.contains(i) else { continue }
            var current = sorted[i]
            used.insert(i)
            for j in (i + 1)..<sorted.count where !used.contains(j) {
                let dist = cosineDistance(current.centroid, sorted[j].centroid)
                if dist < mergeDistanceThreshold {
                    // 合并 j 到 i
                    let totalCount = current.count + sorted[j].count
                    var newCentroid = current.centroid
                    for k in 0..<newCentroid.count {
                        newCentroid[k] = (current.centroid[k] * Float(current.count) + sorted[j].centroid[k] * Float(sorted[j].count)) / Float(totalCount)
                    }
                    current = (id: current.id, centroid: newCentroid, count: totalCount)
                    used.insert(j)
                }
            }
            merged.append(current)
        }

        // 重新分配标签
        clusters = merged.enumerated().map { (idx, c) in
            (id: speakerLabel(idx), centroid: c.centroid, count: c.count)
        }
        clusterCounter = merged.count
    }

    private func speakerLabel(_ index: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        if index < letters.count {
            let char = letters[letters.index(letters.startIndex, offsetBy: index)]
            return "Speaker_\(char)"
        }
        return "Speaker_\(index)"
    }

    /// 余弦距离（0~2），与 sherpa-onnx FastClustering 语义一致
    /// distance = 1 - cosine_similarity，范围 [0, 2]
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let den = sqrt(magA) * sqrt(magB)
        let sim = den > 0 ? max(-1, min(1, dot / den)) : 0
        return max(0, min(2, 1 - sim))  // 余弦距离，钳位至 [0, 2]
    }
}
