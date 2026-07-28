<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AuraNote 代码评审报告 — 流式/离线 ASR 模型统一</title>
<style>
:root {
  --bg: #ffffff;
  --card: #f6f8fa;
  --border: #d0d7de;
  --text: #1f2328;
  --muted: #656d76;
  --accent: #0969da;
  --green: #1a7f37;
  --red: #cf222e;
  --orange: #bf8700;
  --purple: #8250df;
}
* { margin:0; padding:0; box-sizing:border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Microsoft YaHei", sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.7;
  max-width: 960px;
  margin: 0 auto;
  padding: 40px 24px 64px;
  font-size: 15px;
}
h1 { font-size: 26px; font-weight: 700; margin-bottom: 4px; }
h2 { font-size: 20px; font-weight: 600; margin: 32px 0 16px; padding-bottom: 8px; border-bottom: 2px solid var(--accent); }
h3 { font-size: 16px; font-weight: 600; margin: 20px 0 10px; }
sub { color: var(--muted); font-size: 14px; font-weight: 400; }
p, li { color: var(--text); }
li { margin: 4px 0; }
ul, ol { padding-left: 20px; margin: 8px 0; }
code { background: var(--card); padding: 2px 6px; border-radius: 4px; font-size: 13px; border: 1px solid var(--border); }
pre { background: #1f2328; color: #e6edf3; border-radius: 8px; padding: 16px; overflow-x: auto; font-size: 13px; line-height: 1.6; margin: 12px 0; }
table { width:100%; border-collapse: collapse; margin: 12px 0; font-size: 14px; }
th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border); vertical-align: top; }
th { background: var(--card); font-weight: 600; }
.summary { display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 12px; margin: 16px 0; }
.stat { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; text-align: center; }
.stat-num { font-size: 28px; font-weight: 700; }
.stat-label { font-size: 12px; color: var(--muted); margin-top: 4px; }
.critical { color: var(--red); }
.warning { color: var(--orange); }
.info { color: var(--accent); }
.ok { color: var(--green); }
.tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-right: 4px; }
.tag-high { background: #cf222e20; color: var(--red); }
.tag-med { background: #bf870020; color: var(--orange); }
.tag-low { background: #8250df20; color: var(--purple); }
.tag-info { background: #0969da20; color: var(--accent); }
blockquote { border-left: 4px solid var(--accent); margin: 12px 0; padding: 10px 16px; background: var(--card); border-radius: 0 8px 8px 0; }
.finding { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin: 12px 0; }
.finding-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
.finding-title { font-weight: 600; }
.finding-body { font-size: 14px; }
</style>
</head>
<body>

<h1>AuraNote · 代码评审报告</h1>
<sub>主题：流式/离线 ASR 模型统一 · 评审日期：2026-07-28 · 版本：v1.1.4 (Build 5)</sub>

<div class="summary">
  <div class="stat">
    <div class="stat-num ok">0</div>
    <div class="stat-label">严重问题</div>
  </div>
  <div class="stat">
    <div class="stat-num warning">3</div>
    <div class="stat-label">中等建议</div>
  </div>
  <div class="stat">
    <div class="stat-num info">4</div>
    <div class="stat-label">优化建议</div>
  </div>
  <div class="stat">
    <div class="stat-num ok">✓</div>
    <div class="stat-label">架构正确</div>
  </div>
</div>

<h2>1. 核心结论</h2>

<blockquote>
  <strong>当前代码已实现单模型统一架构。</strong> 流式转写和离线转写共用同一个 <code>sherpa-onnx-paraformer-zh-2024-03-09</code> 模型，不需要额外修改。
</blockquote>

<ul>
  <li><strong>流式（实时录音）</strong>: 伪流式层（Pseudo-Streaming）每 1.5s 对累积音频缓冲区运行一次离线 Paraformer 推理，增量计算文本</li>
  <li><strong>离线（文件导入）</strong>: 直接使用离线 Paraformer 进行高精度整文件转写（VAD 分段 / 滑动窗口 / 说话人分离）</li>
  <li><strong>不存在独立的在线模型</strong>: 代码中无 <code>SherpaOnnxCreateOnlineRecognizer</code> 调用，<code>initializeOnline()</code> 仅为 <code>initializeOffline()</code> 的别名</li>
</ul>

<h2>2. 发现与建议</h2>

<h3>2.1 <span class="tag tag-med">中等</span> 存在 226MB 未使用模型文件</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">streaming-paraformer-bilingual-zh-en 模型未实际使用</span>
    <span class="tag tag-med">冗余</span>
  </div>
  <div class="finding-body">
    <p><strong>证据</strong>: </p>
    <ul>
      <li><code>funasrOnlineModelDir</code> 返回 <code>funasrOfflineModelDir</code> (<code>SettingsManager.swift:136-138</code>)</li>
      <li><code>initializeOnline()</code> 直接调用 <code>initializeOffline()</code> (<code>FunASRService.swift:71-75</code>)</li>
      <li>代码中从不加载 <code>streaming-paraformer-bilingual-zh-en</code> 目录</li>
      <li>该模型占用 App Bundle ~226MB（encoder.int8.onnx 158MB + decoder.int8.onnx 68MB）</li>
    </ul>
    <p><strong>影响</strong>: App 体积虚增 226MB（约占总体积的 27%）</p>
    <p><strong>建议</strong>: 从 <code>Libraries/sherpa-onnx/models/funasr/</code> 移除 <code>streaming-paraformer-bilingual-zh-en/</code> 目录</p>
  </div>
</div>

<h3>2.2 <span class="tag tag-med">中等</span> 存在误导性别名</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">funasrOnlineModelDir / isFunASROnlineAvailable 是冗余别名</span>
    <span class="tag tag-med">可维护性</span>
  </div>
  <div class="finding-body">
    <p><strong>受影响文件</strong>: <code>SettingsManager.swift:136-138, 166-168</code></p>
    <table>
      <tr><th>属性</th><th>行号</th><th>实际返回</th><th>问题</th></tr>
      <tr><td>funasrOnlineModelDir</td><td>136-138</td><td>funasrOfflineModelDir</td><td>命名暗示独立路径</td></tr>
      <tr><td>isFunASROnlineAvailable</td><td>166-168</td><td>isFunASROfflineAvailable</td><td>毫无意义的反射代理</td></tr>
    </table>
    <p><strong>建议</strong>: 
      <ul>
        <li>移除 <code>funasrOnlineModelDir</code> 和 <code>isFunASROnlineAvailable</code>（它们纯属别名，无独立逻辑）</li>
        <li>在调用处直接使用 <code>funasrOfflineModelDir</code> 和 <code>isFunASROfflineAvailable</code></li>
      </ul>
    </p>
  </div>
</div>

<h3>2.3 <span class="tag tag-med">中等</span> AuraNoteApp.swift 初始化参数冗余</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">updateModelPaths 的 online 参数被丢弃</span>
    <span class="tag tag-med">死代码</span>
  </div>
  <div class="finding-body">
    <p><strong>证据</strong>: <code>FunASRService.swift:58-63</code></p>
    <pre>func updateModelPaths(online: String, offline: String, punct: String, vad: String) {
    self.configuredOnlineModelDir = online   // ← 存储但未使用
    self.configuredOfflineModelDir = offline
    self.configuredPunctModelPath = punct
    self.configuredVadModelPath = vad
}</pre>
    <p><code>AuraNoteApp.swift:82-87</code> 仍传入 4 个参数，其中 <code>online</code> 参数仅在函数签名中出现，后续逻辑不使用。</p>
    <p><strong>建议</strong>: 将 <code>updateModelPaths</code> 改为仅接收 <code>offline</code>, <code>punct</code>, <code>vad</code> 三个参数</p>
  </div>
</div>

<h3>2.4 <span class="tag tag-low">优化</span> AudioRecorder.swift 注释过时</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">类注释提到不存在的 "SenseVoice 离线"</span>
    <span class="tag tag-low">文档</span>
  </div>
  <div class="finding-body">
    <p><strong>行 4</strong>: <code>/// 音频录制 + 基于 sherpa-onnx FunASR（Paraformer 流式 + SenseVoice 离线）...</code></p>
    <p>"SenseVoice" 是历史遗留名称，当前实际使用的是 Paraformer Offline。</p>
    <p><strong>建议</strong>: 改为 <code>/// 音频录制 + 基于 sherpa-onnx FunASR（伪流式 + 离线 Paraformer）...</code></p>
  </div>
</div>

<h3>2.5 <span class="tag tag-low">优化</span> 伪流式解码每 0.2s / 1.5s 两次轮询，存在冗余</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">两层定时器设计可合并</span>
    <span class="tag tag-low">性能</span>
  </div>
  <div class="finding-body">
    <p><strong>AudioRecorder.swift:</strong></p>
    <ul>
      <li><strong>第 201 行</strong>: <code>funasrDecodeTimer</code> — 每 0.2s 轮询解码</li>
      <li><strong>第 211 行</strong>: <code>SegmentQueue consumerTask</code> — 每 0.3s 轮询显示</li>
    </ul>
    <p>两个定时器都与实时显示相关，可考虑合并为一个 0.2s 的单一轮询循环。不过当前设计分离了解码与显示关注点，具有合理性。不强制修改。</p>
  </div>
</div>

<h3>2.6 <span class="tag tag-low">优化</span> FunASRService 文件过大（1370 行）</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">单体 Actor 承载过多职责</span>
    <span class="tag tag-low">架构</span>
  </div>
  <div class="finding-body">
    <p><strong>当前职责</strong>:</p>
    <ul>
      <li>伪流式缓冲区管理（~50 行）</li>
      <li>离线 Paraformer 推理（~200 行）</li>
      <li>VAD 分段转写（~200 行）</li>
      <li>标点恢复（~100 行）</li>
      <li>Silero VAD 检测（~100 行）</li>
      <li>滑动窗口转写（~200 行）</li>
      <li>说话人段转写（~200 行）</li>
    </ul>
    <p><strong>建议</strong>: 未来可拆分为 <code>PseudoStreamService</code>, <code>PunctuationService</code>, <code>VadService</code> 等独立 Actor，降低单文件复杂度。</p>
  </div>
</div>

<h3>2.7 <span class="tag tag-low">优化</span> isModelAvailable 使用 OR 但实际只有一个条件</h3>

<div class="finding">
  <div class="finding-header">
    <span class="finding-title">布尔表达式过度设计</span>
    <span class="tag tag-low">可读性</span>
  </div>
  <div class="finding-body">
    <p><strong>SettingsManager.swift:238-240</strong>:</p>
    <pre>var isModelAvailable: Bool {
    return isFunASROfflineAvailable || isFunASROnlineAvailable
}</pre>
    <p>由于 <code>isFunASROnlineAvailable</code> 等同于 <code>isFunASROfflineAvailable</code>，此 OR 始终为恒等式。</p>
    <p><strong>建议</strong>: 简化为 <code>return isFunASROfflineAvailable</code>，或统一为一个 <code>isFunASRModelAvailable</code></p>
  </div>
</div>

<h2>3. 架构图</h2>

<pre>
┌─────────────────────────────────────────────────┐
│                  AuraNote App                    │
│                                                 │
│  ┌──────────────┐    ┌───────────────────────┐  │
│  │ AudioRecorder │    │  RecordingViewModel   │  │
│  │               │    │                       │  │
│  │ 实时录音      │    │  离线音频文件处理       │  │
│  │ ↓             │    │  ↓                     │  │
│  │ 伪流式层      │    │  transcribe()          │  │
│  │ (1.5s 定时    │    │  transcribeProgressive │  │
│  │  全量推理)    │    │  transcribeVadAccum     │  │
│  └──────┬───────┘    └───────────┬─────────────┘  │
│         │                        │                │
│         └──────────┬─────────────┘                │
│                    ▼                              │
│          ┌─────────────────┐                      │
│          │  FunASRService   │                      │
│          │                 │                      │
│          │  唯一模型路径:   │                      │
│          │  sherpa-onnx-   │                      │
│          │  paraformer-    │                      │
│          │  zh-2024-03-09  │                      │
│          │                 │                      │
│          │  + 标点:         │                      │
│          │  CT-Transformer │                      │
│          │                 │                      │
│          │  + VAD:          │                      │
│          │  Silero VAD      │                      │
│          └─────────────────┘                      │
│                    │                              │
│                    ▼                              │
│          ┌─────────────────┐                      │
│          │  ONNX Runtime    │                      │
│          │  (sherpa-onnx)   │                      │
│          └─────────────────┘                      │
└─────────────────────────────────────────────────┘
</pre>

<h2>4. 修改清单</h2>

<table>
  <tr><th>优先级</th><th>文件</th><th>修改</th><th>影响</th></tr>
  <tr>
    <td><span class="tag tag-med">中</span></td>
    <td>Libraries/.../funasr/</td>
    <td>删除 streaming-paraformer-bilingual-zh-en/ 目录</td>
    <td>App 瘦身 226MB</td>
  </tr>
  <tr>
    <td><span class="tag tag-med">中</span></td>
    <td>SettingsManager.swift</td>
    <td>移除 funasrOnlineModelDir / isFunASROnlineAvailable 别名</td>
    <td>消除混淆，无功能影响</td>
  </tr>
  <tr>
    <td><span class="tag tag-med">中</span></td>
    <td>FunASRService.swift</td>
    <td>移除 updateModelPaths 的 online 参数</td>
    <td>清理死参数</td>
  </tr>
  <tr>
    <td><span class="tag tag-low">低</span></td>
    <td>AuraNoteApp.swift</td>
    <td>适配 updateModelPaths 新签名</td>
    <td>配套修改</td>
  </tr>
  <tr>
    <td><span class="tag tag-low">低</span></td>
    <td>AudioRecorder.swift</td>
    <td>修正行 4 注释</td>
    <td>文档修正</td>
  </tr>
  <tr>
    <td><span class="tag tag-low">低</span></td>
    <td>SettingsManager.swift</td>
    <td>简化 isModelAvailable 表达式</td>
    <td>可读性提升</td>
  </tr>
</table>

<h2>5. 总结</h2>

<blockquote>
  <p><strong>现状</strong>: 代码架构已正确实现单模型统一——流式/离线共用 <code>sherpa-onnx-paraformer-zh-2024-03-09</code>，无严重 bug 或架构缺陷。</p>
  <p><strong>主要收益</strong>: 完成上述清理后，App 体积可减少约 226MB（移除未使用的 streaming-paraformer 模型），代码消除 4 处误导性别名/死代码。</p>
  <p><strong>伪流式方案的局限性</strong>: 当前伪流式方案（每 1.5s 全量离线推理）对于单个 30 秒段尚可，但随录音时长增长，累积缓冲区持续膨胀会导致推理延迟上升。建议未来监控 5 分钟以上录音的延迟表现，必要时引入真正的流式 Paraformer Online 模型。</p>
</blockquote>

</body>
</html>
