# AuraNote 离线分析管线设计文档

> 版本: 2026-07-22 | 引擎: Paraformer (sherpa-onnx C API) + Pyannote 3.0 + eres2net

---

## 一、总体架构

离线分析 (`RecordingViewModel` → `transcriptionTask`) 分三步执行：

```
┌──────────────────────────────────────────────────────────────────┐
│                      离线分析管线 (3 步)                          │
│                                                                  │
│  Step 1: VAD累积式ASR转写 (FunASRService)                         │
│    Silero VAD → 合并相邻段(≤1.5s) → 累积至~30s → Paraformer     │
│    输出: [TranscriptSegment] (带 tokenTimestamps)                 │
│         ↓                                                        │
│  Step 2: 声纹分离 (DiarizationService)                            │
│    能量VAD粗筛 → Pyannote帧级(10ms)精细分割 → eres2net声纹提取  │
│    → 增量聚类 → intersectAndLabel (切句+标注)                     │
│    → refineWithEmbeddingSplit (二次校验)                          │
│    输出: [TranscriptSegment] (带 speakerLabel)                    │
│         ↓                                                        │
│  Step 3: 声纹匹配 (SpeakerMatcher)                                │
│    eres2net 声纹向量 → 余弦相似度 → 联系人绑定                    │
│    输出: 持久化到 SQLite + 绑定 contactId                         │
└──────────────────────────────────────────────────────────────────┘
```

核心代码路径：
- 管线编排: `RecordingViewModel.swift:655-708`
- ASR 转写: `FunASRService.swift:521-733`
- 声纹分离: `DiarizationService.swift:199-393`
- 切句对齐: `DiarizationService.swift:490-583`
- 二次校验: `DiarizationService.swift:763-840`

---

## 二、Step 1: VAD累积式ASR转写

### 2.1 模型依赖

| 模型 | 路径 | 用途 |
|------|------|------|
| Paraformer bilingual INT8 | `sherpa-onnx-models/funasr/offline-paraformer/model.int8.onnx` | 离线语音识别，输出 token 级时间戳 |
| Silero VAD | `sherpa-onnx-models/funasr/silero-vad/silero_vad.onnx` | 语音活动检测 |
| CT-Transformer | `sherpa-onnx-models/funasr/punct/model.onnx` | 标点恢复 |

### 2.2 五步处理流程

```
第1步: Silero VAD 逐窗检测
  ┌─────────────────────────────────────────────┐
  │ 16kHz PCM → 512样本窗口 → Silero VAD 推理    │
  │ 输出: rawSegments [(start, end), ...]        │
  └─────────────────────────────────────────────┘

第2步: 合并相邻段 (gap ≤ 1.5s)
  ┌─────────────────────────────────────────────┐
  │ mergeAdjacentVadSegments(rawSegments, maxGap: 1.5) │
  │ 句中短暂停顿(≤1.5s)被视为同一说话人继续发言          │
  └─────────────────────────────────────────────┘

第3步: 累积至 ~30s 语音块
  ┌─────────────────────────────────────────────┐
  │ 按顺序累加合并后的 VAD 段                       │
  │ 语音累计时长 ≥ 30s 时，切出一个 chunk           │
  │ 输出: chunks [(chunkStart, chunkEnd), ...]    │
  └─────────────────────────────────────────────┘

第4步: 逐块 Paraformer 转写 (token 级时间戳)
  ┌─────────────────────────────────────────────┐
  │ 每个 chunk:                                  │
  │   - 前后各扩展 300ms 上下文 (改善ASR质量)       │
  │   - Paraformer 推理 → tokens_arr + timestamps │
  │   - SentencePiece 解码 (▁前缀, @@后缀)         │
  │   - 构建 charToTokenIdx 映射表                 │
  │   - CT-Transformer 标点恢复 → splitBySentences │
  │   - 为每个句子构建 tokenTimestamps             │
  └─────────────────────────────────────────────┘

第5步: 全局排序 + 重叠去重
  ┌─────────────────────────────────────────────┐
  │ 按 startTime 排序 → 相邻重叠句 Jaccard 去重    │
  │ (sim > 0.5 且后句更长 → 替换前句)              │
  └─────────────────────────────────────────────┘
```

### 2.3 Paraformer token 级时间戳

Paraformer 通过 CIF (Continuous Integrate and Fire) 机制为每个 token 输出精确时间戳：

```
sherpa-onnx C API 输出:
  tokens_arr[ti]  = token 文本 (UTF-8 C string)
  timestamps[ti]  = token 起始时间 (秒, float)
  durations[ti]   = token 持续时长 (秒, float)

token → 字符映射 (SentencePiece 解码):
  "▁对"     → "对"     (词边界, 前面补空格)
  "就"       → "就"     (中文直接拼接)
  "齿轮@@"  → "齿轮"   (@@ 后缀, 与前 token 合并)
  "精准"     → "精准"
  ...

  rawChars = ["对","就","像","齿","轮","精","准",...]
  charToTokenIdx = [0, 1, 1, 1, 2, 2, 3, 3, ...]
```

### 2.4 tokenTimestamps 构建 (buildTokenTimestamps)

```
输入: trimmed (含标点的句子文本), rawText (纯token文本),
      charToTokenIdx, tsPtr, timeOffset

算法:
  1. 去除 trimmed 中所有标点 → stripped (纯文本)
  2. 在 rawText 中找到 stripped 的精确位置 → rawRange
  3. 遍历 trimmed 每个字符:
     - 标点字符 (，。！？等) → 沿用最近非标点字符的时间戳
     - 非标点字符 → rawText[rawPos] → charToTokenIdx[rawPos] → tsPtr[tokenIdx]
       rawPos += 1
  4. 返回 [Double]? (长度 = trimmed.count, nil = 映射失败)

输出: tokenTimestamps[i] = text 第 i 个字符对应的音频绝对时间 (秒)
```

---

## 三、Step 2: Hybrid声纹分离

### 3.1 模型依赖

| 模型 | 路径 | 用途 |
|------|------|------|
| Pyannote 3.0 INT8 | `sherpa-onnx-models/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx` | 帧级(10ms)说话人切换检测 |
| eres2net | `sherpa-onnx-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx` | 512维声纹向量提取 |

### 3.2 处理流程

```
第1步: 能量VAD粗筛
  ┌─────────────────────────────────────────────┐
  │ energyVADSegments(samples)                   │
  │ RMS能量阈值检测 → 将音频切成若干粗粒度 chunk    │
  │ 输出: vadSegments [(start, end), ...]        │
  └─────────────────────────────────────────────┘

第2步: 逐 chunk 精细处理
  ┌─────────────────────────────────────────────┐
  │ for each vadSeg:                            │
  │   extractHybridSegments():                  │
  │     - Pyannote Neural VAD 10ms帧级分割        │
  │     - eres2net 逐段提取 512维声纹向量          │
  │     - 上下文填充: 短段自动扩展到 ≥1.6s         │
  │        (prepareSamplesWithContext)           │
  │   → 增量聚类 (IncrementalSpeakerClustering)  │
  │     addEmbedding() → 分配说话人标签           │
  │   → labeledSubSegments 累积                  │
  └─────────────────────────────────────────────┘

第3步: 周期聚类合并 (每30s)
  ┌─────────────────────────────────────────────┐
  │ mergeSimilarClusters()                      │
  │ 簇质心互比余弦距离 ≤ clusterMergeDistance(0.45)  │
  │ → 合并为同一说话人                            │
  └─────────────────────────────────────────────┘

第4步: 最终合并
  ┌─────────────────────────────────────────────┐
  │ mergeSimilarClusters() 最终调用              │
  │ buildDiarizationOutput():                   │
  │   - 按 label 分组                           │
  │   - 合并相邻段 (间隔 ≤ 0.1s)                  │
  │   - 计算各说话人平均声纹                       │
  │ 输出: DiarizationOutput {segments, embeddings}│
  └─────────────────────────────────────────────┘
```

### 3.3 关键技术点

**eres2net 最小音频时长要求**:
- `< 0.3s`: 跳过不处理
- `0.3s ~ 1.6s`: 需要上下文填充至 ≥1.6s (`prepareSamplesWithContext`)
- `≥ 1.6s`: 直接提取，声纹向量可靠

**Pyannote 帧级精度**:
- 分割粒度: 10ms/帧
- `minDurationOn = 0.3s`: 最短语音段
- `minDurationOff = 0.2s`: 最短静音间隔 (说话人切换检测灵敏度)

---

## 四、intersectAndLabel: 说话人切换点切句

### 4.1 问题背景

ASR 分句基于语义/标点 (`splitBySentences`)，不感知说话人变化。当两人在 ASR 一句内快速交替发言时，整句会被错误标注为同一人。

### 4.2 算法

```
输入: sentences ([TranscriptSegment] from ASR)
      diarSegments ([DiarizedSegment] from Step 2)

for each sentence:
  1. 找到所有时间重叠的声纹分离段 (overlapping)
  2. 将连续同说话人的段合并为 speakerGroups
  3. 判断:
     - speakerGroups.count == 1 → 整句标注为同一人
     - speakerGroups.count > 1  → 在切换点切开
```

### 4.3 多说话人切分 (核心)

```
┌──────────────────────────────────────────────────────────────┐
│ sentence: [07.0 ──────────────────────────────── 22.0]s     │
│ text: "对，就像那种齿轮精准咬合的瑞士手表，没错，或者是一张..."    │
│                                                              │
│ Pyannote 声纹段 (overlapping):                                │
│   Speaker_A: [07.0────07.5]      ← 说话人 A                  │
│   Speaker_B:       [07.5──08.0]  ← 说话人 B                  │
│   Speaker_A:             [08.0────────────22.0] ← 说话人 A   │
│                                                              │
│ speakerGroups (合并后):                                       │
│   A: [07.0──07.5]  B: [07.5──08.0]  A: [08.0──22.0]        │
│                                                              │
│ splitTextByTokenTimestamps() → 在切换点 07.5s 和 08.0s 切开  │
│                                                              │
│ 结果:                                                        │
│   [07.0─07.5] A: "对，就像那种齿轮精准咬合的瑞士手表，"       │
│   [07.5─08.0] B: "没错，"                                    │
│   [08.0─22.0] A: "或者是一张完美的建筑蓝图..."               │
└──────────────────────────────────────────────────────────────┘
```

### 4.4 子段时间戳计算

切开后，每段的 **startTime/endTime** 从 token 时间戳反推：

```
if tokenTimestamps 可用:
  - 在原文中找到子段文本的位置 → range
  - startTime = ts[range.lowerBound]  (首字符时间戳)
  - endTime   = ts[range.upperBound-1] (末字符时间戳)
else:
  - 回退到 Pyannote 边界 (group.start / group.end)
```

---

## 五、splitTextByTokenTimestamps: Token 时间戳精确切分

### 5.1 核心策略

用 Paraformer 的 **字级时间戳** + Pyannote 的 **说话人边界**，在自然停顿处精确切分。不依赖语速假设。

### 5.2 两阶段切分算法

```
阶段1: 找自然停顿 (主要策略)
  ┌─────────────────────────────────────────────────────────┐
  │ 在 Pyannote 边界 ±500ms 搜索窗口内:                       │
  │   for idx in searchWindow:                              │
  │     gap = ts[idx+1] - ts[idx]                            │
  │     记录最大 gap 的位置                                    │
  │                                                          │
  │ 若 maxGap > 50ms → 在此停顿处切开 (说话人自然切换点)       │
  │ 若 maxGap ≤ 50ms → 进入阶段2                             │
  └─────────────────────────────────────────────────────────┘

阶段2: 最近字符 (回退策略)
  ┌─────────────────────────────────────────────────────────┐
  │ 遍历所有字符，找 tokenTimestamps[i] 最接近 boundaryTime 的  │
  │ 字符位置作为切分点                                         │
  └─────────────────────────────────────────────────────────┘

标点微调:
  ┌─────────────────────────────────────────────────────────┐
  │ 优先向后找标点 (splitIdx ~ splitIdx+5)                     │
  │ 找不到则向前找 (splitIdx-3 ~ splitIdx)                     │
  │ 确保至少前进一个字符                                        │
  └─────────────────────────────────────────────────────────┘
```

### 5.3 回退机制

当 `tokenTimestamps` 为 nil 时，退化为 `splitTextByTimeRatio` (按时长比例盲猜分配文本)。

---

## 六、refineWithEmbeddingSplit: 声纹二次校验

### 6.1 问题背景

当两个说话人声纹特征相似 (如两个男声)，增量聚类 (`clusterMergeDistance`) 可能将它们合并为同一人。`intersectAndLabel` 无法在这种情况下切句。

### 6.2 算法

```
for each sentence (duration ≥ 2s):
  1. 取前半段音频 → eres2net → emb1
  2. 取后半段音频 → eres2net → emb2
  3. cosineDistance(emb1, emb2)
  4. 若 dist > embeddingSplitThreshold (默认 0.40):
     → 句中存在声纹突变，强制切为 2 段
     → 用 splitTextByTokenTimestamps 分配文本
```

---

## 七、参数配置体系

所有参数通过 `SettingsManager` 统一管理，在 `SettingsView` 中可调。

### 声纹聚类参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `clusteringThreshold` | 0.71 | 0.3~1.2 | sherpa-onnx FastClustering 余弦距离阈值，越低越细分 |
| `incrementalClusteringDistance` | 0.45 | 0.2~0.8 | 逐段增量聚类余弦距离阈值 |
| `clusterMergeDistance` | 0.45 | 0.2~0.8 | 簇质心互比合并余弦距离阈值 |
| `embeddingSplitThreshold` | 0.40 | 0.2~0.7 | refineWithEmbeddingSplit 句内拆分阈值 |
| `minDurationOn` | 0.3s | 0.1~2.0 | Pyannote 最短语音段 |
| `minDurationOff` | 0.2s | 0.1~2.0 | Pyannote 最短静音间隔 |

### 声纹匹配参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `matchingThreshold` | 0.63 | 0.3~0.9 | 余弦相似度最低匹配分 |
| `highConfidenceThreshold` | 0.655 | 0.5~0.95 | 高置信度自动绑定阈值 |
| `liveMatchingThreshold` | 0.58 | 0.3~0.8 | 实时录音匹配阈值 |

---

## 八、数据流总览

```
音频文件 (WAV)
    │
    ├──→ FunASRService.transcribeVadAccumulated()
    │       │
    │       ├─ Silero VAD 检测
    │       ├─ mergeAdjacentVadSegments (gap ≤ 1.5s)
    │       ├─ 累积至 ~30s chunks
    │       ├─ Paraformer 逐块转写
    │       ├─ CT-Transformer 标点恢复
    │       ├─ buildTokenTimestamps()  ← 为每句每个字符附加时间戳
    │       └─ 输出: [TranscriptSegment {text, startTime, endTime, tokenTimestamps}]
    │
    └──→ DiarizationService.diarizeWithEmbeddings()
            │
            ├─ 能量VAD粗筛
            ├─ Pyannote 帧级(10ms) Neural VAD 精细分割
            ├─ eres2net 逐段提取 512维声纹向量
            ├─ IncrementalSpeakerClustering 增量聚类
            ├─ mergeSimilarClusters 簇合并
            └─ 输出: DiarizationOutput {segments, embeddings}

            ↓

    intersectAndLabel(sentences, diarSegments)
            │
            ├─ 时间重叠匹配
            ├─ 同说话人段合并 → speakerGroups
            ├─ speakerGroups.count > 1 → 切句
            │   └─ splitTextByTokenTimestamps()  ← Token时间戳精确切分
            └─ 输出: [TranscriptSegment {text, startTime, endTime, speakerLabel}]

            ↓

    refineWithEmbeddingSplit(sentences, samples)
            │
            ├─ 前后半段声纹余弦距离对比
            ├─ dist > embeddingSplitThreshold → 强制切句
            └─ 输出: [TranscriptSegment {speakerLabel}]

            ↓

    SpeakerMatcher
            │
            ├─ 声纹向量 → 余弦相似度 → 联系人匹配
            └─ 持久化: SQLite + contactId
```

---

## 九、关键约束与边界条件

1. **ASR 与声纹分离解耦**: sherpa-onnx 的 `OfflineRecognizer` (ASR) 和 `OfflineDiarizer` (声纹) 完全独立，无共享参数。FunASR SDK 的 `spk_model="cam++"` 一体化方案在 sherpa-onnx C API 中不可用。

2. **eres2net 最小时长**: < 1.6s 的片段必须通过 `prepareSamplesWithContext` 自动填充上下文，否则声纹向量不可靠。

3. **Pyannote 边界误差**: 说话人切换检测可能有 ±200ms 偏差。`splitTextByTokenTimestamps` 通过搜索 token 时间戳自然停顿来纠正。

4. **VAD 合并副作用**: `mergeAdjacentVadSegments(maxGap: 1.5s)` 会将句中短暂停顿合并，导致大段文本跨越多说话人。这需要下游 `intersectAndLabel` 来补救。

5. **tokenTimestamps 可用性**: 仅 Paraformer 模型支持。Whisper 等回退模型不产生 token 级时间戳，此时切句退化为 `splitTextByTimeRatio`。

6. **标点字符的时间戳**: CT-Transformer 添加的标点 (，。！？) 无独立 token 时间戳。`buildTokenTimestamps` 为它们分配最近非标点字符的时间戳。
