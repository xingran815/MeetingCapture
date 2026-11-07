import AVFoundation
import Accelerate
import Foundation

// Removes speaker echo from the mic track after the call, from the raw tracks.
//
// Why after the call: on a Studio Display the echo is about as loud as its source, and
// the mic's and the system's clocks differ by about 8 ppm, so the path keeps moving under
// any filter (M3.2, `dev/evidence/`). After the call the filter can see its own future.
//
//   1. Lag and drift: a whitened cross-correlation per window gives both.
//   2. Linear: one least-squares filter per 8 s window, from the reference on the mic's
//      clock, crossfaded. The user's speech isn't correlated with the reference at these
//      lags, so it barely bends the fit, and there's no adaptation to go wrong in double
//      talk. A repeat of the far side's words is later than the filter reaches.
//   3. Residual: a per-bin gain from how much of what's left the echo estimate explains.
//      When the user talks over the far side, what's left isn't coherent with the
//      estimate, so the gain stays near one.
//
// Nothing here looks at words. Audio in memory is bounded by one window; the line-check
// levels grow with length, at about 262 MB at peak for 30 minutes.
// The raw track is never touched, so a failure here can't lose the recording.
enum EchoRemover {

    static let sampleRate = 48_000
    // From the lab, tuned on `main-3` only, then frozen for the other takes. The figures
    // and their limits are in the M3.2 report.
    static let fitWindowSeconds = 8.0
    static let fitHopSeconds = 2.0
    static let filterTaps = 9_600
    static let leadSeconds = 0.03
    static let overSuppression = 16.0
    static let gainFloorDB = -50.0
    /// A fit needs far more reference than it has taps, or it can reproduce the user's voice
    /// and subtract it. So a window with less reuses the last good filter, which holds
    /// while the room stays the same. From the M3.2 deep review.
    static let minimumActiveSeconds = 2.0

    struct Result {
        let cleaned: URL
        let lagSeconds: Double
        let driftPPM: Double
        let evidence: EchoEvidence
        /// The tracks' delay jumped during the part, and one shift can't follow that, so
        /// some of the part may keep its echo.
        let lagMoved: Bool
    }

    /// Writes the cleaned mic to `output`, or returns nil if no echo shows in the mic at
    /// all, such as on headphones, where filtering could only harm the voice.
    static func clean(mic: URL, system: URL, to output: URL) throws -> Result? {
        let micReader = try MonoReader(mic)
        let systemReader = try MonoReader(system)
        let frames = min(micReader.length, systemReader.length)
        guard frames > 0 else { return nil }
        let track = try lagTrack(mic: micReader, system: systemReader, frames: frames)
        guard let lag = medianLag(track) else { return nil }
        let drift = driftPPM(track)

        // The warp pivots at the file's start, so the shift has to be the lag there, not the
        // median, or a fast mic clock moves the echo ahead of what the filter can reach.
        let lagAtStart = lagAtFileStart(track, ppm: drift)
        let reference = try WarpedReference(
            reader: systemReader, ppm: drift, shift: max(lagAtStart - Int(leadSeconds * Double(sampleRate)), 0))
        let writer = try MonoWriter(output)
        let suppressor = ResidualSuppressor(writer: writer)
        var evidence = EvidenceBuilder()
        try fitAndSubtract(mic: micReader, reference: reference, frames: frames) { micChunk, estimate in
            var left = [Double](repeating: 0, count: micChunk.count)
            vDSP_vsubD(estimate, 1, micChunk, 1, &left, 1, vDSP_Length(micChunk.count))
            evidence.add(mic: micChunk, estimate: estimate)
            try suppressor.push(error: left, estimate: estimate)
        }
        try suppressor.finish(totalFrames: frames)
        writer.close()
        return Result(
            cleaned: output, lagSeconds: Double(lag) / Double(sampleRate), driftPPM: drift,
            evidence: evidence.build(cleanPower: suppressor.cleanPower),
            lagMoved: lagMoved(track, ppm: drift))
    }

    // MARK: - Lag and drift

    struct LagPoint: Equatable {
        let seconds: Double
        let lag: Int
    }

    static func lagTrack(mic: MonoReader, system: MonoReader, frames: Int) throws -> [LagPoint] {
        let window = 20 * sampleRate
        // Windows overlap, and the last ends at the file's end, so no far side goes unseen.
        let hop = 15 * sampleRate
        // A false peak at exactly zero shows in some windows, and no speaker and mic pair
        // has that little delay.
        let lowest = 2 * sampleRate / 1000
        let highest = 400 * sampleRate / 1000
        let fft = RealFFT(atLeast: 2 * min(window, frames))
        var points: [LagPoint] = []
        var starts = Array(stride(from: 0, to: max(frames - window, 1), by: hop))
        if frames > window, let last = starts.last, last != frames - window { starts.append(frames - window) }
        for start in starts {
            let m = try mic.read(from: start, count: min(window, frames - start))
            let r = try system.read(from: start, count: min(window, frames - start))
            if meanPower(r) >= 1e-7, let lag = peakLag(mic: m, reference: r, fft: fft, lowest: lowest, highest: highest)
            {
                points.append(LagPoint(seconds: Double(start + m.count / 2) / Double(sampleRate), lag: lag))
            }
        }
        return points
    }

    /// The strongest tap of a whitened cross-correlation, if it's clear. Speech over
    /// speech gives a low, unreliable peak, and no echo gives none.
    static func peakLag(mic: [Double], reference: [Double], fft: RealFFT, lowest: Int, highest: Int) -> Int? {
        var spectrum = fft.crossSpectrum(of: mic, with: reference)
        spectrum.whiten()
        let c = fft.inverse(spectrum)
        guard highest <= c.count else { return nil }
        var magnitudes = [Double](repeating: 0, count: highest - lowest)
        c.withUnsafeBufferPointer { p in
            vDSP_vabsD(p.baseAddress! + lowest, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
        }
        var peak = 0.0
        var index: vDSP_Length = 0
        vDSP_maxviD(magnitudes, 1, &peak, &index, vDSP_Length(magnitudes.count))
        let median = magnitudes.sorted()[magnitudes.count / 2]
        guard peak > 15 * (median + 1e-12) else { return nil }
        return lowest + Int(index)
    }

    static func medianLag(_ track: [LagPoint]) -> Int? {
        guard !track.isEmpty else { return nil }
        return track.map(\.lag).sorted()[track.count / 2]
    }

    /// How much faster the mic's clock runs, from the robust slope of the lag over time.
    /// Too short a recording can't show a drift, and a drift can't matter there.
    static func driftPPM(_ track: [LagPoint]) -> Double {
        guard track.count >= 6, let median = medianLag(track),
            let first = track.first, let last = track.last, last.seconds - first.seconds >= 60
        else { return 0 }
        let good = track.filter { abs($0.lag - median) < sampleRate / 50 }
        var slopes: [Double] = []
        for i in good.indices {
            for j in good.indices where j > i && good[j].seconds - good[i].seconds >= 60 {
                slopes.append(Double(good[j].lag - good[i].lag) / (good[j].seconds - good[i].seconds))
            }
        }
        guard !slopes.isEmpty else { return 0 }
        return slopes.sorted()[slopes.count / 2] / Double(sampleRate) * 1e6
    }

    /// Where the lag line starts, robustly, given its slope.
    static func lagAtFileStart(_ track: [LagPoint], ppm: Double) -> Int {
        let slope = ppm * 1e-6 * Double(sampleRate)
        let starts = track.map { Double($0.lag) - slope * $0.seconds }.sorted()
        return starts.isEmpty ? 0 : Int(starts[starts.count / 2])
    }

    /// More than one window off the lag line by over 20 ms. One can be a false peak.
    static func lagMoved(_ track: [LagPoint], ppm: Double) -> Bool {
        let slope = ppm * 1e-6 * Double(sampleRate)
        let start = Double(lagAtFileStart(track, ppm: ppm))
        return track.filter { abs(Double($0.lag) - start - slope * $0.seconds) > Double(sampleRate) / 50 }.count > 1
    }

    /// Samples of `x` in 10 ms frames loud enough to count as the far side talking.
    static func activeSamples(_ x: [Double]) -> Int {
        let frame = sampleRate / 100
        return stride(from: 0, to: max(x.count - frame + 1, 0), by: frame).reduce(0) { total, start in
            var power = 0.0
            x.withUnsafeBufferPointer { p in
                vDSP_measqvD(p.baseAddress! + start, 1, &power, vDSP_Length(frame))
            }
            return power >= 1e-6 ? total + frame : total
        }
    }

    // MARK: - Least squares

    private static func fitAndSubtract(
        mic: MonoReader, reference: WarpedReference, frames: Int,
        emit: (_ mic: [Double], _ estimate: [Double]) throws -> Void
    ) throws {
        let window = Int(fitWindowSeconds * Double(sampleRate))
        let hop = Int(fitHopSeconds * Double(sampleRate))
        let taps = filterTaps
        let fft = RealFFT(atLeast: max(window + taps, 2 * hop + 2 * taps))
        // Hann over two hops sums to one, except at the very start and end.
        let fade = hann(2 * hop)
        var filter: RealFFT.Spectrum?
        var estimate = [Double](repeating: 0, count: 2 * hop)
        var weight = [Double](repeating: 0, count: 2 * hop)

        var centre = 0
        while centre < frames {
            let a = max(centre - window / 2, 0)
            let b = min(centre + window / 2, frames)
            let x = try reference.read(from: a, count: b - a)
            if activeSamples(x) >= Int(minimumActiveSeconds * Double(sampleRate)) {
                let y = try mic.read(from: a, count: b - a)
                if let taps = solveFilter(x: x, y: y, taps: taps, fft: fft) {
                    filter = fft.forward(taps)
                }
            }
            let base = centre - hop
            let start = max(base, 0)
            let end = min(centre + hop, frames)
            if let filter {
                let context = max(start - taps, 0)
                let input = try reference.read(from: context, count: end - context)
                let output = fft.inverse(fft.forward(input).multiplied(by: filter))
                for i in start..<end {
                    estimate[i - base] += fade[i - base] * output[i - context]
                }
            }
            for i in start..<end { weight[i - base] += fade[i - base] }

            // The first hop of this span now has every window that reaches it.
            let doneEnd = min(centre, frames)
            if doneEnd > start {
                let chunk = try mic.read(from: start, count: doneEnd - start)
                try emit(chunk, normalised(estimate, weight, offset: start - base, count: doneEnd - start))
            }
            estimate.replaceSubrange(0..<hop, with: estimate[hop..<(2 * hop)])
            weight.replaceSubrange(0..<hop, with: weight[hop..<(2 * hop)])
            for i in hop..<(2 * hop) {
                estimate[i] = 0
                weight[i] = 0
            }
            centre += hop
        }
        // What the last window alone reached.
        let last = centre - hop
        let tailEnd = min(centre, frames)
        if tailEnd > last {
            let chunk = try mic.read(from: last, count: tailEnd - last)
            try emit(chunk, normalised(estimate, weight, offset: 0, count: tailEnd - last))
        }
    }

    private static func normalised(_ values: [Double], _ weight: [Double], offset: Int, count: Int) -> [Double] {
        // The crossfade's weight reaches almost zero at the very end, where the estimate
        // has shrunk by the same factor, so only an exact zero needs guarding.
        (0..<count).map { weight[offset + $0] > 1e-12 ? values[offset + $0] / weight[offset + $0] : 0 }
    }

    /// The FIR filter that best turns x into y, by the normal equations.
    static func solveFilter(x: [Double], y: [Double], taps: Int, fft: RealFFT) -> [Double]? {
        let spectrumX = fft.forward(x)
        let spectrumY = fft.forward(y)
        var rxx = Array(fft.inverse(spectrumX.correlated(with: spectrumX))[0..<taps])
        let rxy = Array(fft.inverse(spectrumY.correlated(with: spectrumX))[0..<taps])
        guard rxx[0] > 0 else { return nil }
        rxx[0] *= 1 + 1e-4
        return levinson(autocorrelation: rxx, crossCorrelation: rxy)
    }

    /// Solves a symmetric Toeplitz system in O(n²). The inner steps are vector calls, so
    /// even a debug build stays quick. Doubles on purpose: in Float it loses about 10 dB.
    static func levinson(autocorrelation r: [Double], crossCorrelation b: [Double]) -> [Double]? {
        let n = r.count
        guard n > 0, b.count == n, r[0] > 0 else { return nil }
        var a = [Double](repeating: 0, count: n)
        var scratch = [Double](repeating: 0, count: n)
        var w = [Double](repeating: 0, count: n)
        a[0] = 1
        w[0] = b[0] / r[0]
        var e = r[0]
        for k in 1..<max(n, 1) {
            var lambda = 0.0
            r.withUnsafeBufferPointer { p in
                vDSP_dotprD(a, 1, p.baseAddress! + k, -1, &lambda, vDSP_Length(k))
            }
            var reflection = -lambda / e
            a.withUnsafeBufferPointer { p in
                vDSP_vsmaD(p.baseAddress! + k, -1, &reflection, p.baseAddress!, 1, &scratch, 1, vDSP_Length(k + 1))
            }
            swap(&a, &scratch)
            e *= 1 - reflection * reflection
            guard e > 0 else { return nil }

            var estimate = 0.0
            r.withUnsafeBufferPointer { p in
                vDSP_dotprD(w, 1, p.baseAddress! + k, -1, &estimate, vDSP_Length(k))
            }
            var mu = (b[k] - estimate) / e
            a.withUnsafeBufferPointer { p in
                w.withUnsafeMutableBufferPointer { q in
                    vDSP_vsmaD(p.baseAddress! + k, -1, &mu, q.baseAddress!, 1, q.baseAddress!, 1, vDSP_Length(k + 1))
                }
            }
        }
        return w
    }

    static func meanPower(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        var result = 0.0
        vDSP_measqvD(x, 1, &result, vDSP_Length(x.count))
        return result
    }

    static func hann(_ count: Int) -> [Double] {
        (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(count)) }
    }
}

// MARK: - Evidence for labels

/// What the canceller did to each 10 ms, so a line can be judged by delay and level and
/// never by its words. A line under `You` is echo if the canceller took it down a long
/// way, and what's left barely clears the room. A repeat spoken while the far side is
/// quiet loses nothing, so it can't match, and a voice over the far side stays far above
/// the room, so that can't either.
///
/// Measured on `main-3` and `main-2`: real speech stays 25 dB or more above the room, with
/// almost no drop. Talking over the far side also shows a large drop, so only level protects
/// a soft speaker. The ceiling therefore follows this recording's own voice, measured while
/// the far side is silent: a line within 10 dB of that voice is kept, even if that leaves
/// some echo in. A speaker who is much softer in one line than in the rest is still unsure,
/// and so is one who never speaks alone. Quiet noise on its own isn't touched, per D-56.
struct EchoEvidence {
    static let frameSeconds = 0.01
    static let minimumDrop: Float = 10
    static let echoCeilingAboveRoom: Float = 15
    static let voiceMargin: Float = 10

    let micDB: [Float]
    let cleanDB: [Float]
    let roomDB: Float
    /// The user's loudest fifth while the far side is silent, or nil if they hardly spoke alone.
    var voiceDB: Float?

    var ceilingAboveRoom: Float {
        guard let voiceDB else { return Self.echoCeilingAboveRoom }
        return min(Self.echoCeilingAboveRoom, voiceDB - roomDB - Self.voiceMargin)
    }

    func looksLikeEcho(start: Double, end: Double) -> Bool {
        let count = min(micDB.count, cleanDB.count)
        let first = max(Int(start / Self.frameSeconds), 0)
        let last = min(Int(end / Self.frameSeconds) + 1, count)
        guard last > first else { return false }
        // A segment can hold long silences, so each measure uses the line's loudest fifth.
        // Level goes by the cleaned track, which a voice keeps and an echo doesn't. Drop
        // goes by the mic, because once an echo is cleaned below the room, the cleaned
        // track's loudest frames are the pauses, which lost nothing.
        let fifth = max((last - first) / 5, 1)
        let frames = first..<last
        // Level is a mean of power, so one real word in a long line still counts.
        let loudest = frames.sorted { cleanDB[$0] > cleanDB[$1] }.prefix(fifth)
        let level = 10 * log10(mean(loudest) { pow(10, cleanDB[$0] / 10) })
        let drop = mean(frames.sorted { micDB[$0] > micDB[$1] }.prefix(fifth)) { micDB[$0] - cleanDB[$0] }
        return drop >= Self.minimumDrop && level - roomDB < ceilingAboveRoom
    }

    private func mean(_ indices: ArraySlice<Int>, _ value: (Int) -> Float) -> Float {
        indices.reduce(Float(0)) { $0 + value($1) } / Float(indices.count)
    }
}

struct EvidenceBuilder {
    private let frame = Int(EchoEvidence.frameSeconds * Double(EchoRemover.sampleRate))
    private var micSum = 0.0
    private var estimateSum = 0.0
    private var filled = 0
    private var micPower: [Float] = []
    private var estimatePower: [Float] = []

    mutating func add(mic: [Double], estimate: [Double]) {
        for i in mic.indices {
            micSum += mic[i] * mic[i]
            estimateSum += estimate[i] * estimate[i]
            filled += 1
            if filled == frame {
                micPower.append(Float(micSum / Double(frame)))
                estimatePower.append(Float(estimateSum / Double(frame)))
                micSum = 0
                estimateSum = 0
                filled = 0
            }
        }
    }

    func build(cleanPower: [Float]) -> EchoEvidence {
        let quiet = zip(micPower, estimatePower).compactMap { $1 < 1e-7 && $0 > 0 ? $0 : nil }
        let room: Float
        if quiet.count >= 50 {
            room = quiet.sorted()[quiet.count / 4]
        } else {
            let heard = micPower.filter { $0 > 0 }.sorted()
            room = heard.isEmpty ? 1e-12 : heard[heard.count / 20]
        }
        // At least a second of the mic clearly above the room with no far side to explain it.
        let alone = zip(micPower, estimatePower).compactMap { $1 < 1e-7 && $0 > room * 10 ? $0 : nil }.sorted()
        let voice = alone.count >= 100 ? alone.suffix(alone.count / 5).map(decibels) : []
        return EchoEvidence(
            micDB: micPower.map(decibels), cleanDB: cleanPower.map(decibels), roomDB: decibels(room),
            voiceDB: voice.isEmpty ? nil : voice.reduce(0, +) / Float(voice.count))
    }

    private func decibels(_ power: Float) -> Float { 10 * log10(max(power, 1e-12)) }
}

// MARK: - Residual suppression

/// One frame at a time, keeping only the smoothing state.
final class ResidualSuppressor {
    private static let size = 1024
    private static let hop = 512
    private static let bins = size / 2 + 1

    private let writer: MonoWriter
    private let fft = RealFFT(atLeast: size)
    private let window: [Double] = EchoRemover.hann(size).map { $0.squareRoot() }
    private let floorGain = pow(10, EchoRemover.gainFloorDB / 20)

    private var errorInput: [Double] = []
    private var estimateInput: [Double] = []
    private var overlap = [Double](repeating: 0, count: ResidualSuppressor.size)
    private var crossRe = [Double](repeating: 0, count: bins)
    private var crossIm = [Double](repeating: 0, count: bins)
    private var errorSmooth = [Double](repeating: 0, count: bins)
    private var estimateSmooth = [Double](repeating: 0, count: bins)
    private var errorFast = [Double](repeating: 0, count: bins)
    private var tail = [Double](repeating: 0, count: bins)
    private var written = 0
    private var limit = Int.max
    private var powerSum = 0.0
    private var powerFilled = 0
    private let powerFrame = Int(EchoEvidence.frameSeconds * Double(EchoRemover.sampleRate))
    private(set) var cleanPower: [Float] = []

    init(writer: MonoWriter) { self.writer = writer }

    func push(error: [Double], estimate: [Double]) throws {
        errorInput += error
        estimateInput += estimate
        var used = 0
        while errorInput.count - used >= Self.size {
            try runFrame(at: used)
            used += Self.hop
        }
        errorInput.removeFirst(used)
        estimateInput.removeFirst(used)
    }

    /// Pads out the last frame, and writes exactly as many frames as went in.
    func finish(totalFrames: Int) throws {
        limit = totalFrames
        let padding = [Double](repeating: 0, count: Self.size)
        try push(error: padding, estimate: padding)
        if written < totalFrames {
            try write(Array(overlap.prefix(totalFrames - written)))
        }
    }

    private func runFrame(at start: Int) throws {
        let n = Self.size
        var e = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        errorInput.withUnsafeBufferPointer { p in
            vDSP_vmulD(p.baseAddress! + start, 1, window, 1, &e, 1, vDSP_Length(n))
        }
        estimateInput.withUnsafeBufferPointer { p in
            vDSP_vmulD(p.baseAddress! + start, 1, window, 1, &d, 1, vDSP_Length(n))
        }
        var errorSpectrum = fft.forward(e)
        let estimateSpectrum = fft.forward(d)
        let gains = updateGains(error: errorSpectrum, estimate: estimateSpectrum)
        errorSpectrum.applyGains(gains)
        let y = fft.inverse(errorSpectrum)
        for i in 0..<n { overlap[i] += y[i] * window[i] }
        try write(Array(overlap[0..<Self.hop]))
        overlap.replaceSubrange(0..<Self.hop, with: overlap[Self.hop..<n])
        for i in Self.hop..<n { overlap[i] = 0 }
    }

    /// How much of what's left the echo estimate explains, per bin. See `EchoRemover`.
    private func updateGains(error: RealFFT.Spectrum, estimate: RealFFT.Spectrum) -> [Double] {
        var gains = [Double](repeating: 1, count: Self.bins)
        for k in 0..<Self.bins {
            let er = error.real(at: k)
            let ei = error.imaginary(at: k)
            let dr = estimate.real(at: k)
            let di = estimate.imaginary(at: k)
            let pe = er * er + ei * ei
            let pd = dr * dr + di * di
            crossRe[k] = 0.9 * crossRe[k] + 0.1 * (er * dr + ei * di)
            crossIm[k] = 0.9 * crossIm[k] + 0.1 * (ei * dr - er * di)
            errorSmooth[k] = 0.9 * errorSmooth[k] + 0.1 * pe
            estimateSmooth[k] = 0.9 * estimateSmooth[k] + 0.1 * pd
            errorFast[k] = 0.5 * errorFast[k] + 0.5 * pe
            tail[k] = max(pd, tail[k] * 0.6)
            let cross = crossRe[k] * crossRe[k] + crossIm[k] * crossIm[k]
            let coherence = cross / (errorSmooth[k] * estimateSmooth[k] + 1e-20)
            let leak = min(cross / (estimateSmooth[k] * estimateSmooth[k] + 1e-20), 1)
            let residual = EchoRemover.overSuppression * leak * tail[k] * min(coherence * 4, 1)
            gains[k] = max(1 - residual / (errorFast[k] + 1e-20), floorGain)
        }
        return gains
    }

    private func write(_ all: [Double]) throws {
        let samples = Array(all.prefix(max(limit - written, 0)))
        for sample in samples {
            powerSum += sample * sample
            powerFilled += 1
            if powerFilled == powerFrame {
                cleanPower.append(Float(powerSum / Double(powerFrame)))
                powerSum = 0
                powerFilled = 0
            }
        }
        try writer.write(samples)
        written += samples.count
    }
}

// MARK: - Files

/// Random access to a mono file. Reads past either end are silence.
final class MonoReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let length: Int
    private static let capacity: AVAudioFrameCount = 48_000

    init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1,
            Int(file.processingFormat.sampleRate) == EchoRemover.sampleRate,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.capacity)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.buffer = buffer
        length = Int(file.length)
    }

    func read(from start: Int, count: Int) throws -> [Double] {
        var out = [Double](repeating: 0, count: max(count, 0))
        var position = max(start, 0)
        let end = min(start + count, length)
        guard position < end else { return out }
        file.framePosition = AVAudioFramePosition(position)
        while position < end {
            let want = AVAudioFrameCount(min(end - position, Int(Self.capacity)))
            try file.read(into: buffer, frameCount: want)
            let got = Int(buffer.frameLength)
            guard got > 0, let samples = buffer.floatChannelData?[0] else { break }
            out.withUnsafeMutableBufferPointer { p in
                vDSP_vspdp(samples, 1, p.baseAddress! + (position - start), 1, vDSP_Length(got))
            }
            position += got
        }
        return out
    }
}

/// The system track on the mic's clock, delayed so the echo falls inside the filter.
final class WarpedReference {
    private let reader: MonoReader
    private let rate: Double
    private let shift: Int

    init(reader: MonoReader, ppm: Double, shift: Int) throws {
        self.reader = reader
        rate = 1 - ppm * 1e-6
        self.shift = shift
    }

    func read(from start: Int, count: Int) throws -> [Double] {
        guard count > 0 else { return [] }
        let first = start - shift
        if rate == 1 { return try reader.read(from: first, count: count) }
        let low = Int((Double(first) * rate).rounded(.down)) - 1
        let high = Int((Double(first + count) * rate).rounded(.down)) + 3
        let source = try reader.read(from: low, count: high - low)
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(first + i) * rate
            let whole = t.rounded(.down)
            let f = t - whole
            let at = Int(whole) - low
            guard at >= 1, at + 2 < source.count else { continue }
            let a = source[at - 1]
            let b = source[at]
            let c = source[at + 1]
            let d = source[at + 2]
            out[i] = b + 0.5 * f * (c - a + f * (2 * a - 5 * b + 4 * c - d + f * (3 * (b - c) + d - a)))
        }
        return out
    }
}

final class MonoWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat

    init(_ url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: EchoRemover.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        format = file.processingFormat
    }

    func write(_ samples: [Double]) throws {
        guard let file, !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let out = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        vDSP_vdpsp(samples, 1, out, 1, vDSP_Length(samples.count))
        try file.write(from: buffer)
    }

    func close() { file = nil }
}

// MARK: - FFT

/// A real FFT of a fixed size in doubles, padding shorter input with zeros.
final class RealFFT {
    /// vDSP's packed form: index 0 holds DC in `re` and Nyquist in `im`.
    struct Spectrum {
        var re: [Double]
        var im: [Double]

        func real(at k: Int) -> Double { k == re.count ? im[0] : re[k] }
        func imaginary(at k: Int) -> Double { k == 0 || k == re.count ? 0 : im[k] }

        /// self × other.
        func multiplied(by other: Spectrum) -> Spectrum { combine(other, conjugate: false) }
        /// self × conj(other). vDSP conjugates its first argument, hence the swap.
        func correlated(with other: Spectrum) -> Spectrum { other.combine(self, conjugate: true) }

        private func combine(_ o: Spectrum, conjugate: Bool) -> Spectrum {
            var out = Spectrum(re: re, im: im)
            let count = vDSP_Length(re.count)
            let flag: Int32 = conjugate ? -1 : 1
            re.withUnsafeBufferPointer { ar in
                im.withUnsafeBufferPointer { ai in
                    o.re.withUnsafeBufferPointer { br in
                        o.im.withUnsafeBufferPointer { bi in
                            out.re.withUnsafeMutableBufferPointer { cr in
                                out.im.withUnsafeMutableBufferPointer { ci in
                                    var a = DSPDoubleSplitComplex(
                                        realp: UnsafeMutablePointer(mutating: ar.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: ai.baseAddress!))
                                    var b = DSPDoubleSplitComplex(
                                        realp: UnsafeMutablePointer(mutating: br.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: bi.baseAddress!))
                                    var c = DSPDoubleSplitComplex(realp: cr.baseAddress!, imagp: ci.baseAddress!)
                                    vDSP_zvmulD(&a, 1, &b, 1, &c, 1, count, flag)
                                }
                            }
                        }
                    }
                }
            }
            out.re[0] = re[0] * o.re[0]
            out.im[0] = im[0] * o.im[0]
            return out
        }

        mutating func whiten() {
            let n = re.count
            var magnitude = [Double](repeating: 0, count: n)
            vDSP_vdistD(re, 1, im, 1, &magnitude, 1, vDSP_Length(n))
            var peak = 0.0
            vDSP_maxvD(magnitude, 1, &peak, vDSP_Length(n))
            let floor = 1e-9 * peak + 1e-30
            for k in 0..<n {
                let divisor = magnitude[k] + floor
                re[k] /= divisor
                im[k] /= divisor
            }
        }

        mutating func applyGains(_ gains: [Double]) {
            let half = re.count
            re[0] *= gains[0]
            im[0] *= gains[half]
            for k in 1..<half {
                re[k] *= gains[k]
                im[k] *= gains[k]
            }
        }
    }

    let size: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetupD

    init(atLeast minimum: Int) {
        var power: vDSP_Length = 1
        while (1 << power) < minimum { power += 1 }
        log2Size = power
        size = 1 << power
        setup = vDSP_create_fftsetupD(power, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    func forward(_ input: [Double]) -> Spectrum {
        var padded = [Double](repeating: 0, count: size)
        padded.replaceSubrange(0..<min(input.count, size), with: input.prefix(size))
        var out = Spectrum(
            re: [Double](repeating: 0, count: size / 2), im: [Double](repeating: 0, count: size / 2))
        out.re.withUnsafeMutableBufferPointer { re in
            out.im.withUnsafeMutableBufferPointer { im in
                var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctozD(
                        raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zripD(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Forward))
            }
        }
        // vDSP's forward is twice the true transform.
        RealFFT.scale(&out.re, by: 0.5)
        RealFFT.scale(&out.im, by: 0.5)
        return out
    }

    func inverse(_ spectrum: Spectrum) -> [Double] {
        var re = spectrum.re
        var im = spectrum.im
        var out = [Double](repeating: 0, count: size)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zripD(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztocD(
                        &split, 1, raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, vDSP_Length(size / 2))
                }
            }
        }
        // vDSP's inverse of the true transform comes out multiplied by the size.
        RealFFT.scale(&out, by: 1 / Double(size))
        return out
    }

    static func scale(_ values: inout [Double], by factor: Double) {
        var factor = factor
        let count = vDSP_Length(values.count)
        values.withUnsafeMutableBufferPointer { p in
            vDSP_vsmulD(p.baseAddress!, 1, &factor, p.baseAddress!, 1, count)
        }
    }

    func crossSpectrum(of y: [Double], with x: [Double]) -> Spectrum {
        forward(y).correlated(with: forward(x))
    }
}
