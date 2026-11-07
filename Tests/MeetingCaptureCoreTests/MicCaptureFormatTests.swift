import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Finding: a real recording aborted at start with "Failed to create tap due to format mismatch,
/// 2 ch 44100 Hz Float32 deinterleaved". The tap now takes the device's own format and `handle`
/// converts each buffer from the format it arrives in. No real mic is used: buffers are synthetic.
final class MicCaptureFormatTests: XCTestCase {

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!

    private func sine(
        rate: Double, channels: AVAudioChannelCount, interleaved: Bool, frames: Int, hz: Double = 1000,
        phaseStart: Int = 0
    ) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let n = Int(channels)
        for i in 0..<frames {
            let v = Float(0.5 * sin(2 * Double.pi * hz * Double(i + phaseStart) / rate))
            if interleaved {
                let p = b.floatChannelData![0]
                p[i * n] = v
                for c in 1..<max(n, 1) where n > 1 { p[i * n + c] = 0 }
            } else {
                b.floatChannelData![0][i] = v
                for c in 1..<max(n, 1) where n > 1 { b.floatChannelData![c][i] = 0 }
            }
        }
        return b
    }

    private func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
    }

    /// Runs buffers through one converter, as the tap does, and concatenates the output.
    private func run(_ conv: MicFormatConverter, _ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var out: [Float] = []
        for b in buffers {
            guard let o = conv.convert(b) else { continue }
            XCTAssertEqual(o.format.channelCount, 1)
            XCTAssertEqual(o.format.sampleRate, 48_000)
            out.append(contentsOf: UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
        }
        return out
    }

    // MARK: needsNoConversion

    func testNeedsNoConversionTruthTable() {
        func fmt(_ t: AVAudioCommonFormat, _ r: Double, _ c: AVAudioChannelCount, _ i: Bool) -> AVAudioFormat {
            AVAudioFormat(commonFormat: t, sampleRate: r, channels: c, interleaved: i)!
        }
        XCTAssertTrue(MicFormatConverter.needsNoConversion(fmt(.pcmFormatFloat32, 48_000, 1, true), to: target))
        // Rate
        XCTAssertFalse(MicFormatConverter.needsNoConversion(fmt(.pcmFormatFloat32, 44_100, 1, true), to: target))
        // Channels
        XCTAssertFalse(MicFormatConverter.needsNoConversion(fmt(.pcmFormatFloat32, 48_000, 2, true), to: target))
        // Sample type
        XCTAssertFalse(MicFormatConverter.needsNoConversion(fmt(.pcmFormatInt16, 48_000, 1, true), to: target))
        // Mono deinterleaved is the same layout as mono interleaved to AVFoundation; the helper just
        // compares the flag, so accept either answer but it must not crash.
        _ = MicFormatConverter.needsNoConversion(fmt(.pcmFormatFloat32, 48_000, 1, false), to: target)
        // The crash format
        XCTAssertFalse(MicFormatConverter.needsNoConversion(fmt(.pcmFormatFloat32, 44_100, 2, false), to: target))
    }

    // MARK: convert (no mic needed)

    func testCrashFormat44kStereoDeinterleavedBecomesMono48kAndKeepsTheTone() {
        let conv = MicFormatConverter(target: target)
        let inFrames = 4096
        let buffers = 6
        let out = run(
            conv,
            (0..<buffers).map {
                sine(rate: 44_100, channels: 2, interleaved: false, frames: inFrames, phaseStart: $0 * inFrames)
            })
        let expected = Double(inFrames * buffers) * 48_000 / 44_100
        XCTAssertEqual(Double(out.count), expected, accuracy: expected * 0.05, "total frames after resampling")
        XCTAssertGreaterThan(rms(Array(out.dropFirst(2000))), 0.2, "the 1 kHz tone (rms ~0.35) must survive")
    }

    func testMono48kInterleavedPassesThroughUnchanged() {
        let conv = MicFormatConverter(target: target)
        let b = sine(rate: 48_000, channels: 1, interleaved: true, frames: 1024)
        let out = run(conv, [b])
        XCTAssertEqual(out, Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: 1024)))
    }

    func testFormatChangeMidStreamKeepsProducingMono48kWithoutCrashing() {
        // A Bluetooth headset switching to its call profile: 48k mono, then 44.1k stereo, then 16k mono.
        let conv = MicFormatConverter(target: target)
        XCTAssertEqual(run(conv, [sine(rate: 48_000, channels: 1, interleaved: true, frames: 4800)]).count, 4800)
        let b = run(
            conv,
            (0..<3).map {
                sine(rate: 44_100, channels: 2, interleaved: false, frames: 4096, phaseStart: $0 * 4096)
            })
        XCTAssertGreaterThan(b.count, 12_000, "44.1k stereo stage produced output")
        let c = run(
            conv,
            (0..<3).map {
                sine(rate: 16_000, channels: 1, interleaved: false, frames: 1600, phaseStart: $0 * 1600)
            })
        XCTAssertGreaterThan(c.count, 9_000, "16k mono stage (4800 in -> ~14400 out)")
        XCTAssertLessThan(c.count, 16_000)
        XCTAssertEqual(run(conv, [sine(rate: 48_000, channels: 1, interleaved: true, frames: 480)]).count, 480)
    }

    func testEmptyBufferReturnsNil() {
        let conv = MicFormatConverter(target: target)
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let empty = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 16)!
        empty.frameLength = 0
        XCTAssertNil(conv.convert(empty))
        let pass = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16)!
        pass.frameLength = 0
        XCTAssertNil(conv.convert(pass), "empty even when no conversion is needed")
    }

    // MARK: MicCapture wiring (needs a mic, skips without one)

    func testMicCaptureHandleForwardsConvertedSamplesFromTheCrashFormat() throws {
        let mic: MicCapture
        do { mic = try MicCapture() } catch { throw XCTSkip("No input device here: \(error)") }
        var count = 0
        mic.onSamples = { _, n in count += n }
        mic.handle(sine(rate: 44_100, channels: 2, interleaved: false, frames: 4096))
        mic.handle(sine(rate: 44_100, channels: 2, interleaved: false, frames: 4096))
        XCTAssertGreaterThan(count, 4096)
    }
}
