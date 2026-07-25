# AuraNote 混合流式声纹分离逻辑 (Hybrid Diarization)

本文档阐述 AuraNote 应用中针对会议、录音等场景的说话人分离与声纹识别架构。为了兼顾极高的分离精度、对“抢话（重叠语音）”的支持以及性能，AuraNote 采用了 **「能量 VAD 粗筛 + Neural VAD 精细切割 + ERes2Net 全局声纹池匹配」** 的混合管线 (Hybrid Pipeline) 设计。

## 1. 架构总览

在真实的流式录音或离线音频导入场景中，系统会将音频送入一个**三级流水线**进行处理。整个流程不依赖于大模型转写的时间轴，而是从底层音频采样级别建立独立的声纹时间轴，最终通过“重叠映射 (Overlap Matching)”算法与转写文字完美贴合。

### 核心三级管线

1. **Stage 1: 能量 VAD (Energy VAD) - 粗筛大段落**
   - **机制**：通过音频样本的能量（振幅）进行快速判定，遇到低于特定阈值（默认 `0.02`）的静音超过 1 秒时，将前后语音切分为一个大段。
   - **目的**：以 $O(n)$ 复杂度瞬间跳过大量无声片段，保证 CPU 资源全用在刀刃上；同时按照最长 8 秒限制强制切分，避免底层模型因超长音频引发 OOM。

2. **Stage 2: 神经网络 VAD (Neural VAD) - 精细切割与重叠检测**
   - **底层引擎**：利用 `sherpa-onnx` 运行 `pyannote-segmentation-3-0` 高精度声学模型。
   - **机制**：
     - **极严配置**：向底层传递参数 `clustering.threshold = 0.1`（距离极小），强迫底层只进行极为细腻的切割，而**完全不进行同源片段合并**。
     - **重叠支持 (OSD)**：该层模型原生支持重叠语音检测，当遇到多人抢话或环境复杂时，它会在同一时间起点吐出**多条时间轴重叠**的独立细微片段。
   - **目的**：绝不放过任何一次说话人切换。宁可产生冗余的重叠片段，也坚决避免把不同人的声音错误混合到同一段中。

3. **Stage 3: 3D-Speaker (ERes2Net) - 全局声纹提取与熔接**
   - **机制**：
     - **声纹提取**：对 Stage 2 输出的每一个极度纯净的“细切片”，送入 `ERes2Net` 提取 192 维的声纹特征向量。
     - **聚类与匹配**：在外层维护一个全局联系人池（包含已存储的常用联系人和动态分配的新说话人），使用余弦相似度（Cosine Similarity，默认阈值 `0.70`）进行比对归并。
     - **片段熔接去重 (Segment Merging)**：扫描所有匹配好的片段，如果发现有**时间重叠或紧密相邻，且被归为同一个说话人**的切片，则立刻将它们熔接（合并）为一个干净的长片段。
   - **目的**：实现真正的说话人身份认证与归类，并消除底层带来的视觉干扰和数据双倍计分问题。

## 2. 关键算法详解

### 2.1 重叠熔接去重 (Segment Merging)

当 Neural VAD 因环境噪音或抢话输出多条同一时间轴的重叠片段时，只要这些片段都被 ERes2Net 鉴定为“说话人 A”，AuraNote 就会执行以下重叠消除逻辑：

```swift
// 同说话人重叠片段合并去重算法
let groupedByLabel = Dictionary(grouping: labeledSubSegments, by: { $0.label })
for (label, group) in groupedByLabel {
    let sorted = group.sorted { $0.start < $1.start }
    var currentMerged: [...] = []
    
    for seg in sorted {
        if let last = currentMerged.last, seg.start <= last.end + 0.1 { // 相邻或重叠
            currentMerged[currentMerged.count - 1] = (
                start: last.start,
                end: max(last.end, seg.end), // 取最外沿
                label: label,
                ...
            )
        } else {
            currentMerged.append(seg)
        }
    }
}
```

**作用**：
- 在测试页面中，消除同一人说话时产生两条并行线段的怪异视觉现象。
- 保证真实的“不同人抢话”（如 说话人 A 和 说话人 B 时间重叠）被完美保留。

### 2.2 录音主链路的重叠分配 (Overlap Matching)

在主界面的真实录音中，我们需要把转写引擎（Whisper）产出的“文字气泡”和声纹管线产出的“声纹标签”绑定在一起。由于两者的分段时间轴不可能 100% 对齐，我们采用了**基于真实音频样本长度求交集的主导者算法**：

1. 将一段 Whisper 文字对应的音频样本映射回它的起止时间。
2. 遍历该时间段内所有覆盖进来的声纹分段（Stage 3 熔接后的结果）。
3. 求出每个声纹标签在这个文字气泡里的**交集时长（Overlap Duration）**。
4. 统计得出占比最高的主导说话人（Dominant Speaker），将该文字气泡归属给 Ta。

## 3. 核心阈值与参数配置 (`SettingsManager.swift`)

混合管线的准确性极度依赖内外两层阈值的动态平衡：

- **底层引擎参数 (`SherpaDiarizationConfig`)**
  - `clustering.threshold = 0.1`：不可更改。用于完全压制底层合并冲动。
- **全局声纹匹配参数 (`SettingsManager`)**
  - `matchingThreshold` & `liveMatchingThreshold`：**默认 0.70**。当提取出的声纹与已知联系人的余弦相似度 >= 0.70 时，直接绑定身份（如“张总”）。
  - `incrementalClusteringDistance` & `clusterMergeDistance`：**默认 0.70**。针对未知说话人的增量聚类，若特征差异极小（通过质心漂移算法），则归入同一个虚拟发言人（如“说话人 1”）。

## 4. 总结

AuraNote 的声纹分离系统彻底摒弃了单一模型极易出错的固有弱点，转而让不同的神经网络各司其职：
- **pyannote** 专做精细“主刀”，宁可错切一千，不漏过一次抢话。
- **ERes2Net** 专做“鉴定专家”，凭借极强的 192 维特征提取能力把错切的片段全部拼回原主。
两者结合，实现了极具鲁棒性和商用潜力的流式分离体验。
