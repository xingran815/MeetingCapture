import AVFoundation
import Accelerate
import XCTest

@testable import MeetingCaptureCore

/// Invented audio for the echo tests: syllable-like noise bursts, and a synthetic room with
/// about 150 ms of delay (the Studio Display figure), a level near 0 dB and a decaying tail.
/// Nothing here is a recording. Everything is seeded, so every run sees the same samples.
enum EchoLab {

    static let rate = EchoRemover.sampleRate
    static let delay = 7_200  // 150 ms

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// White noise, uniform, scaled to this RMS.
    static func noise(_ count: Int, seed: UInt64, rms: Double) -> [Double] {
        var rng = SplitMix64(state: seed)
        let scale = rms * 3.0.squareRoot()
        return (0..<count).map { _ in (rng.unit() * 2 - 1) * scale }
    }

    /// Two one-pole low-passes in a row (about 1.5 kHz), so the signal is speech-wide and
    /// interpolating it for a clock drift costs almost nothing.
    static func lowpass(_ x: [Double]) -> [Double] {
        var out = x
        for _ in 0..<2 {
            var padded = [0.0, 0.0] + out
            var result = [Double](repeating: 0, count: padded.count)
            let coefficients: [Double] = [0.2, 0, 0, -0.8, 0]
            vDSP_deq22D(&padded, 1, coefficients, &result, 1, vDSP_Length(out.count))
            out = Array(result[2...])
        }
        return out
    }

    /// Syllable-like bursts with short gaps and now and then a longer pause, at this
    /// overall RMS. A different seed gives different "words".
    static func speech(seconds: Double, seed: UInt64, rms: Double) -> [Double] {
        speech(frames: Int(seconds * Double(rate) + 0.5), seed: seed, rms: rms)
    }

    static func speech(frames: Int, seed: UInt64, rms: Double) -> [Double] {
        var rng = SplitMix64(state: seed &* 7 &+ 1)
        var envelope = [Double](repeating: 0, count: frames)
        var cursor = Int(0.2 * Double(rate))
        var bursts = 0
        while cursor < frames {
            let length = Int((0.15 + 0.25 * rng.unit()) * Double(rate))
            let gain = 0.5 + 0.5 * rng.unit()
            let end = min(cursor + length, frames)
            for i in cursor..<end { envelope[i] = gain }
            cursor = end
            bursts += 1
            let gap = bursts % 4 == 0 ? 0.6 + 0.6 * rng.unit() : 0.05 + 0.2 * rng.unit()
            cursor += Int(gap * Double(rate))
        }
        // A 2 ms ramp on every edge.
        var padded = [0.0, 0.0] + envelope
        var smooth = [Double](repeating: 0, count: padded.count)
        vDSP_deq22D(&padded, 1, [0.02, 0, 0, -0.98, 0], &smooth, 1, vDSP_Length(frames))
        let carrier = lowpass(noise(frames, seed: seed, rms: 1))
        var signal = [Double](repeating: 0, count: frames)
        vDSP_vmulD(Array(smooth[2...]), 1, carrier, 1, &signal, 1, vDSP_Length(frames))
        return scaled(signal, toRMS: rms)
    }

    static func scaled(_ x: [Double], toRMS target: Double) -> [Double] {
        let current = EchoRemover.meanPower(x).squareRoot()
        guard current > 0 else { return x }
        var factor = target / current
        var out = x
        vDSP_vsmulD(x, 1, &factor, &out, 1, vDSP_Length(x.count))
        return out
    }

    /// A direct path of 0 dB, then a random tail that dies away in about 50 ms. Its total
    /// gain is within 1 dB of 0.
    static func tail(seed: UInt64) -> [Double] {
        let taps = 2_400
        var rng = SplitMix64(state: seed)
        var h = [Double](repeating: 0, count: taps)
        h[0] = 1
        for n in 1..<taps {
            h[n] = (rng.unit() * 2 - 1) * 3.0.squareRoot() * 0.02 * exp(-Double(n) / 720)
        }
        return h
    }

    /// `x` through `h`, cut to the length of `x`.
    static func convolve(_ x: [Double], _ h: [Double]) -> [Double] {
        let n = x.count
        let m = h.count
        let padded = [Double](repeating: 0, count: m - 1) + x
        var out = [Double](repeating: 0, count: n)
        h.withUnsafeBufferPointer { hp in
            vDSP_convD(padded, 1, hp.baseAddress! + (m - 1), -1, &out, 1, vDSP_Length(n), vDSP_Length(m))
        }
        return out
    }

    static func shifted(_ x: [Double], by samples: Int) -> [Double] {
        guard samples > 0 else { return x }
        return [Double](repeating: 0, count: samples) + x.dropLast(samples)
    }

    /// The far side as the mic hears it: 150 ms late, through the invented room.
    static func echo(of far: [Double], delay: Int = EchoLab.delay, seed: UInt64 = 99) -> [Double] {
        shifted(convolve(far, tail(seed: seed)), by: delay)
    }

    static func sum(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: max(a.count, b.count))
        for (i, v) in a.enumerated() { out[i] += v }
        for (i, v) in b.enumerated() { out[i] += v }
        return out
    }

    static func adding(_ x: [Double], _ other: [Double], at start: Int, gain: Double = 1) -> [Double] {
        var out = x
        for (i, v) in other.enumerated() where start + i < out.count { out[start + i] += gain * v }
        return out
    }

    /// Zeros everywhere except in `range`.
    static func only(_ x: [Double], seconds range: ClosedRange<Double>) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        let a = Int(range.lowerBound * Double(rate))
        let b = min(Int(range.upperBound * Double(rate)), x.count)
        for i in a..<b { out[i] = x[i] }
        return out
    }

    /// The mic's clock running `ppm` faster: mic[m] reads the source at m × (1 - ppm).
    static func warped(_ x: [Double], ppm: Double) -> [Double] {
        let n = x.count
        var positions = (0..<n).map { Double($0) * (1 - ppm * 1e-6) }
        var out = [Double](repeating: 0, count: n)
        vDSP_vlintD(x, &positions, 1, &out, 1, vDSP_Length(n), vDSP_Length(n))
        return out
    }

    // MARK: Measures

    /// Power of each non-overlapping 10 ms frame.
    static func framePower(_ x: [Double], frame: Int = 480) -> [Double] {
        stride(from: 0, to: x.count - frame + 1, by: frame).map {
            EchoRemover.meanPower(Array(x[$0..<($0 + frame)]))
        }
    }

    static func db(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-30)) }

    /// How far `output` is below `input`, in dB, over the loud frames of `input` from
    /// `from` seconds on. Frames are 10 ms, and "loud" is RMS above `threshold`.
    static func reductionDB(
        input: [Double], output: [Double], from: Double, to: Double? = nil, threshold: Double = 0.03
    ) -> Double {
        let a = framePower(input)
        let b = framePower(output)
        let first = Int(from * 100)
        let last = min(to.map { Int($0 * 100) } ?? a.count, a.count, b.count)
        var before = 0.0
        var after = 0.0
        for i in first..<last where a[i] > threshold * threshold {
            before += a[i]
            after += b[i]
        }
        return db(before / max(after, 1e-30))
    }

    /// 10 log10 of mean power in the span, `output` over `input`: negative if quieter.
    static func levelChangeDB(input: [Double], output: [Double], seconds: ClosedRange<Double>) -> Double {
        let a = Int(seconds.lowerBound * Double(rate))
        let b = min(Int(seconds.upperBound * Double(rate)), input.count, output.count)
        return db(EchoRemover.meanPower(Array(output[a..<b])) / EchoRemover.meanPower(Array(input[a..<b])))
    }

    // MARK: Files

    static func writeMono(_ x: [Double], to url: URL, rate sampleRate: Int = EchoRemover.sampleRate) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var start = 0
            while start < x.count {
                let count = min(48_000, x.count - start)
                let buffer = try XCTUnwrap(
                    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let out = try XCTUnwrap(buffer.floatChannelData?[0])
                x[start..<(start + count)].withUnsafeBufferPointer {
                    vDSP_vdpsp($0.baseAddress!, 1, out, 1, vDSP_Length(count))
                }
                try file.write(from: buffer)
                start += count
            }
        }
    }

    /// Channel `channel` of any audio file as doubles.
    static func read(_ url: URL, channel: Int = 0) throws -> [Double] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { return [] }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return (0..<Int(buffer.frameLength)).map { Double(data[channel][$0]) }
    }

    /// A two-track WAV (mic is channel 1) through the real `TrackWriter`.
    static func writeTwoTrack(mic: [Double], system: [Double], to url: URL) throws {
        let frames = max(mic.count, system.count)
        try TestAudio.writeWAV(
            at: url, seconds: (Double(frames) + 0.5) / Double(rate),
            mic: { $0 < mic.count ? Float(mic[$0]) : 0 },
            system: { $0 < system.count ? Float(system[$0]) : 0 })
    }
}

/// The standard 24 s call used by several tests: the far side talks, the room echoes it.
/// Built once, because the room convolution is the slow part.
struct EchoScene {
    let seconds = 24.0
    let far: [Double]
    let echo: [Double]
    let noise: [Double]

    /// Far-end speech at RMS 0.1, a room tail, and room noise 70 dB down.
    static let standard: EchoScene = {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        return EchoScene(
            far: far, echo: EchoLab.echo(of: far), noise: EchoLab.noise(far.count, seed: 5, rms: 0.0003))
    }()

    /// The echo and the room noise: the mic when the user says nothing.
    var micEchoOnly: [Double] { EchoLab.sum(echo, noise) }
}
