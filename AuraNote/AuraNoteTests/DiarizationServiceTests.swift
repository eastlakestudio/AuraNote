import XCTest
@testable import AuraNote

final class DiarizationServiceTests: XCTestCase {

    func testPrepareSamplesWithContextLongSegment() {
        // 构造 10 秒音频采样
        let sampleRate = 16000
        let totalSamples = 10 * sampleRate
        let samples = (0..<totalSamples).map { Float($0) }

        // 2秒~4秒区间（时长 2.0s，大于 1.6s 目标）
        let result = DiarizationService.prepareSamplesWithContext(
            allSamples: samples,
            startSec: 2.0,
            endSec: 4.0,
            sampleRate: sampleRate,
            targetDuration: 1.6
        )

        XCTAssertEqual(result.count, 2 * sampleRate)
        XCTAssertEqual(result.first, Float(2 * sampleRate))
    }

    func testPrepareSamplesWithContextMiddleShortSegment() {
        let sampleRate = 16000
        let totalSamples = 10 * sampleRate
        let samples = (0..<totalSamples).map { Float($0) }

        // 5.0秒~5.5秒区间（0.5s 短句，需补至 1.6s 即 25600 采样点）
        let result = DiarizationService.prepareSamplesWithContext(
            allSamples: samples,
            startSec: 5.0,
            endSec: 5.5,
            sampleRate: sampleRate,
            targetDuration: 1.6
        )

        let targetCount = Int(1.6 * Double(sampleRate))
        XCTAssertEqual(result.count, targetCount)
    }

    func testPrepareSamplesWithContextBoundaryStart() {
        let sampleRate = 16000
        let totalSamples = 10 * sampleRate
        let samples = (0..<totalSamples).map { Float($0) }

        // 0.0秒~0.5秒区间（处于音频最开头）
        let result = DiarizationService.prepareSamplesWithContext(
            allSamples: samples,
            startSec: 0.0,
            endSec: 0.5,
            sampleRate: sampleRate,
            targetDuration: 1.6
        )

        let targetCount = Int(1.6 * Double(sampleRate))
        XCTAssertEqual(result.count, targetCount)
        XCTAssertEqual(result.first, 0.0)
    }

    func testPrepareSamplesWithContextShortAudioPadding() {
        let sampleRate = 16000
        // 音频总时长仅 0.5 秒（8000 个采样点）
        let totalSamples = Int(0.5 * Double(sampleRate))
        let samples = (0..<totalSamples).map { Float($0) }

        let result = DiarizationService.prepareSamplesWithContext(
            allSamples: samples,
            startSec: 0.0,
            endSec: 0.5,
            sampleRate: sampleRate,
            targetDuration: 1.6
        )

        let targetCount = Int(1.6 * Double(sampleRate))
        XCTAssertEqual(result.count, targetCount)
    }
}
