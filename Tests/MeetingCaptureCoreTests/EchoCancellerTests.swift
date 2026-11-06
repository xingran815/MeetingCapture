import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Finding: speaker echo on the real call (D-58). The two real calls had the mic 260 to 290 ms
/// behind system audio, and the old 150 ms tail took off about 1 dB of that. All audio here is
/// invented: seeded noise shaped like syllables, through an invented three-path room.
final class EchoCancellerTests: XCTestCase {

    static let rate = EchoCanceller.sampleRate
    static let seconds = 12.0
    /// Measure only after the filter has had this long to converge.
    static let settle = 8.0

    // MARK: - Invented audio

    /// Small deterministic generator, so every run sees the same samples.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) * 2 - 1 }
    }

    /// Broadband noise with syllable-rate bursts (about 4 per second) and short pauses.
    static func speechLike(seed: UInt64, seconds: Double, amplitude: Float) -> [Float] {
        var rng = SplitMix64(state: seed)
        let count = Int((seconds * Double(rate)).rounded())
        var out = [Float](repeating: 0, count: count)
        let syllable = rate / 4
        var envelope: Float = 0
        var target: Float = 1
        for i in 0..<count {
            if i % syllable == 0 {
                // Every few syllables, a pause; otherwise a burst of varying strength.
                let r = (rng.unit() + 1) / 2
                target = r < 0.2 ? 0 : 0.5 + r * 0.5
            }
            envelope += (target - envelope) * 0.002
            out[i] = rng.unit() * envelope * amplitude
        }
        return out
    }

    /// The invented room: 0.4 * far(t - d) + 0.15 * far(t - d - 5 ms) + 0.08 * far(t - d - 20 ms).
    static func room(_ far: [Float], delayMs: Double) -> [Float] {
        let d = Int(delayMs * Double(rate) / 1000)
        let d5 = d + rate * 5 / 1000
        let d20 = d + rate * 20 / 1000
        var out = [Float](repeating: 0, count: far.count)
        for i in 0..<far.count {
            var v: Float = 0
            if i >= d { v += 0.4 * far[i - d] }
            if i >= d5 { v += 0.15 * far[i - d5] }
            if i >= d20 { v += 0.08 * far[i - d20] }
            out[i] = v
        }
        return out
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func db(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

    // MARK: - Feeding the canceller

    /// Collects what comes out of the canceller. The callback runs on its own queue.
    final class Sink {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ ptr: UnsafePointer<Float>, _ n: Int) {
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
            lock.unlock()
        }
        var all: [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples.count
        }
    }

    /// Reference and mic go in 100 ms at a time. Returns the cleaned mic, after waiting (bounded)
    /// until every whole 10 ms frame that can be paired has come out.
    /// `micBacklog` is mic audio pushed before the first reference; `gate` drops it when closed.
    @discardableResult
    func run(
        canceller: EchoCanceller, reference: [Float], mic: [Float],
        micBacklog: [Float] = [], gate: MicStartGate? = nil,
        micSamplesReaching: UnsafeMutablePointer<Int>? = nil
    ) throws -> [Float] {
        let sink = Sink()
        canceller.onCleanMic = { ptr, n in sink.append(ptr, n) }
        let block = Self.rate / 10
        var reached = 0

        func pushMic(_ samples: ArraySlice<Float>) {
            if let gate { guard gate.passes else { return } }
            reached += samples.count
            Array(samples).withUnsafeBufferPointer {
                canceller.pushMic($0.baseAddress!, frameCount: samples.count)
            }
        }

        // The backlog arrives first, before system audio has started.
        var b = 0
        while b < micBacklog.count {
            let e = min(b + block, micBacklog.count)
            pushMic(micBacklog[b..<e])
            b = e
        }
        gate?.open()

        var i = 0
        while i < reference.count {
            let e = min(i + block, reference.count)
            let slice = Array(reference[i..<e])
            let buf = try TestAudio.stereo(frames: slice.count) { slice[$0] }
            canceller.pushReference(buf)
            pushMic(mic[i..<min(e, mic.count)])
            i = e
        }
        micSamplesReaching?.pointee = reached

        let expected = min(reached, reference.count) / EchoCanceller.frameSize * EchoCanceller.frameSize
        let deadline = Date().addingTimeInterval(20)
        while sink.count < expected && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(sink.count, expected, "canceller output did not arrive in time")
        return sink.all
    }

    /// How many dB the output is below the mic over the settled part of the clip.
    func reduction(mic: [Float], out: [Float], from: Double = settle) -> Double {
        let a = Int(from * Double(Self.rate))
        let end = min(mic.count, out.count)
        XCTAssertGreaterThan(end, a, "no output past the convergence point")
        return Self.db(Self.rms(mic[a..<end]) / Self.rms(out[a..<end]))
    }

    func echoReduction(delayMs: Double, tailSamples: Int? = nil) throws -> Double {
        let far = Self.speechLike(seed: 1, seconds: Self.seconds, amplitude: 0.3)
        let mic = Self.room(far, delayMs: delayMs)
        let canceller = tailSamples.map { EchoCanceller(tailSamples: $0) } ?? EchoCanceller()
        let out = try run(canceller: canceller, reference: far, mic: mic)
        let r = reduction(mic: mic, out: out)
        print(
            "EchoCancellerTests: delay \(delayMs) ms, tail \(tailSamples ?? EchoCanceller.tailSamples) samples: \(r) dB"
        )
        return r
    }

    // MARK: - Tests

    func testDefaultTailRemovesTheEchoMeasuredOnTheRealCalls() throws {
        XCTAssertGreaterThanOrEqual(try echoReduction(delayMs: 290), 15)
    }

    func testOldTailOf150msTakesOffUnder6dBAt290ms() throws {
        // Proves the setup can show the failure the 500 ms tail fixes.
        XCTAssertLessThan(try echoReduction(delayMs: 290, tailSamples: Self.rate * 150 / 1000), 6)
    }

    func testDefaultTailRemovesEchoesAt30msAnd450ms() throws {
        XCTAssertGreaterThanOrEqual(try echoReduction(delayMs: 30), 15)
        XCTAssertGreaterThanOrEqual(try echoReduction(delayMs: 450), 15)
    }

    func testNearVoiceIsKeptWhileTheEchoIsRemoved() throws {
        let far = Self.speechLike(seed: 1, seconds: Self.seconds, amplitude: 0.3)
        let echo = Self.room(far, delayMs: 290)
        // The near voice joins at the convergence point, so both talk during the measured part.
        let start = Int(Self.settle * Double(Self.rate))
        var near = Self.speechLike(seed: 7, seconds: Self.seconds, amplitude: 0.15)
        for i in 0..<start { near[i] = 0 }
        let mic = zip(echo, near).map { $0 + $1 }

        let out = try run(canceller: EchoCanceller(), reference: far, mic: mic)
        let end = min(out.count, near.count)
        let kept = Self.db(Self.rms(out[start..<end]) / Self.rms(near[start..<end]))
        print("EchoCancellerTests: double-talk output vs near voice alone: \(kept) dB")
        XCTAssertLessThanOrEqual(abs(kept), 3)
    }

    func testMicBacklogBeforeSystemAudioIsDroppedByTheGateAndTheEchoIsRemoved() throws {
        let far = Self.speechLike(seed: 1, seconds: Self.seconds, amplitude: 0.3)
        let mic = Self.room(far, delayMs: 30)
        let backlogSamples = Self.rate * 290 / 1000
        let backlog = Self.speechLike(seed: 3, seconds: 0.29, amplitude: 0.02)
        XCTAssertEqual(backlog.count, backlogSamples)

        let gate = MicStartGate()
        var reached = 0
        let out = try run(
            canceller: EchoCanceller(), reference: far, mic: mic,
            micBacklog: backlog, gate: gate, micSamplesReaching: &reached)

        // Nothing sent before open() got through, so the pairing starts clean.
        XCTAssertEqual(reached, mic.count, "the \(backlogSamples) backlog samples must not reach the canceller")
        let r = reduction(mic: mic, out: out)
        print("EchoCancellerTests: gated backlog, 30 ms room: \(r) dB")
        XCTAssertGreaterThanOrEqual(r, 15)
    }

    func testMicStartGateIsClosedUntilOpenedAndStaysOpen() {
        let gate = MicStartGate()
        XCTAssertFalse(gate.passes)
        gate.open()
        XCTAssertTrue(gate.passes)
        gate.open()
        XCTAssertTrue(gate.passes)
    }

    func testMicStartGateIsSafeWhenOpenedFromAnotherThreadWhileRead() {
        let gate = MicStartGate()
        let lock = NSLock()
        var wentBackToClosed = false
        var sawOpen = false
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            if worker == 0 {
                Thread.sleep(forTimeInterval: 0.01)
                gate.open()
            } else {
                var seen = false
                for _ in 0..<200_000 {
                    let p = gate.passes
                    if seen && !p {
                        lock.lock()
                        wentBackToClosed = true
                        lock.unlock()
                    }
                    if p {
                        seen = true
                    }
                }
                if seen {
                    lock.lock()
                    sawOpen = true
                    lock.unlock()
                }
            }
        }
        XCTAssertFalse(wentBackToClosed, "a gate that was seen open closed again")
        XCTAssertTrue(gate.passes)
        _ = sawOpen  // Whether a reader caught the opening depends on timing, so it isn't asserted.
    }

    func testTailIs500msAndTailSamplesAgree() {
        XCTAssertEqual(EchoCanceller.tailMs, 500)
        XCTAssertEqual(EchoCanceller.tailSamples, 24_000)
        XCTAssertEqual(EchoCanceller.tailSamples, EchoCanceller.sampleRate * EchoCanceller.tailMs / 1000)
    }
}
