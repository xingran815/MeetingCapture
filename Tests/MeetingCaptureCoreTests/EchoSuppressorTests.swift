import XCTest

@testable import MeetingCaptureCore

/// Issue 31: the neural mask was trained on int16 WAV dumps, but the app fed it float
/// estimates, so a far-silent frame looked unlike anything it learned and 20 dB came off the
/// user's voice. `LinearStageFile` now rounds both signals to 16 bits. Invented signals only.
final class EchoSuppressorTests: XCTestCase {

    private let lsb = 1.0 / 32768

    // MARK: int16 rounding

    func testInt16ExactValues_issue31Int16TrainDeployMismatch() {
        XCTAssertEqual(LinearStageFile.int16(0), 0)
        XCTAssertEqual(LinearStageFile.int16(1.0), Float(32767.0 / 32768.0), "full scale clips to the top code")
        XCTAssertEqual(LinearStageFile.int16(-1.0), -1)
        XCTAssertEqual(LinearStageFile.int16(5.0), Float(32767.0 / 32768.0))
        XCTAssertEqual(LinearStageFile.int16(-5.0), -1)
        XCTAssertEqual(LinearStageFile.int16(1e-7), 0, "far under half a step is zero")
        XCTAssertEqual(LinearStageFile.int16(-1e-7), 0)
        XCTAssertEqual(LinearStageFile.int16(3.0 / 32768), Float(3.0 / 32768), "an exact code is kept")
    }

    func testInt16RoundsHalfStepsAwayFromZero() {
        // Swift's .rounded() is schoolbook: .5 goes away from zero.
        XCTAssertEqual(LinearStageFile.int16(0.5 * lsb), Float(lsb))
        XCTAssertEqual(LinearStageFile.int16(1.5 * lsb), Float(2 * lsb))
        XCTAssertEqual(LinearStageFile.int16(-0.5 * lsb), Float(-lsb))
        XCTAssertEqual(LinearStageFile.int16(-1.5 * lsb), Float(-2 * lsb))
        XCTAssertEqual(LinearStageFile.int16(0.49 * lsb), 0)
    }

    // MARK: round trip through the file

    private func readPairs(_ stage: LinearStageFile) throws -> [Float] {
        let data = try Data(contentsOf: stage.url)
        // int16 pairs on disk, read as the values they stand for (M8 deep review: half the disk).
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
    }

    func testFileHoldsQuantizedValues_farSilentEstimateReadsBackAsZero() throws {
        let stage = try LinearStageFile(frames: 5, available: nil)
        defer { stage.remove() }
        let error = [0.1, -0.25, 0.3333333, 2.0, -3.0]
        let estimate = [1e-6, -1e-6, 2e-6, 0.0, 1.2e-5]
        try stage.append(error: error, estimate: estimate)
        XCTAssertEqual(stage.frames, 5)
        let pairs = try readPairs(stage)
        XCTAssertEqual(pairs.count, 10)
        for i in 0..<5 {
            let e = Double(pairs[2 * i])
            let d = Double(pairs[2 * i + 1])
            XCTAssertEqual((e * 32768).rounded(), e * 32768, accuracy: 1e-9, "error \(i) is on the int16 grid")
            XCTAssertEqual((d * 32768).rounded(), d * 32768, accuracy: 1e-9, "estimate \(i) is on the int16 grid")
        }
        for i in 0..<3 { XCTAssertEqual(pairs[2 * i + 1], 0, "a far-silent estimate is exactly 0") }
        XCTAssertEqual(pairs[2 * 4 + 1], 0, "1.2e-5 is under half a step (1.5e-5)")
        XCTAssertEqual(pairs[6], Float(32767.0 / 32768.0), "an error of 2.0 clips")
        XCTAssertEqual(pairs[8], -1)
        XCTAssertEqual(Double(pairs[2]), -0.25, accuracy: 1e-9)
    }

    func testAppendAccumulatesAcrossCalls() throws {
        let stage = try LinearStageFile(frames: 3, available: nil)
        defer { stage.remove() }
        try stage.append(error: [0.1, 0.2], estimate: [0, 0])
        try stage.append(error: [0.3], estimate: [0])
        XCTAssertEqual(stage.frames, 3)
        let pairs = try readPairs(stage)
        XCTAssertEqual(pairs.count, 6)
        XCTAssertEqual(Double(pairs[4]), 0.3, accuracy: 1.0 / 32768)
    }

    // MARK: the weights

    func testWeightsAreConsistent() throws {
        let text = EchoSuppressorWeights.base64.filter { !$0.isWhitespace }
        let data = try XCTUnwrap(Data(base64Encoded: text))
        XCTAssertEqual(data.count, EchoSuppressorWeights.count * 2, "half precision: two bytes per weight")
        XCTAssertEqual(EchoSuppressorWeights.bins, 513)
        XCTAssertEqual(EchoSuppressorWeights.bins, EchoSuppressor.size / 2 + 1)
        XCTAssertGreaterThan(EchoSuppressorWeights.hidden, 0)
        XCTAssertEqual(NeuralMask.inputBins, EchoSuppressorWeights.bins)
        XCTAssertEqual(NeuralMask.hidden, EchoSuppressorWeights.hidden)
    }

    func testNeuralMaskLoadsAndGivesGainsInRange() {
        var network = NeuralMask()
        let bins = EchoSuppressorWeights.bins
        let quiet = [Double](repeating: 1e-10, count: bins)
        let mask = network.mask(errorPower: quiet, estimatePower: quiet)
        XCTAssertEqual(mask.count, bins)
        XCTAssertTrue(mask.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.0001 }, "a mask is a gain between 0 and 1")
    }

    // MARK: the user's voice alone

    /// Runs the suppressor on a stage whose error is the user's voice and whose estimate is the
    /// given far-side echo estimate; returns the mean power in dB of input and output.
    private func levelChange(seconds: Double, estimate: ([Double]) -> [Double]) throws -> Double {
        let frames = Int(seconds * Double(EchoRemover.sampleRate))
        let voice = EchoLab.speech(frames: frames, seed: 7, rms: 0.05)
        let stage = try LinearStageFile(frames: frames, available: nil)
        defer { stage.remove() }
        for start in stride(from: 0, to: frames, by: 4800) {
            let end = min(start + 4800, frames)
            let chunk = Array(voice[start..<end])
            try stage.append(error: chunk, estimate: estimate(chunk))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("suppressor-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try MonoWriter(out)
        _ = try EchoSuppressor.run(stage: stage, writer: writer)
        writer.close()
        let cleaned = try EchoLab.read(out)
        let skip = EchoRemover.sampleRate / 2
        func power(_ x: [Double]) -> Double {
            let s = x[skip..<min(x.count, frames)]
            return s.reduce(0) { $0 + $1 * $1 } / Double(s.count)
        }
        return EchoLab.db(power(cleaned) / power(voice))
    }

    func testVoiceAloneKeepsItsLevel_farEndSilent_short() throws {
        let change = try levelChange(seconds: 3) { $0.map { _ in 0 } }
        XCTAssertEqual(change, 0, accuracy: 1.0, "far side silent: the user's voice must not be cut (issue 31)")
    }

    func testVoiceAloneKeepsItsLevel_estimateBelowOneStep_short() throws {
        // A float estimate of ~1e-6 is what a silent far side leaves; it must round to 0.
        let change = try levelChange(seconds: 3) { chunk in
            EchoLab.noise(chunk.count, seed: UInt64(chunk.count) &+ 3, rms: 1e-6)
        }
        XCTAssertEqual(change, 0, accuracy: 1.0, "an estimate under one LSB is silence (issue 31)")
    }
}

final class EchoSuppressorSlowTests: XCTestCase {
    func testVoiceAloneKeepsItsLevelOverALongRun() throws {
        let seconds = 30.0
        let frames = Int(seconds * Double(EchoRemover.sampleRate))
        let voice = EchoLab.speech(frames: frames, seed: 11, rms: 0.03)
        let stage = try LinearStageFile(frames: frames, available: nil)
        defer { stage.remove() }
        for start in stride(from: 0, to: frames, by: 4800) {
            let end = min(start + 4800, frames)
            try stage.append(
                error: Array(voice[start..<end]),
                estimate: EchoLab.noise(end - start, seed: UInt64(start) &+ 5, rms: 1e-6))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("suppressor-slow-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try MonoWriter(out)
        _ = try EchoSuppressor.run(stage: stage, writer: writer)
        writer.close()
        let cleaned = try EchoLab.read(out)
        let skip = EchoRemover.sampleRate
        func power(_ x: [Double]) -> Double {
            let s = x[skip..<min(x.count, frames)]
            return s.reduce(0) { $0 + $1 * $1 } / Double(s.count)
        }
        XCTAssertEqual(EchoLab.db(power(cleaned) / power(voice)), 0, accuracy: 1.0)
    }
}
