# AuraNote 功能规格说明

> 版本: 2026-07-25 | 引擎: Paraformer (sherpa-onnx) + Pyannote 3.0 + eres2net | macOS 原生 SwiftUI 应用

---

## 一、产品概述

AuraNote（听纪）是一款专注于**端侧离线会议纪要**的 macOS 原生应用。核心价值在于利用本地 AI 能力，在断网环境中实现：
- 麦克风实时录音 + 流式语音转写 + 声纹分离
- 音频文件导入 + 高精度离线转写 + 声纹分离
- 声纹人脉库积累：自动识别已知联系人，越用越准

### 技术栈

| 层级 | 技术 |
|------|------|
| UI | SwiftUI (macOS) |
| 数据库 | SQLite (本地沙盒) |
| 在线 ASR | Paraformer 流式 (sherpa-onnx) |
| 离线 ASR | Paraformer 离线 (sherpa-onnx, token 级时间戳) |
| 声纹分割 | Pyannote 3.0 INT8 (10ms 帧级) |
| 声纹提取 | eres2net (512 维声纹向量) |
| 标点恢复 | CT-Transformer |
| VAD | Silero VAD (实时: 振幅 VAD; 离线: Silero + 振幅双模式) |

### 核心数据模型

```
Meeting ──1:N── SpeechClip ──N:1── Contact
  │                                      │
  │  (id, title, audioPath, duration,    │  (id, name, embedding)
  │   status, attendees, ...)            │
  │                                      │
  └── 1:N ── AudioChunk (仅实时录音阶段)
```

---

## 二、实时录音处理流程

实时录音从用户点击"开始录音"到退出会议整理界面，分为 **6 大阶段**。

### 阶段 0: 启动与模型预加载

**触发**: App 启动 (`AuraNoteApp.swift`)

```
┌─────────────────────────────────────────────────┐
│ 1. 清空上次运行日志 (AppLog.clearLogFile)         │
│ 2. 单进程锁检测 (同 Bundle ID 只保留一个实例)       │
│ 3. 异步预加载 FunASR 离线模型 (Paraformer)         │
│ 4. 异步预加载 CT-Transformer 标点模型              │
│ 5. VAD 模型不预加载 (仅 628KB, 按需加载)           │
└─────────────────────────────────────────────────┘
```

### 阶段 1: 新建会议并启动录音

**触发**: 用户点击"开始录音" → 填写会议表单 → 确认

**入口**: `RecordingViewModel.startRecording()`

```
┌──────────────────────────────────────────────────────────────┐
│ Step 1.1: 权限检查                                           │
│   - 请求麦克风权限                                           │
│                                                              │
│ Step 1.2: 创建会议记录 (SQLite)                               │
│   - 生成 UUID 会议 ID                                       │
│   - 标题/地点/参会人/语言/热词分类                            │
│   - 支持延续上一次会议 (parentMeetingId)                      │
│   - status: .recording                                       │
│                                                              │
│ Step 1.3: 启动音频引擎 (AudioRecorder)                        │
│   - AVAudioEngine 输入节点采样 (原始采样率)                   │
│   - 自适应语音增强 (silenceThreshold 以下不放大)              │
│   - 重采样至 16kHz 单声道                                    │
│   - 实时写入 WAV 文件 (audio_{meetingId}.wav)                │
│                                                              │
│ Step 1.4: 初始化 FunASR 流式 Paraformer                      │
│   - 创建 OnlineRecognizer + OnlineStream                     │
│   - 传入上下文热词 (标题/地点/参会人/行业热词)                 │
│   - 启动 0.2s 间隔的解码轮询定时器                            │
│                                                              │
│ Step 1.5: 启动 1s 间隔的 UI 刷新定时器                        │
│   - 更新录制时长                                              │
│   - 同步 audioChunks 列表                                    │
│   - 更新 isListening 指示器                                  │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 2: 实时音频流水线 (录音进行中)

**核心循环**: `AudioRecorder` 的 `installTap` 回调 (每 4096 样本触发一次)

```
┌─────────────────────────────────────────────────────────────────┐
│                   实时音频流水线 (每帧 4096 samples)              │
│                                                                 │
│  麦克风输入 (原始采样率)                                         │
│      │                                                          │
│      ├── 1) 计算原始振幅 (用于 VAD 静音检测，不受增益干扰)       │
│      │                                                          │
│      ├── 2) 自适应语音增强                                      │
│      │      - 峰值 > noiseGate → 增益到 targetPeak              │
│      │      - 峰值 ≤ noiseGate → 不做放大 (避免抬升底噪)        │
│      │                                                          │
│      ├── 3) 重采样到 16kHz                                      │
│      │                                                          │
│      ├── 4) 写入 WAV 文件                                       │
│      │                                                          │
│      ├── 5) 喂入 FunASR 流式 Paraformer                        │
│      │      - acceptWaveform(samples)                           │
│      │      - 0.2s 定时器轮询 decodeStreamIncremental()         │
│      │      - 增量文本累积到 funasrAccumulatedText              │
│      │                                                          │
│      └── 6) VAD 切割 (appendAudioAndSegment)                    │
│             - 振幅 > silenceThreshold → 标记语音活动            │
│             - 启动 pauseWindow 静默计时器                       │
│             - 超 maxChunkDuration 强制切分                      │
│             - 计时器触发 / 超时 → cutCurrentChunk()             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.1 VAD 切割逻辑 (`cutCurrentChunk`)

```
┌──────────────────────────────────────────────────────────────┐
│ 1. 裁剪尾部静音 (从末尾向前搜索，去掉 < noiseGate 的采样)      │
│                                                              │
│ 2. 噪声过滤                                                   │
│    - 片段时长 < 0.3s → 丢弃 (噪声碎片)                        │
│    - 平均能量 < noiseGate × 0.5 → 丢弃 (纯噪声)               │
│                                                              │
│ 3. 创建 AudioChunk                                            │
│    - 记录 startTime / endTime (相对录音开始)                   │
│    - 绑定 FunASR 流式累积文本                                  │
│    - 异步标点恢复 (CT-Transformer)                             │
│    - 加入 audioChunks 列表                                    │
│                                                              │
│ 4. 重置状态                                                   │
│    - funasrAccumulatedText = ""                               │
│    - currentChunkBuffer = []                                  │
│    - isListening = false                                      │
└──────────────────────────────────────────────────────────────┘
```

#### 2.2 实时声纹批量处理

```
┌──────────────────────────────────────────────────────────────┐
│ 攒批机制 (enqueueChunkForVoiceprintBatch)                      │
│                                                              │
│ 触发条件: 攒满 8 秒连续语音 或 不少于 4 个句段                  │
│                                                              │
│ 批量处理流程 (processVoiceprintBatch):                         │
│                                                              │
│   1. 合并批次内所有音频采样                                     │
│                                                              │
│   2. Hybrid 声纹分离 (extractHybridSegments)                  │
│      - Pyannote Neural VAD (threshold=0.1, 极细切割)          │
│      - eres2net 逐段提取 512 维声纹向量                        │
│      - 上下文填充至 ≥1.6s (prepareSamplesWithContext)          │
│                                                              │
│   3. 子片段标注                                                │
│      - 已知联系人: 余弦相似度 ≥ liveMatchingThreshold → 匹配   │
│      - 未知说话人: IncrementalSpeakerClustering 增量聚类       │
│                                                              │
│   4. 同说话人重叠片段合并 (mergeConsecutiveSameSpeakerChunks)  │
│      - 间隔 ≤ 0.1s 的同人片段合并                              │
│                                                              │
│   5. 时间重叠分配 (Overlap Matching)                           │
│      - 将声纹标签映射回各个 AudioChunk                         │
│      - 重叠时长最长者 = 主导说话人                              │
│                                                              │
│   6. UI 更新                                                   │
│      - 更新 audioChunks[i].speakerLabel                       │
│      - 合并相邻同说话人片段 (间隔 ≤ 3.0s)                      │
│      - 触发 onVoiceprintLabelsUpdated 回调                    │
│      - 已知联系人自动添加为参会人                               │
│      - 新匿名说话人自动添加为参会人                             │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 3: 停止录音

**触发**: 用户点击"停止录音"

**入口**: `RecordingViewModel.stopRecording()`

```
┌──────────────────────────────────────────────────────────────┐
│ Step 3.1: 停止音频引擎                                        │
│   - 在后台线程调用 stopRecording (避免主线程死锁)              │
│   - 停止 FunASR 流式解码定时器                                 │
│   - 刷新 FunASR 剩余帧 (inputFinished + decode 5 轮)          │
│   - 刷出剩余未满 8 秒的声纹批次                                │
│   - 最终增量聚类合并 (mergeSimilarClusters)                    │
│                                                              │
│ Step 3.2:AudioChunk → TranscriptSegment 转换                  │
│   - 保留实时转写文本和声纹标签                                 │
│   - 仍在识别中的片段保留空文本 (待离线回填)                    │
│                                                              │
│ Step 3.3: 状态切换                                            │
│   - meeting.status → pendingDiarization                      │
│   - meetingStatus → .reviewing                               │
│   - 延迟 0.15s 切换 (确保文件句柄释放)                         │
│                                                              │
│ Step 3.4: 启动离线高精度分析 (runOfflineTranscription)         │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 4: 离线高精度分析 (录音停止后自动触发)

**入口**: `RecordingViewModel.runOfflineTranscription()`

这是录音停止后最重要的处理阶段，采用 **声纹分离 + 转写交错并行** 架构。

```
┌──────────────────────────────────────────────────────────────────┐
│                    离线分析流水线总览                               │
│                                                                  │
│  ┌─────────────────────┐     ┌─────────────────────────────┐     │
│  │  声纹分离子任务       │     │  ASR 转写子任务               │     │
│  │  (DiarizationService) │     │  (FunASRService)             │     │
│  │                       │     │                              │     │
│  │  能量VAD → Pyannote   │     │  声纹 chunk 到达 →           │     │
│  │  精细分割 → eres2net  │────→│  Paraformer 逐段转写         │     │
│  │  声纹提取 → 增量聚类   │     │  (transcribeDiarizedSegments)│     │
│  │                       │     │                              │     │
│  │  onChunkDiarized ─────┘     │                              │     │
│  │  (AsyncStream 驱动 ASR)    │                              │     │
│  └─────────────────────┘     └─────────────────────────────┘     │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  前台消费者 (每 0.3s 轮询)                                │    │
│  │  - 接收 Whisper/ASR 产出                                  │    │
│  │  - 接收声纹分离结果 → SpeakerAlignmentService.align       │    │
│  │  - 声纹匹配 (SpeakerMatcher)                              │    │
│  │  - 每 ~3s 保存中间结果到 SQLite                            │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

#### 4.1 前台 UI 准备

```
┌──────────────────────────────────────────────────────────────┐
│ 实时录音场景:                                                 │
│   - 保留实时段的文本 + 声纹标签作为初始显示                     │
│   - 在实时段之间的时间空隙填充占位段 (isPlaceholder=true)       │
│   - offlineTotalSegments = 实时段数估算                        │
│                                                              │
│ 纯离线场景 (无实时段):                                         │
│   - 不预建占位段，转写结果逐步追加                              │
│   - offlineTotalSegments = 0 (动态确定)                       │
│                                                              │
│ 进度初始化:                                                    │
│   - offlineProgressFraction = 0                               │
│   - processedDiarizationDuration = 0                          │
│   - totalAudioDuration = 音频总时长                            │
└──────────────────────────────────────────────────────────────┘
```

#### 4.2 后台声纹分离子任务 (`DiarizationService.diarizeWithEmbeddings`)

```
┌──────────────────────────────────────────────────────────────┐
│ Step 4.2.1: 能量 VAD 粗筛 (energyVADSegments)                 │
│   - 振幅扫描，threshold=0.002                                 │
│   - pauseWindow 静音超时切段                                  │
│   - maxChunkDuration=8s 强制切分                              │
│   - 时间复杂度 O(n)，极快                                      │
│                                                              │
│ Step 4.2.2: 逐 chunk 精细处理 (循环)                           │
│                                                              │
│   for each energy VAD chunk:                                 │
│     ┌────────────────────────────────────────────────────┐   │
│     │ a) Pyannote Neural VAD (threshold=0.1 极严格)       │   │
│     │    10ms 帧级分割，不合并同源片段                      │   │
│     │    支持 OSD 重叠语音检测                              │   │
│     │                                                     │   │
│     │ b) eres2net 逐段提取 512 维声纹                      │   │
│     │    - 跳过 < 0.3s 的片段                              │   │
│     │    - 0.3s~1.6s: prepareSamplesWithContext 填充       │   │
│     │    - ≥1.6s: 直接提取 (声纹可靠)                      │   │
│     │                                                     │   │
│     │ c) IncrementalSpeakerClustering 增量聚类              │   │
│     │    余弦距离 ≤ incrementalClusteringDistance (0.45)    │   │
│     │    → 归入已有说话人，否则创建新说话人                   │   │
│     │                                                     │   │
│     │ d) 同人相邻段合并 (间隔 ≤ 0.5s, 总长 ≤ 30s)           │   │
│     │                                                     │   │
│     │ e) onChunkDiarized 回调 → AsyncStream → ASR 转写     │   │
│     └────────────────────────────────────────────────────┘   │
│                                                              │
│ Step 4.2.3: 周期聚类合并 (每 30s)                             │
│   - mergeSimilarClusters()                                   │
│   - 簇质心互比余弦距离 ≤ clusterMergeDistance (0.45) → 合并   │
│                                                              │
│ Step 4.2.4: 增量声纹匹配 (onIncrementalResult)                │
│   - 每 3 秒触发一次 (加速首屏匹配)                             │
│   - 拉取已知联系人 → SpeakerMatcher.match                     │
│   - 高置信度 (≥ highConfidenceThreshold=0.655) → 自动绑定      │
│                                                              │
│ Step 4.2.5: 最终合并                                         │
│   - mergeSimilarClusters() 最终调用                          │
│   - buildDiarizationOutput → 按 label 分组                    │
│   - 合并相邻段 (间隔 ≤ 0.1s)                                  │
│   - 计算各说话人平均声纹                                      │
│   - 输出: DiarizationOutput { segments, embeddings }         │
└──────────────────────────────────────────────────────────────┘
```

#### 4.3 后台 ASR 转写子任务 (降级路径)

当声纹分离失败或结果为空时，降级为 `transcribeVadAccumulated`:

```
┌──────────────────────────────────────────────────────────────┐
│ 第1步: Silero VAD 逐窗检测                                    │
│   512样本窗口 → Silero VAD 推理 → rawSegments                 │
│                                                              │
│ 第2步: 合并相邻段 (gap ≤ 0.5s, maxDuration ≤ 15s)             │
│                                                              │
│ 第3步: 逐块 Paraformer 转写                                   │
│   前后各扩展 300ms 上下文 → 标点恢复 → 输出句子                │
│   时间戳直接从 VAD 段边界赋值                                  │
└──────────────────────────────────────────────────────────────┘
```

#### 4.4 前台消费者循环

```
┌──────────────────────────────────────────────────────────────┐
│ 每 0.3 秒轮询一次 (consumerPollInterval):                      │
│                                                              │
│ 1. 读取 ASR 产出的新段 (pendingChunks)                        │
│    - 去重 (realSeenIds)                                      │
│    - 过滤空文本                                               │
│                                                              │
│ 2. 检查声纹分离结果 (sharedState.getDiarSegments)              │
│    若有新结果 → align + match + 更新 UI                       │
│                                                              │
│ 3. SpeakerAlignmentService.align                              │
│    - 核心区重叠 (权重 2.0) + 中点命中 + 全区重叠               │
│    - 最近邻兜底 (fallbackNearestNeighbor)                     │
│                                                              │
│ 4. 声纹匹配 (SpeakerMatcher)                                  │
│    - 余弦相似度 ≥ matchingThreshold (0.63) → 匹配             │
│    - 贪心 1:1 去重分配                                       │
│    - ≥ highConfidenceThreshold (0.655) → 自动绑定 contactId  │
│                                                              │
│ 5. 每 10 次循环 (~3s) → 保存中间结果到 SQLite                  │
│                                                              │
│ 6. 更新 progress:                                             │
│    - 进度 = processedDiarizationDuration / totalAudioDuration │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 5: 离线分析完成

```
┌──────────────────────────────────────────────────────────────┐
│ Step 5.1: 最终句段合并                                        │
│   - 收集所有转写句段 (collectedSegments)                       │
│   - 按 id 去重 → 按 startTime 排序                            │
│                                                              │
│ Step 5.2: 恢复用户手动修改                                     │
│   - 基于时间重叠度匹配原始段                                   │
│   - 非 Speaker_ 前缀的标签优先保留                             │
│   - 全局待重命名列表回填                                       │
│                                                              │
│ Step 5.3: 最终声纹匹配                                         │
│   - 保存声纹向量到 SQLite (saveMeetingEmbeddings)             │
│   - SpeakerMatcher.match 全量匹配                             │
│   - 高置信度联系人 → 自动绑定 contactId                        │
│   - 未匹配 → 创建内存临时 Contact (Speaker_X)                  │
│   - 清理无发言记录的 pending 条目                              │
│                                                              │
│ Step 5.4: 持久化                                               │
│   - 事务写入 speech_clips 表                                   │
│   - meeting.status → .completed                               │
│                                                              │
│ Step 5.5: 完成提示                                             │
│   - analysisCompletionMessage: "已知发言人 N 位: 张三(52句)，李四(31句)" │
│   - "未知发言人 M 位，总计发言 K 句"                           │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 6: 退出会议整理

**入口**: `RecordingViewModel.finishReview()`

```
┌──────────────────────────────────────────────────────────────┐
│ Step 6.1: 保存最终结果                                        │
│   - saveSegmentsToDatabase (事务)                             │
│   - 保存实际音频时长到 Meeting                                 │
│                                                              │
│ Step 6.2: 新发言人确认                                         │
│   - 检查 pendingNewContacts 的发言记录数                       │
│   - 发言记录 = 0 → 自动清理 (不写入数据库)                     │
│   - 发言记录 > 0 → 弹窗让用户勾选保存                          │
│                                                              │
│ Step 6.3: 持久化发言人重命名                                   │
│   - pendingSpeakerRenames → 写回 speech_clips                 │
│   - 更新 meeting.attendees                                    │
│                                                              │
│ Step 6.4: 清理资源 (finalizeExit)                              │
│   - 取消 transcriptionTask                                    │
│   - 释放 ONNX 会话 (~500MB-1GB)                               │
│   - FunASRService.reset() + DiarizationService.reset()       │
│   - 清空所有内存状态，返回首页                                  │
└──────────────────────────────────────────────────────────────┘
```

---

## 三、音频文件导入处理流程

音频文件导入从用户选择文件到完成分析，分为 **5 大阶段**。

### 阶段 1: 导入与预处理

**触发**: 用户在首页点击导入 → 选择音频文件 → 填写会议信息

**入口**: `RecordingViewModel.importAudioFile()`

```
┌──────────────────────────────────────────────────────────────┐
│ Step 1.1: 格式校验                                            │
│   支持: wav, mp3, m4a, aac, flac, ogg, caf                    │
│                                                              │
│ Step 1.2: 文件拷贝                                            │
│   - 源文件 → 沙盒 Documents/audio_{meetingId}.{ext}           │
│                                                              │
│ Step 1.3: 音频元数据提取                                       │
│   - 录制日期提取 (优先级):                                     │
│     1) WAV BWF bext chunk (OriginationDate/Time)             │
│     2) AVAsset commonMetadata.creationDate                    │
│     3) QuickTime/ID3/Vorbis Comment (多种键名匹配)             │
│     4) 文件系统创建日期 (兜底)                                 │
│   - 探针播放器获取音频时长 (AVAudioPlayer.duration)             │
│                                                              │
│ Step 1.4: 创建 Meeting 记录                                    │
│   - 标题默认: "{文件名} {日期}"                                │
│   - 录制时间: 元数据提取的真实录制时间                          │
│   - status: .pendingDiarization                               │
│                                                              │
│ Step 1.5: 进入回顾模式                                         │
│   - meetingStatus = .reviewing                                │
│   - 启动 runOfflineTranscription                              │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 2: 离线分析启动

**入口**: `RecordingViewModel.runOfflineTranscription(for:audioURL:)`

```
┌──────────────────────────────────────────────────────────────┐
│ Step 2.1: 状态设置                                            │
│   - meeting.status → .processingLlm                          │
│   - isTranscribingOffline = true                              │
│                                                              │
│ Step 2.2: 导入音频场景的 UI 初始化                             │
│   - offlineTotalSegments = 0 (动态增长)                       │
│   - transcriptSegments = [] (不预建占位段)                    │
│   - 转写产出逐步追加显示                                       │
│                                                              │
│ Step 2.3: 模型初始化 (后台)                                    │
│   - FunASR 离线 Paraformer 模型                               │
│   - Silero VAD 模型                                           │
│   - CT-Transformer 标点模型                                    │
│                                                              │
│ Step 2.4: 组装热词                                            │
│   - 行业热词 (HotwordPresetsManager)                          │
│   - 会议参会人名称                                             │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 3: 声纹分离 + ASR 转写交错并行

**与实时录音的离线分析阶段 4 共享同一管线**，差异点在于：

| 环节 | 实时录音场景 | 导入音频场景 |
|------|-------------|-------------|
| UI 初始显示 | 保留实时段 + 占位段 | 空列表，逐步追加 |
| 总段数估算 | 实时段数推算 | 0 (动态增长) |
| 声纹分离结果 | 通过 sharedState 异步传递 | 同上 |
| 降级路径 | transcribeDiarizedSegments → transcribeVadAccumulated | 同上 |

```
┌──────────────────────────────────────────────────────────────┐
│ 后台生产者:                                                    │
│                                                              │
│   loadAudioSamples(audioURL)  (使用 AVAssetReader 解码)       │
│        │                                                     │
│        ├──→ DiarizationService.diarizeWithEmbeddings          │
│        │       ├─ 能量 VAD 粗筛                               │
│        │       ├─ Pyannote Neural VAD 精细分割                 │
│        │       ├─ eres2net 声纹提取                           │
│        │       ├─ IncrementalSpeakerClustering                │
│        │       ├─ onChunkDiarized → AsyncStream → ASR         │
│        │       └─ onIncrementalResult → 声纹匹配               │
│        │                                                     │
│        └──→ FunASRService.transcribeDiarizedSegments          │
│               ├─ 逐段 Paraformer 转写                         │
│               ├─ CT-Transformer 标点恢复                      │
│               └─ onSegment → pendingChunks                   │
│                                                              │
│ 前台消费者 (每 0.3s):                                          │
│   - 读取 pendingChunks → 追加到 transcriptSegments             │
│   - 读取 sharedState.diarSegments → align + match             │
│   - 每 ~3s 保存中间结果                                       │
│                                                              │
│ 降级 (声纹分离失败时):                                         │
│   → FunASRService.transcribeVadAccumulated                    │
│       ├─ Silero VAD 逐窗检测                                  │
│       ├─ 合并相邻段 (gap ≤ 0.5s, maxDuration ≤ 15s)           │
│       ├─ 逐段 Paraformer 转写                                 │
│       └─ 输出: [TranscriptSegment] (speakerLabel = "?")      │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 4: 完成与声纹匹配

```
┌──────────────────────────────────────────────────────────────┐
│ Step 4.1: 句段去重与排序                                       │
│   - 按 id 去重 (保留最新版本)                                  │
│   - 过滤空文本                                                 │
│   - 按 startTime 排序                                         │
│                                                              │
│ Step 4.2: 恢复用户手动修改                                     │
│   - 非 Speaker_ 前缀的标签优先恢复                             │
│   - 全局 pending 重命名列表回填                                │
│                                                              │
│ Step 4.3: 最终声纹匹配 (SpeakerMatcher)                        │
│   - 保存声纹向量到 SQLite                                      │
│   - 拉取已知联系人全量底库                                     │
│   - 余弦相似度 ≥ matchingThreshold (0.63) → 候选匹配           │
│   - 贪心 1:1 去重 + ≥ highConfidenceThreshold (0.655) → 自动绑定│
│                                                              │
│ Step 4.4: 未匹配发言人处理                                     │
│   - Speaker_ 前缀 → 创建内存临时 Contact (pendingNewContacts)  │
│   - 分配临时 contactId → 等待退出时用户确认保存                 │
│                                                              │
│ Step 4.5: 持久化                                               │
│   - 事务写入 speech_clips                                     │
│   - meeting.status → .completed                               │
│   - analysisCompletionMessage → 发言人统计                     │
└──────────────────────────────────────────────────────────────┘
```

### 阶段 5: 退出 (与实时录音阶段 6 相同)

---

## 四、关键技术细节

### 4.1 声纹分离核心算法

#### 三级流水线

```
Stage 1: 能量 VAD 粗筛
  O(n) 振幅扫描 → 剔除静音 → max 8s 强制切分 (防 OOM)

Stage 2: Pyannote Neural VAD 精细切割
  10ms 帧级分割 → threshold=0.1 极度不合并 → 支持 OSD 重叠检测

Stage 3: eres2net 声纹提取 + 增量聚类
  512 维向量 → 余弦距离 → IncrementalSpeakerClustering
  → 同人相邻段合并 (间隔 ≤ 0.1s)
```

#### 声纹聚类参数

| 参数 | 默认值 | 语义 |
|------|--------|------|
| `clusteringThreshold` | 0.71 | sherpa-onnx FastClustering 余弦距离阈值 |
| `incrementalClusteringDistance` | 0.45 | 增量聚类余弦距离阈值 |
| `clusterMergeDistance` | 0.45 | 簇质心合并余弦距离阈值 |
| `embeddingSplitThreshold` | 0.40 | 句内前后半段声纹拆分阈值 |

> 注: 上述阈值使用**余弦距离** (0~2), distance = 1 - cos_sim。值越小 = 越相似。

#### 声纹匹配参数

| 参数 | 默认值 | 语义 |
|------|--------|------|
| `matchingThreshold` | 0.63 | 余弦相似度最低匹配分 (≥此值视为同一人) |
| `highConfidenceThreshold` | 0.655 | 高置信度自动绑定阈值 |
| `liveMatchingThreshold` | 0.58 | 实时录音匹配阈值 (更宽松) |

> 注: 匹配阈值使用**余弦相似度** (-1~1), 值越大 = 越相似。

### 4.2 转写-声纹对齐算法

`SpeakerAlignmentService.align` 使用三维评分模型:

```
score = coreOverlap × 2.0          // 核心区间重叠 (权重最高)
      + hitsMidpoint × 0.5 × dur   // 中点命中
      + fullOverlap × 0.5          // 全区重叠

兜底: fallbackNearestNeighbor (中心时间最近邻)
```

### 4.3 eres2net 最小时长约束

| 片段时长 | 处理方式 |
|---------|---------|
| < 0.3s | 跳过 (声纹不可靠) |
| 0.3s ~ 1.6s | `prepareSamplesWithContext` 自动填充上下文至 ≥ 1.6s |
| ≥ 1.6s | 直接提取声纹 (512 维向量) |

### 4.4 模型清单

| 模型 | 路径 | 大小 | 用途 |
|------|------|------|------|
| Paraformer online | `funasr/online-paraformer/` | ~200MB | 流式实时转写 |
| Paraformer offline | `funasr/offline-paraformer/model.int8.onnx` | ~200MB | 离线高精转写 + token 时间戳 |
| Silero VAD | `funasr/silero-vad/silero_vad.onnx` | 628KB | 语音活动检测 |
| CT-Transformer | `funasr/punct/model.onnx` | ~30MB | 标点恢复 |
| Pyannote 3.0 INT8 | `sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx` | 1.5MB | 帧级说话人切换检测 |
| eres2net | `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx` | ~40MB | 声纹向量提取 |

### 4.5 数据库表结构

```
Meeting: id, parentMeetingId, title, location, audioPath, duration, status, summary, createdAt, updatedAt, attendees, hotwordCategories

SpeechClip: id, meetingId, speakerLabel, contactId, startTime, endTime, originalText, cleanedText, audioClipPath, isKeyClip

Contact: id, name, role, company, avatarUrl, createdAt, updatedAt

ContactEmbedding: contactId, embedding (BLOB), totalDuration

MeetingEmbedding: meetingId, speakerLabel, embedding (BLOB)
```

---

## 五、状态机

```
Meeting.Status:
  recording → pendingDiarization → processingLlm → completed

MeetingStatus (UI):
  idle → recording → reviewing → idle

RecordingMode:
  liveRecording | importFile
```

---

## 六、文件路径约定

所有数据和模型存储在沙盒 `Documents` 目录下:

```
~/Documents/
├── audio_{meetingId}.wav          # 录音/导入的音频文件
├── config.json                     # 用户配置 (SettingsManager)
└── AuraNote.db                     # SQLite 数据库

Bundle Resources/
└── sherpa-onnx-models/            # 内置 ONNX 模型
    ├── funasr/
    │   ├── online-paraformer/
    │   ├── offline-paraformer/
    │   ├── silero-vad/
    │   └── punct/
    └── sherpa-onnx-pyannote-segmentation-3-0/
    └── 3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
```
