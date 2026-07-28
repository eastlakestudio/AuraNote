# AuraNote · 听纪

> **端侧离线 AI 会议纪要** — 麦克风录音、实时转写、声纹分离，全程本地运行，数据不上云。

[![Platform](https://img.shields.io/badge/平台-macOS%2014%2B%20%7C%20iOS%2017%2B-blue?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)](https://swift.org/)
[![Version](https://img.shields.io/badge/版本-1.1.4-green?style=flat-square)](https://github.com/EastlakeStudio/AuraNote)
[![License](https://img.shields.io/badge/许可-Private-red?style=flat-square)](./PRIVACY.md)

---

## 📖 产品简介

**AuraNote（听纪）** 是一款专注于**端侧离线会议纪要**的原生应用，采用 SwiftUI 开发，同时支持 macOS 和 iOS（Apple Silicon Mac 可直接运行 iPad 版）。

核心理念：**隐私优先，全程离线**。所有语音识别、声纹分析和 AI 推理均在本地完成，会议内容永远不会离开你的设备。

---

## ✨ 核心功能

### 🎙️ 实时录音与流式转写
- 麦克风实时录制会议音频，支持回放
- 基于 **Paraformer（sherpa-onnx）** 的流式语音转文字，毫秒级实时上屏
- 自适应语音增强（智能降噪、增益控制）
- CT-Transformer 自动恢复标点符号

### 📁 音频文件离线导入
- 支持导入 WAV / MP3 / M4A / AAC / FLAC / OGG / CAF 格式
- 自动从文件元数据提取真实录制时间（BWF、ID3、QuickTime 等多种格式）
- 导入后全自动启动高精度离线分析流水线

### 🧑‍🤝‍🧑 声纹分离与说话人识别
- **三级声纹分离流水线**：
  1. 能量 VAD 粗筛（O(n) 极速）
  2. Pyannote 3.0 Neural VAD 精细分割（10ms 帧级）
  3. eres2net 提取 512 维声纹向量 + 增量聚类
- 多说话人自动标注为 Speaker_1、Speaker_2…
- 已知联系人**自动匹配**（余弦相似度 ≥ 0.63），高置信度（≥ 0.655）自动绑定姓名
- 全局一键更新：确认说话人身份后，全篇转写记录同步更名

### 📚 声纹人脉库
- 本地 SQLite 持久化存储每位联系人的声纹向量（512 维）
- 越用越准：每次会议后自动积累联系人声纹特征
- 支持手动创建、编辑、管理联系人档案

### 🤝 会议管理
- 记录会议元数据：标题、时间、地点、参会人、热词分类
- **会议延续性**：同一主题的上下午场会议可无缝衔接，继续上次录音
- 本地 SQLite 持久化所有历史会议记录

### 🔥 行业热词注入
- 内置热词预设管理器（支持自定义行业词汇表）
- 录音前可选择热词分类，ASR 识别时自动注入，显著提升专业术语准确率
- 热词范围包括：会议标题、地点、参会人姓名、行业词汇

### ⚙️ 会议整理与转写审阅
- 转写完成后进入**审阅模式**，支持手动编辑文本
- 统一编辑器（`UnifiedTranscriptEditor`）支持分段编辑、说话人标签修改
- 侧边栏（`MeetingInfoSidebar`）展示会议元数据与参会人统计
- 离线分析进度条实时显示处理进度

---

## 🏗️ 技术架构

### 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | SwiftUI (macOS 14+ / iOS 17+) |
| 数据库 | SQLite（本地沙盒） |
| 实时 ASR | Paraformer Online（sherpa-onnx 流式） |
| 离线 ASR | Paraformer Offline（sherpa-onnx，token 级时间戳） |
| 声纹分割 | Pyannote 3.0 INT8（10ms 帧级） |
| 声纹提取 | eres2net（512 维声纹向量） |
| 标点恢复 | CT-Transformer |
| VAD | Silero VAD（离线双模式）+ 振幅 VAD（实时） |
| 推理引擎 | ONNX Runtime（sherpa-onnx 封装） |

### 目录结构

```
AuraNote/
├── AuraNote/              # iOS/macOS 主应用
│   ├── AuraNote/
│   │   ├── AuraNoteApp.swift          # 应用入口、模型预加载
│   │   ├── Models/                    # 数据模型（Meeting、SpeechClip、Contact 等）
│   │   ├── ViewModels/                # 业务逻辑（RecordingViewModel 等）
│   │   ├── Views/                     # UI 视图层
│   │   │   ├── MeetingListView.swift  # 会议列表首页
│   │   │   ├── RecordingView.swift    # 实时录音视图
│   │   │   ├── ReviewingView.swift    # 转写审阅视图
│   │   │   ├── MeetingInfoSidebar.swift
│   │   │   ├── PersonnelManagementView.swift  # 联系人/声纹管理
│   │   │   ├── SettingsView.swift     # 设置（模型路径、热词等）
│   │   │   └── HotwordsManagementView.swift
│   │   ├── Services/                  # 核心服务层
│   │   │   ├── FunASRService.swift    # ASR 转写服务
│   │   │   ├── DiarizationService.swift  # 声纹分离服务
│   │   │   ├── SpeakerMatcher.swift   # 声纹匹配
│   │   │   ├── SpeakerAlignmentService.swift  # 转写-声纹对齐
│   │   │   ├── IncrementalSpeakerClustering.swift
│   │   │   ├── AudioRecorder.swift    # 麦克风录音
│   │   │   ├── DatabaseManager.swift  # SQLite 数据库
│   │   │   └── SettingsManager.swift  # 用户设置
│   │   └── Resources/                 # 本地化资源
│   └── AuraNoteTests/                 # 单元测试
├── doc/                               # 产品文档
│   ├── functional_spec.md             # 完整功能规格说明
│   ├── feature.md                     # 功能需求说明
│   └── pipeline.md                    # 处理流水线详解
└── openspec/                          # 变更规格管理
```

### 核心数据模型

```
Meeting ──1:N── SpeechClip ──N:1── Contact
  │                                    │
  │  id, title, audioPath,             │  id, name, role, company
  │  duration, status,                 │  └── ContactEmbedding (512维向量)
  │  attendees, hotwordCategories      │
  └── 1:N ── AudioChunk (实时录音阶段)

Meeting.Status: recording → pendingDiarization → processingLlm → completed
```

---

## 🤖 AI 模型清单

| 模型 | 大小 | 用途 |
|------|------|------|
| Paraformer Online | ~200MB | 流式实时语音转写 |
| Paraformer Offline | ~200MB | 离线高精度转写（含 token 时间戳） |
| CT-Transformer | ~30MB | 标点符号恢复 |
| Silero VAD | 628KB | 语音活动检测（离线场景） |
| Pyannote 3.0 INT8 | 1.5MB | 帧级说话人切换检测 |
| eres2net | ~40MB | 512 维声纹向量提取 |

> 所有模型以 ONNX 格式内置于 App Bundle，通过 sherpa-onnx 调用，**无需网络，无需外部依赖**。

---

## 🚀 构建与运行

### 环境要求

- macOS 14.0+（开发环境）
- Xcode 16.0+
- Swift 5.9+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（用于从 `project.yml` 生成 `.xcodeproj`）

### 构建步骤

```bash
# 1. 克隆仓库
git clone https://github.com/EastlakeStudio/AuraNote.git
cd AuraNote/AuraNote

# 2. 生成 Xcode 项目
xcodegen generate

# 3. 用 Xcode 打开并构建
open AuraNote.xcodeproj
```

> **注意**：项目依赖 sherpa-onnx 动态库和 ONNX 模型文件（存放于 `Libraries/sherpa-onnx/`），这些文件因体积较大未纳入版本控制，请联系开发团队获取。

---

## 🔒 隐私承诺

- 🚫 **零网络传输**：所有音频、文本、声纹数据仅在本地处理
- 🏠 **沙盒存储**：所有数据存储于 App 沙盒 `Documents` 目录
- 🤫 **麦克风权限**：仅在用户主动点击录音时使用
- 📄 详见 [隐私政策](./PRIVACY.md)

---

## 📊 处理流水线概述

```
实时录音模式:
  麦克风 → 增益/降噪 → 重采样(16kHz)
        ├─→ [流式 ASR] Paraformer Online → 实时文本
        └─→ [VAD 切割] 攒批 8s → Pyannote + eres2net → 说话人标签
  ↓ 停止录音
  [离线精分析] 全量音频 → Pyannote + eres2net + 增量聚类
                ↓ 声纹 chunk
             Paraformer Offline → 高精度转写
                ↓
             SpeakerAlignmentService → 转写-声纹对齐
                ↓
             SpeakerMatcher → 已知联系人匹配 → 持久化

音频导入模式:
  音频文件 → 元数据提取 → AVAssetReader 解码
        → [同上离线精分析流水线]
```

---

## 📝 更新日志

### v1.1.4 (当前)
- 声纹分离三级流水线优化（能量 VAD → Pyannote → eres2net）
- 增量聚类算法优化，提升多说话人区分准确率
- 实时录音与离线分析双模式并行架构
- 音频导入支持多种元数据格式提取录制时间
- 会议整理视图全面重构（UnifiedTranscriptEditor）
- 热词预设管理器上线

---

## 📄 文档

| 文档 | 描述 |
|------|------|
| [功能规格说明](./doc/functional_spec.md) | 完整的功能规格与处理流水线详解 |
| [功能需求](./doc/feature.md) | 产品功能需求概述 |
| [处理流水线](./doc/pipeline.md) | 声纹分离与转写处理管线 |
| [声纹分离逻辑](./doc/speaker_diarization_logic.md) | 说话人分离算法细节 |
| [隐私政策](./PRIVACY.md) | 数据隐私声明 |

---

<p align="center">
  <sub>Built with ❤️ by <a href="https://github.com/EastlakeStudio">EastlakeStudio</a> · 数据你做主，隐私不将就</sub>
</p>
