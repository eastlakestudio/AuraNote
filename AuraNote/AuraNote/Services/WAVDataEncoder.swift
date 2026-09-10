import Foundation

/// 轻量级音频 WAV 编码工具
/// 将 Float32 PCM 采样点直接编码为标准的 16kHz 16-bit 单声道 WAV 容器数据与 Base64
enum WAVDataEncoder {

    /// 将 Float32 音频采样数组编码为 16-bit 线性 PCM 单声道 WAV 二进制数据
    /// - Parameters:
    ///   - samples: 浮点采样点（通常范围 [-1.0, 1.0]）
    ///   - sampleRate: 采样率（默认 16000Hz）
    /// - Returns: 标准 RIFF WAV 格式的二进制数据
    static func encodeToWAVData(samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = UInt16(numChannels * (bitsPerSample / 8))
        let subchunk2Size = UInt32(samples.count * 2)
        let chunkSize = 36 + subchunk2Size

        var data = Data(capacity: 44 + Int(subchunk2Size))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSizeLE = chunkSize.littleEndian
        withUnsafeBytes(of: &chunkSizeLE) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " subchunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1Size = UInt32(16).littleEndian
        withUnsafeBytes(of: &subchunk1Size) { data.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian // PCM
        withUnsafeBytes(of: &audioFormat) { data.append(contentsOf: $0) }
        var channelsLE = numChannels.littleEndian
        withUnsafeBytes(of: &channelsLE) { data.append(contentsOf: $0) }
        var sampleRateLE = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sampleRateLE) { data.append(contentsOf: $0) }
        var byteRateLE = byteRate.littleEndian
        withUnsafeBytes(of: &byteRateLE) { data.append(contentsOf: $0) }
        var blockAlignLE = blockAlign.littleEndian
        withUnsafeBytes(of: &blockAlignLE) { data.append(contentsOf: $0) }
        var bitsPerSampleLE = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bitsPerSampleLE) { data.append(contentsOf: $0) }

        // "data" subchunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var subchunk2SizeLE = subchunk2Size.littleEndian
        withUnsafeBytes(of: &subchunk2SizeLE) { data.append(contentsOf: $0) }

        // 音频采样数据 (Float32 -> Int16)
        for s in samples {
            // 限幅 [-1.0, 1.0]
            let clamped = max(-1.0, min(1.0, s))
            let int16Val = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            var le = int16Val.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        return data
    }

    /// 将 Float32 音频采样数组转换为 Base64 编码的 WAV 字符串
    static func encodeToBase64WAV(samples: [Float], sampleRate: Int = 16000) -> String {
        let wavData = encodeToWAVData(samples: samples, sampleRate: sampleRate)
        return wavData.base64EncodedString()
    }

    /// 生成测试用的 1 秒标准静音 WAV 数据（用于快速连通性验证）
    static func createTestSilentWAVData(durationSeconds: Double = 1.0, sampleRate: Int = 16000) -> Data {
        let count = Int(durationSeconds * Double(sampleRate))
        let silentSamples = [Float](repeating: 0.0, count: count)
        return encodeToWAVData(samples: silentSamples, sampleRate: sampleRate)
    }

    /// 生成测试用的 1 秒标准静音 WAV Base64 字符串
    static func createTestSilentBase64WAV(durationSeconds: Double = 1.0, sampleRate: Int = 16000) -> String {
        return createTestSilentWAVData(durationSeconds: durationSeconds, sampleRate: sampleRate).base64EncodedString()
    }
}
