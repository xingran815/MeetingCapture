import Accelerate
import XCTest

@testable import MeetingCaptureCore

/// The numeric parts of the echo remover, each checked against something worked out another
/// way, and the rules that label a mic line as echo. No files.
final class EchoMathTests: XCTestCase {

    // MARK: 6. levinson

    /// Gaussian elimination with partial pivoting: the independent answer.
    private func solve(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var m = zip(a, b).map { $0 + [$1] }
        for col in 0..<n {
            let pivot = (col..<n).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            m.swapAt(col, pivot)
            for row in (col + 1)..<max(n, col + 1) {
                let f = m[row][col] / m[col][col]
                for k in col...n { m[row][k] -= f * m[col][k] }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = m[row][n]
            for k in (row + 1)..<max(n, row + 1) { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    func testLevinsonAgreesWithAnIndependentSolve() throws {
        // A real autocorrelation, so the matrix is positive definite.
        let signal = EchoLab.lowpass(EchoLab.noise(4_000, seed: 3, rms: 1))
        for n in [1, 2, 3, 6, 12] {
            let r = (0..<n).map { lag in (0..<(signal.count - lag)).reduce(0.0) { $0 + signal[$1] * signal[$1 + lag] } }
            let b = EchoLab.noise(n, seed: UInt64(n), rms: 1000)
            let toeplitz = (0..<n).map { i in (0..<n).map { j in r[abs(i - j)] } }
            let expected = solve(toeplitz, b)
            let got = try XCTUnwrap(EchoRemover.levinson(autocorrelation: r, crossCorrelation: b))
            XCTAssertEqual(got.count, n)
            for i in 0..<n {
                XCTAssertEqual(got[i], expected[i], accuracy: 1e-8 * max(1, abs(expected[i])), "n=\(n) tap \(i)")
            }
        }
    }

    func testLevinsonRecoversAKnownFilter() throws {
        // y = h * x exactly, circularly so the sums have no edges, and the normal
        // equations must give h back.
        let x = EchoLab.noise(20_000, seed: 8, rms: 1)
        let h = [0.0, 0.5, -0.25, 0.125, 0, 0.0625]
        let count = x.count
        let y = (0..<count).map { t in h.indices.reduce(0.0) { $0 + h[$1] * x[(t - $1 + count) % count] } }
        let n = h.count
        let rxx = (0..<n).map { k in (0..<count).reduce(0.0) { $0 + x[$1] * x[($1 - k + count) % count] } }
        let rxy = (0..<n).map { k in (0..<count).reduce(0.0) { $0 + y[$1] * x[($1 - k + count) % count] } }
        let w = try XCTUnwrap(EchoRemover.levinson(autocorrelation: rxx, crossCorrelation: rxy))
        for i in 0..<n { XCTAssertEqual(w[i], h[i], accuracy: 1e-9) }
    }

    func testLevinsonRefusesBadInput() {
        XCTAssertNil(EchoRemover.levinson(autocorrelation: [], crossCorrelation: []))
        XCTAssertNil(EchoRemover.levinson(autocorrelation: [0, 0], crossCorrelation: [1, 1]))
        XCTAssertNil(EchoRemover.levinson(autocorrelation: [-1, 0], crossCorrelation: [1, 1]))
        XCTAssertNil(EchoRemover.levinson(autocorrelation: [1, 0.5], crossCorrelation: [1]))
        // Not positive definite: |r1| > r0.
        XCTAssertNil(EchoRemover.levinson(autocorrelation: [1, 2], crossCorrelation: [1, 1]))
        XCTAssertEqual(EchoRemover.levinson(autocorrelation: [4], crossCorrelation: [2]), [0.5])
    }

    // MARK: 6. RealFFT

    func testFFTRoundTripsAndPadsShortInput() {
        let fft = RealFFT(atLeast: 1_000)
        XCTAssertEqual(fft.size, 1_024)
        let x = EchoLab.noise(1_000, seed: 2, rms: 0.3)
        let back = fft.inverse(fft.forward(x))
        XCTAssertEqual(back.count, 1_024)
        for i in 0..<1_000 { XCTAssertEqual(back[i], x[i], accuracy: 1e-12) }
        for i in 1_000..<1_024 { XCTAssertEqual(back[i], 0, accuracy: 1e-12) }
    }

    func testFFTSizesRoundUpToAPowerOfTwo() {
        XCTAssertEqual(RealFFT(atLeast: 2).size, 2)
        XCTAssertEqual(RealFFT(atLeast: 3).size, 4)
        XCTAssertEqual(RealFFT(atLeast: 4_096).size, 4_096)
        XCTAssertEqual(RealFFT(atLeast: 4_097).size, 8_192)
    }

    func testFFTMatchesTheTrueTransformOfAnImpulseAndACosine() {
        let fft = RealFFT(atLeast: 64)
        let impulse = fft.forward([1])
        XCTAssertTrue(impulse.re.allSatisfy { abs($0 - 1) < 1e-12 })
        XCTAssertEqual(impulse.im[0], 1, accuracy: 1e-12, "Nyquist of an impulse is 1")
        XCTAssertTrue(impulse.im.dropFirst().allSatisfy { abs($0) < 1e-12 })

        // cos(2π·5n/64) has N/2 = 32 in bin 5.
        let cosine = (0..<64).map { cos(2 * Double.pi * 5 * Double($0) / 64) }
        let spectrum = fft.forward(cosine)
        XCTAssertEqual(spectrum.real(at: 5), 32, accuracy: 1e-9)
        XCTAssertEqual(spectrum.imaginary(at: 5), 0, accuracy: 1e-9)
        XCTAssertEqual(spectrum.real(at: 6), 0, accuracy: 1e-9)
    }

    func testMultiplyingSpectraIsCircularConvolution() {
        let fft = RealFFT(atLeast: 256)
        let x = EchoLab.noise(200, seed: 4, rms: 1)
        var delta = [Double](repeating: 0, count: 256)
        delta[4] = 1
        let y = fft.inverse(fft.forward(x).multiplied(by: fft.forward(delta)))
        for i in 0..<200 { XCTAssertEqual(y[i + 4], x[i], accuracy: 1e-12) }
        XCTAssertEqual(y[0], 0, accuracy: 1e-12)
    }

    /// `y.correlated(with: x)` has its peak at the lag k where y[n] = x[n - k]: positive
    /// means y is later. This is the sign the whole remover relies on.
    func testCorrelatedPeaksAtThePositiveLagWhenTheFirstArgumentIsLater() {
        let fft = RealFFT(atLeast: 4_096)
        let x = EchoLab.noise(2_000, seed: 6, rms: 1)
        let power = x.reduce(0) { $0 + $1 * $1 }

        let later = EchoLab.shifted(x, by: 5)
        let c = fft.inverse(fft.forward(later).correlated(with: fft.forward(x)))
        XCTAssertEqual(c[5], power - x[1995...].reduce(0) { $0 + $1 * $1 }, accuracy: 1e-8)
        XCTAssertEqual(c.indices.max { c[$0] < c[$1] }, 5)

        // Earlier: the peak wraps to the end of the circle, size - 3.
        let earlier = Array(x.dropFirst(3)) + [0, 0, 0]
        let d = fft.inverse(fft.forward(earlier).correlated(with: fft.forward(x)))
        XCTAssertEqual(d.indices.max { d[$0] < d[$1] }, 4_096 - 3)

        // The same through crossSpectrum(of:with:).
        let e = fft.inverse(fft.crossSpectrum(of: later, with: x))
        XCTAssertEqual(e.indices.max { e[$0] < e[$1] }, 5)

        // Against itself: lag 0, equal to the energy.
        let own = fft.inverse(fft.forward(x).correlated(with: fft.forward(x)))
        XCTAssertEqual(own[0], power, accuracy: 1e-8)
    }

    // MARK: 6. peakLag

    private let lowest = 2 * EchoLab.rate / 1000
    private let highest = 400 * EchoLab.rate / 1000

    func testPeakLagFindsTheDelayAndItsSign() {
        let reference = EchoLab.speech(seconds: 3, seed: 1, rms: 0.1)
        let fft = RealFFT(atLeast: 2 * reference.count)
        let mic = EchoLab.shifted(reference, by: 7_200)
        XCTAssertEqual(
            EchoRemover.peakLag(mic: mic, reference: reference, fft: fft, lowest: lowest, highest: highest), 7_200)
        // The mic ahead of the reference is not a lag this code reports.
        let ahead = Array(reference.dropFirst(2_000)) + [Double](repeating: 0, count: 2_000)
        XCTAssertNil(EchoRemover.peakLag(mic: ahead, reference: reference, fft: fft, lowest: lowest, highest: highest))
    }

    func testPeakLagIgnoresAFalsePeakAtLagZero() {
        let reference = EchoLab.speech(seconds: 3, seed: 1, rms: 0.1)
        let fft = RealFFT(atLeast: 2 * reference.count)
        // Only a copy at lag 0: that is not an echo, and it isn't reported as one.
        XCTAssertNil(
            EchoRemover.peakLag(mic: reference, reference: reference, fft: fft, lowest: lowest, highest: highest))
        // A strong zero-lag part, and a weaker real echo: the echo is what comes back.
        let mic = EchoLab.sum(reference, EchoLab.shifted(reference, by: 7_200).map { $0 * 0.5 })
        XCTAssertEqual(
            EchoRemover.peakLag(mic: mic, reference: reference, fft: fft, lowest: lowest, highest: highest), 7_200)
    }

    func testPeakLagGivesNothingForUnrelatedSignals() {
        let a = EchoLab.speech(seconds: 3, seed: 1, rms: 0.1)
        let b = EchoLab.speech(seconds: 3, seed: 2, rms: 0.1)
        let fft = RealFFT(atLeast: 2 * a.count)
        XCTAssertNil(EchoRemover.peakLag(mic: b, reference: a, fft: fft, lowest: lowest, highest: highest))
        // And a range wider than the transform is refused rather than read past the end.
        let small = RealFFT(atLeast: 1_024)
        XCTAssertNil(
            EchoRemover.peakLag(
                mic: Array(a.prefix(500)), reference: Array(b.prefix(500)), fft: small, lowest: 10, highest: 5_000))
    }

    // MARK: 10. Labels

    private func evidence(mic: Float, clean: Float, room: Float = -70, seconds: Double = 2) -> EchoEvidence {
        let frames = Int(seconds / EchoEvidence.frameSeconds)
        return EchoEvidence(
            micDB: [Float](repeating: mic, count: frames), cleanDB: [Float](repeating: clean, count: frames),
            roomDB: room)
    }

    func testAHighDropToNearTheRoomLooksLikeEcho() {
        // Took off 45 dB, and what's left is 5 dB over the room.
        XCTAssertTrue(evidence(mic: -20, clean: -65).looksLikeEcho(start: 0.2, end: 1.8))
    }

    func testLoudSpeechWithABigDropIsATalkOverNotEcho() {
        // 15 dB off, but the rest is 45 dB above the room: the user, talking over the far side.
        XCTAssertFalse(evidence(mic: -10, clean: -25).looksLikeEcho(start: 0.2, end: 1.8))
    }

    func testASoftLineWithNoDropIsKept() {
        // D-56: quiet speech nobody cancelled isn't touched.
        XCTAssertFalse(evidence(mic: -60, clean: -60).looksLikeEcho(start: 0.2, end: 1.8))
        XCTAssertFalse(evidence(mic: -52, clean: -55).looksLikeEcho(start: 0.2, end: 1.8), "3 dB isn't a drop")
    }

    func testTheThresholdsAreTheDocumentedOnes() {
        XCTAssertTrue(evidence(mic: -40, clean: -50.5, room: -60).looksLikeEcho(start: 0, end: 1))
        XCTAssertFalse(evidence(mic: -40, clean: -49.5, room: -60).looksLikeEcho(start: 0, end: 1), "9.5 dB drop")
        // 15 dB over the room is the first level that is no longer echo.
        XCTAssertTrue(evidence(mic: 0, clean: -45.1, room: -60).looksLikeEcho(start: 0, end: 1))
        XCTAssertFalse(evidence(mic: 0, clean: -44.9, room: -60).looksLikeEcho(start: 0, end: 1))
    }

    func testAnEmptyOrOutOfRangeTimeRangeIsNeverEcho() {
        let echo = evidence(mic: -20, clean: -65)  // 2 s, so frames 0..<200
        XCTAssertTrue(echo.looksLikeEcho(start: 0.5, end: 1.5))
        XCTAssertFalse(echo.looksLikeEcho(start: 5, end: 6), "after the end")
        XCTAssertFalse(echo.looksLikeEcho(start: 1.5, end: 0.5), "backwards")
        XCTAssertFalse(echo.looksLikeEcho(start: -3, end: -1), "before the start")
        XCTAssertFalse(echo.looksLikeEcho(start: 2.5, end: 2.5))
        let none = EchoEvidence(micDB: [], cleanDB: [], roomDB: -70)
        XCTAssertFalse(none.looksLikeEcho(start: 0, end: 1))
        XCTAssertFalse(none.looksLikeEcho(start: 0, end: 0))
        // Mismatched lengths use the shorter, and don't read past it.
        let uneven = EchoEvidence(micDB: [Float](repeating: -20, count: 50), cleanDB: [], roomDB: -70)
        XCTAssertFalse(uneven.looksLikeEcho(start: 0, end: 1))
    }

    /// A segment can hold a long silence before its words: only its loudest fifth counts.
    func testALongSilenceBeforeAnEchoLineDoesNotHideIt() {
        var mic = [Float](repeating: -70, count: 400)
        var clean = [Float](repeating: -70, count: 400)
        for i in 300..<400 {
            mic[i] = -20
            clean[i] = -65
        }
        let e = EchoEvidence(micDB: mic, cleanDB: clean, roomDB: -70)
        XCTAssertTrue(e.looksLikeEcho(start: 0, end: 4))
    }

    /// The builder finds the room level from frames with no echo estimate, and the drop from
    /// the frames where there is one.
    func testEvidenceBuilderReadsRoomAndDrop() {
        var builder = EvidenceBuilder()
        let frame = 480
        for i in 0..<100 {
            let quiet = i < 60
            let mic = [Double](repeating: quiet ? 0.0003 : 0.1, count: frame)
            let estimate = [Double](repeating: quiet ? 0 : 0.1, count: frame)
            builder.add(mic: mic, estimate: estimate)
        }
        let cleanPower: [Float] = (0..<100).map { $0 < 60 ? 9e-8 : 1e-8 }
        let e = builder.build(cleanPower: cleanPower)
        XCTAssertEqual(e.micDB.count, 100)
        XCTAssertEqual(e.roomDB, -70.5, accuracy: 0.1)
        XCTAssertEqual(e.micDB[80], -20, accuracy: 0.01)
        XCTAssertEqual(e.cleanDB[80], -80, accuracy: 0.01)
        XCTAssertTrue(e.looksLikeEcho(start: 0.65, end: 0.95))
        XCTAssertFalse(e.looksLikeEcho(start: 0.05, end: 0.5))
    }

    // MARK: 11. The ceiling follows the user's own voice (From the M3.2 review, finding 2)

    private func evidence(mic: Float, clean: Float, room: Float = -70, voice: Float?) -> EchoEvidence {
        var e = evidence(mic: mic, clean: clean, room: room)
        e.voiceDB = voice
        return e
    }

    func testTheCeilingIs15dBWithNoVoiceOrALoudVoice() {
        // From the M3.2 review, finding 2.
        XCTAssertEqual(evidence(mic: -20, clean: -65, voice: nil).ceilingAboveRoom, 15)
        XCTAssertEqual(evidence(mic: -20, clean: -65, voice: -10).ceilingAboveRoom, 15, "60 dB over the room")
        XCTAssertEqual(evidence(mic: -20, clean: -65, voice: -45).ceilingAboveRoom, 15, "25 dB over: 15 exactly")
    }

    func testASoftVoiceLowersTheCeilingToVoiceMinus10() {
        // From the M3.2 review, finding 2: voice 20 dB over the room, so the ceiling is 10.
        XCTAssertEqual(evidence(mic: -20, clean: -65, voice: -50).ceilingAboveRoom, 10, accuracy: 0.001)
        XCTAssertEqual(evidence(mic: -20, clean: -65, voice: -55).ceilingAboveRoom, 5, accuracy: 0.001)
    }

    func testALineNearASoftVoiceIsKeptButTheSameLineIsEchoNextToALoudVoice() {
        // From the M3.2 review, finding 2: 13 dB over the room, 12 dB off.
        let soft = evidence(mic: -45, clean: -57, voice: -50)  // voice 20 dB over the room
        let loud = evidence(mic: -45, clean: -57, voice: -30)  // voice 40 dB over the room
        XCTAssertFalse(soft.looksLikeEcho(start: 0.2, end: 1.8), "within 10 dB of the user's voice: kept")
        XCTAssertTrue(loud.looksLikeEcho(start: 0.2, end: 1.8))
        XCTAssertTrue(evidence(mic: -45, clean: -57, voice: nil).looksLikeEcho(start: 0.2, end: 1.8))
    }

    /// 60 quiet frames (amplitude 0.0003, the room), then these (frames, amplitude, estimate).
    private func built(_ spans: [(Int, Double, Double)]) -> EchoEvidence {
        var builder = EvidenceBuilder()
        var count = 0
        for (frames, amplitude, estimate) in [(60, 0.0003, 0.0)] + spans {
            for _ in 0..<frames {
                builder.add(
                    mic: [Double](repeating: amplitude, count: 480),
                    estimate: [Double](repeating: estimate, count: 480))
            }
            count += frames
        }
        return builder.build(cleanPower: [Float](repeating: 1e-8, count: count))
    }

    func testFewerThanAHundredLoudQuietFarSideFramesGiveNoVoice() {
        // From the M3.2 review, finding 2: 99 frames is under a second.
        XCTAssertNil(built([(99, 0.1, 0)]).voiceDB)
        XCTAssertNotNil(built([(100, 0.1, 0)]).voiceDB)
    }

    func testFramesWithAnEstimateAreNotTheUsersVoice() throws {
        // From the M3.2 review, finding 2: loud, but the far side was talking.
        XCTAssertNil(built([(300, 0.1, 0.1)]).voiceDB)
        // 80 alone plus plenty with the far side: still under 100 that count.
        XCTAssertNil(built([(80, 0.1, 0), (300, 0.1, 0.1)]).voiceDB)
        // The far side's frames don't dilute the others: 120 alone at -20 dB.
        let e = built([(120, 0.1, 0), (300, 0.3, 0.1)])
        XCTAssertEqual(try XCTUnwrap(e.voiceDB), -20, accuracy: 0.05)
    }

    func testVoiceIsTheMeanDBOfTheLoudestFifth() throws {
        // From the M3.2 review, finding 2: 150 frames, so 30 count: 15 at -10 dB and 15 at -20 dB.
        let e = built([(120, 0.001.squareRoot() * 1, 0), (15, 0.01.squareRoot(), 0), (15, 0.1.squareRoot(), 0)])
        XCTAssertEqual(try XCTUnwrap(e.voiceDB), -15, accuracy: 0.05, "the mean of dB, not of power")
    }

    func testAQuietRoomAloneGivesNoVoice() {
        // Nothing 10 dB over the room at all.
        XCTAssertNil(built([(200, 0.0003, 0)]).voiceDB)
    }

    func testMedianLagIsTheMiddleOne() {
        let lags = [7_200, 100, 7_210, 9_000, 7_205].enumerated().map {
            EchoRemover.LagPoint(seconds: Double($0.offset), lag: $0.element)
        }
        XCTAssertEqual(EchoRemover.medianLag(lags), 7_205)
    }
}
