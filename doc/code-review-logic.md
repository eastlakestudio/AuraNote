<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AuraNote 逻辑评审报告</title>
<style>
:root { --bg: #fff; --card: #f6f8fa; --border: #d0d7de; --text: #1f2328; --muted: #656d76; --accent: #0969da; --red: #cf222e; --orange: #bf8700; --green: #1a7f37; --purple: #8250df; }
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Microsoft YaHei", sans-serif; background: var(--bg); color: var(--text); line-height: 1.75; max-width: 960px; margin: 0 auto; padding: 40px 24px 64px; font-size: 15px; }
h1 { font-size: 24px; font-weight: 700; margin-bottom: 4px; }
sub { color: var(--muted); font-size: 14px; }
h2 { font-size: 18px; font-weight: 600; margin: 32px 0 12px; padding-bottom: 6px; border-bottom: 2px solid var(--accent); }
h3 { font-size: 15px; font-weight: 600; margin: 16px 0 8px; }
p, li { color: var(--text); }  ul, ol { padding-left: 20px; margin: 6px 0; }  li { margin: 4px 0; }
code { background: var(--card); padding: 1px 6px; border-radius: 4px; font-size: 13px; border: 1px solid var(--border); }
pre { background: #1f2328; color: #e6edf3; border-radius: 8px; padding: 14px 16px; overflow-x: auto; font-size: 13px; line-height: 1.6; margin: 10px 0; }
table { width:100%; border-collapse:collapse; margin: 10px 0; font-size: 14px; }
th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border); vertical-align: top; }
th { background: var(--card); font-weight: 600; }
summary { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; margin: 14px 0; }
.stat { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 14px; text-align: center; }
.num { font-size: 26px; font-weight: 700; }  .num.c { color: var(--red); }  .num.w { color: var(--orange); }  .num.i { color: var(--accent); }
.label { font-size: 11px; color: var(--muted); margin-top: 4px; }
.tag { display: inline-block; padding: 1px 7px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-right: 4px; }
.tag-c { background: #cf222e20; color: var(--red); }  .tag-w { background: #bf870020; color: var(--orange); }  .tag-i { background: #0969da20; color: var(--accent); }
.find { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 14px; margin: 10px 0; }
.find-h { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
.find-t { font-weight: 600; font-size: 14px; }
.find-b { font-size: 14px; }
blockquote { border-left: 3px solid var(--accent); margin: 10px 0; padding: 8px 14px; background: var(--card); border-radius: 0 6px 6px 0; font-size: 14px; }
</style>
</head>
<body>

<h1>AuraNote · 逻辑评审报告</h1>
<sub>伪流式 ASR 管线逻辑分析 · 2026-07-28 · v1.1.4</sub>

<summary>
  <div class="stat"><div class="num c">2</div><div class="label">重要问题</div></div>
  <div class="stat"><div class="num w">2</div><div class="label">中等风险</div></div>
  <div class="stat"><div class="num i">3</div><div class="label">观察项</div></div>
</summary>

<h2>1. 伪流式 O(n²) 性能退化 <span class="tag tag-c">重要</span></h2>

<div class="find">
  <div class="find-b">
    <p><strong>问题</strong>: <code>pseudoStreamBuffer</code> 从录音开始累积全部采样，从不截断。每次 1.5s 定时对<strong>整个累积缓冲区</strong>执行完整 Paraformer 推理。</p>
    <table>
      <tr><th>录音时长</th><th>缓冲区大小</th><th>单次推理耗时</th><th>问题</th></tr>
      <tr><td>30s</td><td>480K 采样</td><td>~200ms</td><td>正常</td></tr>
      <tr><td>1min</td><td>960K 采样</td><td>~500ms</td><td>ok</td></tr>
      <tr><td>5min</td><td>4.8M 采样</td><td>~3-5s</td><td style="color:var(--orange)">推理 > 定时器间隔</td></tr>
      <tr><td>30min</td><td>28.8M 采样</td><td>~20s+</td><td style="color:var(--red)">严重堆积 + 内存暴涨</td></tr>
    </table>
    <p><strong>文件</strong>: <code>FunASRService.swift:86-89</code> (acceptWaveform 只追加不清除), <code>FunASRService.swift:111-126</code> (runPseudoStreamInference 全文推理)</p>
    <p><strong>短期缓解</strong>: <code>isInferring</code> 防重入锁 (AudioRecorder.swift:49,205-215) 阻止新旧推理堆积，但会丢失中间结果的实时性</p>
    <p><strong>长期方案</strong>: 录音期间定期截断缓冲区（仅保留最近 30s），或引入真正的流式 Paraformer Online 模型</p>
  </div>
</div>

<h2>2. resetOnlineStream / 推理缓冲区竞态 <span class="tag tag-c">重要</span></h2>

<div class="find">
  <div class="find-h"><span class="find-t">VAD 切段时清空缓冲区与推理并发</span><span class="tag tag-c">竞态</span></div>
  <div class="find-b">
    <p><strong>场景</strong>:</p>
    <ol>
      <li><code>funasrDecodeTimer</code> (MainActor, 1.5s) 触发 → 读取 <code>pseudoStreamBuffer</code> 进行推理 (actor 异步)</li>
      <li><code>cutCurrentChunk()</code> → <code>Task { await resetOnlineStream() }</code> → 清空 buffer</li>
      <li>推理完成 → 返回文本，但 buffer 已被清空，下一次定时将返回空增量</li>
    </ol>
    <p><strong>影响</strong>: 竞态导致丢失最后一个 VAD 段的末尾转写文本。不崩溃但会漏字。</p>
    <p><strong>文件</strong>: <code>AudioRecorder.swift:423</code> (Task { resetOnlineStream }), <code>AudioRecorder.swift:204-215</code> (decode 定时器)</p>
    <p><strong>方案</strong>: <code>resetOnlineStream</code> 内增加 <code>isInferring</code> 等待，或改为同步调用</p>
  </div>
</div>

<h2>3. lastPseudoText 清空导致全量重复 <span class="tag tag-w">中等</span></h2>

<div class="find">
  <div class="find-b">
    <p><strong>问题</strong>: <code>resetOnlineStream()</code> 同时清空 <code>pseudoStreamBuffer</code> 和 <code>lastPseudoText</code> (FunASRService.swift:136-139)。VAD 切段后下一个段的首帧推理返回完整文本，但 <code>decodeStreamIncremental</code> 因为 <code>lastPseudoText.isEmpty</code> 直接返回全文：</p>
    <pre>func decodeStreamIncremental() -> String? {
    guard let fullText = runPseudoStreamInference() else { return nil }
    let trimmed = fullText.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(lastPseudoText) {
        let inc = String(trimmed.dropFirst(lastPseudoText.count))
        lastPseudoText = trimmed
        return inc.isEmpty ? nil : inc
    } else {
        // lastPseudoText 为空 → 返回全文！
        lastPseudoText = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}</pre>
    <p><strong>影响</strong>: 每个 VAD 段首帧的转写文本被 <code>funasrAccumulatedText += incremental</code> 全量追加，导致同段文本重复出现。但因为 VAD 切段后 buffer 立刻从 0 开始累积，首帧文本很短（~1.5s 音频），实际不造成明显问题。</p>
    <p><strong>方案</strong>: <code>resetOnlineStream</code> 不清空 <code>lastPseudoText</code>，改为在 <code>createOnlineStream</code>（新一轮录音开始）时才清空</p>
  </div>
</div>

<h2>4. cutCurrentChunk 与 pauseTimer 双触发 <span class="tag tag-w">中等</span></h2>

<div class="find">
  <div class="find-b">
    <p><strong>场景</strong>: <code>pauseWindow</code> 定时器刚到期触发 <code>cutCurrentChunk()</code>，同时 <code>maxChunkDuration</code> (20s) 也在同一帧到达，两者同时调用 <code>cutCurrentChunk()</code>。两次调用都在 MainActor 上顺序执行，第二次发现 buffer 已空直接 return。不会崩溃，但 <code>chunkCounter</code> 已递增，造成 ID 编号跳号。</p>
    <p><strong>影响</strong>: 仅影响 chunk ID 连续性，不影响实际功能。</p>
    <p><strong>文件</strong>: <code>AudioRecorder.swift:314-315</code> (pauseTimer), <code>AudioRecorder.swift:319-322</code> (maxChunkDuration)</p>
  </div>
</div>

<h2>5. 观察项</h2>

<div class="find">
  <div class="find-h"><span class="find-t">decodeStreamIncremental 前缀匹配不稳定</span><span class="tag tag-i">观察</span></div>
  <div class="find-b">
    <p><code>FunASRService.swift:99-102</code>: 增量计算依赖 <code>trimmed.hasPrefix(lastPseudoText)</code>。如果 Paraformer 对相同音频 buffer 的两次推理产生微小文本差异（波束搜索随机性），前缀不匹配 → 回退到全量返回 → <code>funasrAccumulatedText</code> 重复追加。</p>
    <p><strong>风险</strong>: 实际受 ONNX 确定性推理保证影响很小，但理论上存在。</p>
  </div>
</div>

<div class="find">
  <div class="find-h"><span class="find-t">funasrAccumulatedText 非原子读写</span><span class="tag tag-i">观察</span></div>
  <div class="find-b">
    <p><strong>写入</strong>: <code>AudioRecorder.swift:211</code> 在 MainActor 上下文中 <code>self.funasrAccumulatedText += incremental</code></p>
    <p><strong>读取+清零</strong>: <code>AudioRecorder.swift:402,420</code> 也在 MainActor 中</p>
    <p><strong>结论</strong>: 两者都在 <code>@MainActor</code> 上，Swift 6 编译器保证无数据竞争。但 <code>decodeStreamIncremental</code> 内部的 actor 逻辑 (FunASRService) 与 MainActor 之间通过 await 切换，存在时序不确定性：推理完成后 MainActor 上的 timer 可能已触发 reset，导致推理结果 append 到已被截断的缓冲区。</p>
  </div>
</div>

<div class="find">
  <div class="find-h"><span class="find-t">isolated actor 推理阻塞录音 Tap</span><span class="tag tag-i">观察</span></div>
  <div class="find-b">
    <p><code>FunASRService</code> 是 <code>actor</code> (FunASRService.swift:11)，所有方法调用串行化。当 <code>runPseudoStreamInference()</code> 执行耗时的 ONNX 推理时，<code>acceptWaveform()</code> 被阻塞在 actor 队列中，导致音频采样堆积。但这些采样只是追加到数组，不丢数据——只是延迟处理。</p>
    <p><strong>实际影响</strong>: actor 串行化延迟 <code>acceptWaveform</code> 但不丢采样，可接受。</p>
  </div>
</div>

<h2>6. 总结</h2>

<blockquote>
  <p><strong>短期可用</strong>: 当前伪流式管线对 &lt; 5 分钟会议可正常工作，无崩溃风险。</p>
  <p><strong>长期风险</strong>: 15 分钟以上会议伪流式推理延迟将显著升高（&gt;10s），体验下降。但 VAD 切段后 buffer 重置 (AudioRecorder.swift:423) 提供了天然缓解——只要说话人有停顿，累积量就不会无限膨胀。</p>
  <p><strong>关键优化（按优先级）</strong>:</p>
  <ol>
    <li>伪流式缓冲区加窗口截断（保留最近 30-60s）</li>
    <li><code>resetOnlineStream</code> 改为同步或等推理完成</li>
    <li>如会议场景扩展到 30min+，考虑引入真正的流式模型</li>
  </ol>
</blockquote>

</body>
</html>
