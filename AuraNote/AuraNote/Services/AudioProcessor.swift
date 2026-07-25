import AVFoundation
import Accelerate

/// 轻量音频处理器，替代 WhisperKit 的 AudioProcessor 工具类
enum AudioProcessor {

    /// 使用 AVAudioConverter 重采样音频 buffer
    static func resampleBuffer(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        var capacity = converter.outputFormat.sampleRate * Double(buffer.frameLength) / converter.inputFormat.sampleRate
        if capacity.truncatingRemainder(dividingBy: 1) != 0 {
            capacity = max(1, capacity.rounded(.toNearestOrEven))
        }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else {
            throw RecorderError.audioResampleFailed
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if buffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                outStatus.pointee = .haveData
                return buffer
            }
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error, let conversionError = error {
            throw RecorderError.audioResampleFailedWithError(conversionError)
        }

        return convertedBuffer
    }

    /// 将 AVAudioPCMBuffer 的浮点声道数据转换为 [Float] 数组
    static func convertBufferToArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let startPointer = channelData[0]
        var result = [Float](repeating: 0, count: frameLength)
        result.withUnsafeMutableBufferPointer { bufPtr in
            vDSP_mmov(startPointer, bufPtr.baseAddress!, vDSP_Length(frameLength), 1, vDSP_Length(frameLength), 1)
        }
        return result
    }
}
