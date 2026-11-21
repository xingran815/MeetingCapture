import Accelerate
import Foundation

// MARK: - Residual suppression (issue 31)

/// What the linear stage leaves still holds some echo. This takes it off per frequency bin,
/// after the call, with the whole file in view:
///
///   - Classical gain: the residual is a per-bin share (`beta`) of the echo estimate's power,
///     measured on this file's echo-heavy frames, times a soft per-frame "is the user
///     talking" weight that looks four frames ahead. Tuned on the AEC-Challenge dev clips to
///     keep the user's voice (`VOICE_SAFE` in `scripts/aec-bench/res_lab.py`).
///   - Neural mask: a small GRU (`EchoSuppressorWeights`) trained on public AEC-Challenge
///     clips. It covers `EchoSuppressorWeights.bins` bins from 0 Hz; full-band weights cover
///     all 513 (0-24 kHz), and weights that stop lower repeat their top band's mean above.
///   - The gain is the geometric mean of the two, and comfort noise fills each bin back up to
///     the room's steady noise, so the background doesn't pump with the far side.
///
/// The shipped weights (D-107) learned from synthetic 48 kHz clips, the 16 kHz challenge clips
/// and real 48 kHz PC calls whose tracks carry sound above 8 kHz, with taking the user's voice
/// away weighted 8 times.
///
/// Unsure: one training seed of three; the others removed as much echo but degraded real
/// double talk a little more. The bench is 10 s clips and 10 real sessions; the M3.2 takes and
/// one real call are the only whole calls of the user's tried.
///
/// The linear stage waits in a temp file between the passes (about 345 MB for a 30-minute
/// part); memory stays at a few histograms and one frame.
enum EchoSuppressor {
    static let size = 1024
    static let hop = 512
    static let bins = size / 2 + 1

    // The classical gain (VOICE_SAFE, chosen on the dev clips).
    static let betaPercentile = 45.61
    static let strongPercentile = 70.0
    static let noisePercentile = 10.0
    static let overSubtraction = 1.6
    static let presenceCentreDB = -1.62
    static let presenceSlope = 0.95
    static let presenceRelease = 0.96
    static let frameFloorDB = -21.27
    static let binFloorDB = -22.31
    static let tailDecay = 0.68
    static let lookAheadFrames = 4
    static let smearBins = 2
    static let gainRelease = 0.5
    /// 330-4,000 Hz at 48 kHz, where a voice's presence shows.
    static let presenceBand = 7..<86

    /// Runs every pass, writes the cleaned mic, and returns its power per evidence frame.
    static func run(stage: LinearStageFile, writer: MonoWriter) throws -> [Float] {
        let stats = try statistics(stage)
        let presence = try presence(stage, stats)
        return try apply(stage, stats, presence: presence, writer: writer)
    }

    struct Statistics {
        var noise: [Double]
        var beta: [Double]
    }

    /// Pass 1: room noise and the echo estimate's strong level per bin. Pass 2: the share of
    /// the estimate that stays in the error on those strong frames.
    static func statistics(_ stage: LinearStageFile) throws -> Statistics {
        var errorLevels = LogHistogram(channels: bins)
        var estimateLevels = LogHistogram(channels: bins)
        try stage.forEachFrame { pe, pd in
            for k in 0..<bins {
                errorLevels.add(k, pe[k])
                estimateLevels.add(k, pd[k])
            }
        }
        let noise = (0..<bins).map { errorLevels.percentile($0, noisePercentile) }
        let strong = (0..<bins).map { estimateLevels.percentile($0, strongPercentile) }

        var ratios = LogHistogram(channels: bins)
        var strongCount = [Int](repeating: 0, count: bins)
        var strongSum = [Double](repeating: 0, count: bins)
        try stage.forEachFrame { pe, pd in
            for k in 0..<bins where pd[k] > strong[k] {
                ratios.add(k, pe[k] / (pd[k] + 1e-20))
                strongCount[k] += 1
                strongSum[k] += pd[k]
            }
        }
        let beta = (0..<bins).map { k -> Double in
            guard strongCount[k] >= 10, strongSum[k] / Double(strongCount[k]) > 1e-12 else { return 1e-2 }
            return min(max(ratios.percentile(k, betaPercentile), 1e-4), 4)
        }
        return Statistics(noise: noise, beta: beta)
    }

    /// The residual's running state, shared by pass 3 and pass 4 so both see the same numbers.
    struct Residual {
        private var tail = [Double](repeating: 0, count: bins)
        private var errorFast = [Double](repeating: 0, count: bins)
        private(set) var smeared = [Double](repeating: 0, count: bins)
        private(set) var binGains = [Double](repeating: 1, count: bins)
        private var raw = [Double](repeating: 0, count: bins)

        mutating func update(_ pe: [Double], _ pd: [Double], beta: [Double]) {
            for k in 0..<bins {
                tail[k] = max(pd[k], tail[k] * tailDecay)
                raw[k] = beta[k] * tail[k]
                errorFast[k] = 0.5 * errorFast[k] + 0.5 * pe[k]
            }
            let floor = pow(10, binFloorDB / 20)
            for k in 0..<bins {
                var top = raw[k]
                for j in max(k - smearBins, 0)...min(k + smearBins, bins - 1) { top = max(top, raw[j]) }
                smeared[k] = top
                binGains[k] = max(1 - overSubtraction * top / (errorFast[k] + 1e-20), floor)
            }
        }
    }

    /// Pass 3: per frame, how likely the user is talking: what's left beyond the residual and
    /// the room, against the two, on a soft curve. Then the most of the next few frames, so a
    /// word's onset isn't cut.
    static func presence(_ stage: LinearStageFile, _ stats: Statistics) throws -> [Double] {
        var residual = Residual()
        var raw: [Double] = []
        let noise = stats.noise.map { $0 + 1e-14 }
        let noiseInBand = presenceBand.reduce(0) { $0 + noise[$1] }
        try stage.forEachFrame { pe, pd in
            residual.update(pe, pd, beta: stats.beta)
            var echo = 0.0
            var left = 0.0
            for k in presenceBand {
                echo += residual.smeared[k]
                left += max(pe[k] - residual.smeared[k] - noise[k], 0)
            }
            if echo < noiseInBand {
                raw.append(1)
            } else {
                let snr = 10 * log10(left / (echo + noiseInBand) + 1e-6)
                raw.append(1 / (1 + exp(-presenceSlope * (snr - presenceCentreDB))))
            }
        }
        return raw.indices.map { t in raw[t...min(t + lookAheadFrames, raw.count - 1)].max()! }
    }

    /// Pass 4: the blended gain, comfort noise, and the cleaned mic.
    static func apply(_ stage: LinearStageFile, _ stats: Statistics, presence: [Double], writer: MonoWriter)
        throws -> [Float]
    {
        var residual = Residual()
        var network = NeuralMask()
        var noisePhase = SplitMix64(seed: 0)
        var output = OverlapAdd(writer: writer, limit: stage.frames)
        let frameFloor = pow(10, frameFloorDB / 20)
        var previous = [Double](repeating: 1, count: bins)
        var level = 1.0
        var gains = [Double](repeating: 1, count: bins)
        var t = 0
        try stage.forEachSpectrum { error, pe, pd in
            residual.update(pe, pd, beta: stats.beta)
            let p = presence[t]
            level = p > level ? p : presenceRelease * level + (1 - presenceRelease) * p
            let mask = network.mask(errorPower: pe, estimatePower: pd)
            for k in 0..<bins {
                var g = residual.binGains[k] * (frameFloor + (1 - frameFloor) * level)
                if g >= previous[k] { g = gainRelease * previous[k] + (1 - gainRelease) * g }
                previous[k] = g
                gains[k] = (mask[k] * g).squareRoot()
            }
            var spectrum = error
            spectrum.applyGains(gains)
            for k in 0..<bins {
                let fill = (stats.noise[k] * max(1 - gains[k] * gains[k], 0)).squareRoot()
                let phase = 2 * Double.pi * noisePhase.nextUnit()
                spectrum.add(at: k, real: fill * cos(phase), imaginary: fill * sin(phase))
            }
            try output.add(spectrum)
            t += 1
        }
        try output.finish()
        return output.cleanPower
    }
}

/// Percentiles of positive values per channel, on a log scale in 0.1 dB steps: memory stays
/// fixed however long the file. Close enough for gains; numpy's exact ones differ by a step.
struct LogHistogram {
    static let lowest = -20.0
    static let highest = 8.0
    static let step = 0.01
    static let count = Int((highest - lowest) / step)
    private var counts: [Int32]
    private var totals: [Int]

    init(channels: Int) {
        counts = [Int32](repeating: 0, count: channels * Self.count)
        totals = [Int](repeating: 0, count: channels)
    }

    mutating func add(_ channel: Int, _ value: Double) {
        let position = (log10(max(value, 1e-30)) - Self.lowest) / Self.step
        let index = min(max(Int(position), 0), Self.count - 1)
        counts[channel * Self.count + index] += 1
        totals[channel] += 1
    }

    /// numpy's linear-interpolation rank, read off at the middle of its step.
    func percentile(_ channel: Int, _ q: Double) -> Double {
        let total = totals[channel]
        guard total > 0 else { return 0 }
        let rank = Int((q / 100 * Double(total - 1)).rounded())
        var seen = 0
        for i in 0..<Self.count {
            seen += Int(counts[channel * Self.count + i])
            if seen > rank { return pow(10, Self.lowest + (Double(i) + 0.5) * Self.step) }
        }
        return pow(10, Self.highest)
    }
}

/// The linear stage's error and echo estimate, as int16 pairs in a private temp file (about
/// 345 MB for a 30-minute part), read back as windowed spectra. Deleted by `remove()`; a crash leaves it in the user's own
/// temp folder, which macOS clears.
final class LinearStageFile {
    let url: URL
    private var handle: FileHandle?
    private(set) var frames = 0
    private let fft = RealFFT(atLeast: EchoSuppressor.size)
    private let window: [Double] = EchoRemover.hann(EchoSuppressor.size).map { $0.squareRoot() }

    /// Free space left on the temp volume after the file, so a recording still being made on
    /// the same disk isn't starved by echo removal (M8 deep review).
    static let spareBytes: Int64 = 1 << 30

    /// Refuses, before writing anything, when `frames` pairs plus `spareBytes` won't fit in the
    /// space `available` reports; nil (unknown) goes ahead. Echo removal then fails, and the
    /// raw mic is transcribed with a note, as for any other failure.
    init(frames: Int, available: Int64? = LinearStageFile.availableBytes()) throws {
        if let available, available < Int64(frames) * 4 + Self.spareBytes {
            throw CocoaError(
                .fileWriteOutOfSpace,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "not enough free disk space for echo removal (\(available / 1_000_000) MB free)"
                ])
        }
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingcapture-echo-\(UUID().uuidString).s16")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        handle = try FileHandle(forUpdating: url)
    }

    deinit { remove() }

    /// Space the temp folder's volume can still give, or nil if macOS won't say.
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Both signals are rounded to 16 bits, as the lab's linear-stage dumps are (MonoWriter), so
    /// the neural mask sees the features it was trained on. Without it, a far-silent frame's
    /// estimate falls far under the int16 floor the network learned, and networks trained on
    /// real calls took 20 dB off the user's voice (issue 31). The rounding itself is at -96 dB.
    func append(error: [Double], estimate: [Double]) throws {
        guard let handle else { return }
        var pairs = [Int16](repeating: 0, count: 2 * error.count)
        for i in error.indices {
            pairs[2 * i] = Self.code(error[i])
            pairs[2 * i + 1] = Self.code(estimate[i])
        }
        try pairs.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        frames += error.count
    }

    /// A sample as an int16 WAV stores it: scaled by 32768, rounded, clipped.
    static func code(_ x: Double) -> Int16 {
        Int16(min(max((x * 32768).rounded(), -32768), 32767))
    }

    /// The value a stored code stands for, as `MonoReader` reads an int16 WAV.
    static func int16(_ x: Double) -> Float {
        Float(code(x)) / 32768
    }

    func remove() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Every frame's error and estimate power per bin, in order.
    func forEachFrame(_ body: (_ errorPower: [Double], _ estimatePower: [Double]) throws -> Void) throws {
        try forEachSpectrum { _, pe, pd in try body(pe, pd) }
    }

    /// Frames start at 0 and step by a hop until one starts past the end; the end is padded.
    func forEachSpectrum(
        _ body: (_ error: RealFFT.Spectrum, _ errorPower: [Double], _ estimatePower: [Double]) throws -> Void
    ) throws {
        guard let handle else { return }
        let size = EchoSuppressor.size
        let hop = EchoSuppressor.hop
        let total = frames / hop + 1
        let block = 64
        var e = [Double](repeating: 0, count: size)
        var d = [Double](repeating: 0, count: size)
        var t = 0
        while t < total {
            let start = t * hop
            let count = min(block, total - t)
            let wanted = (count - 1) * hop + size
            try handle.seek(toOffset: UInt64(start * 4))
            let data = try handle.read(upToCount: wanted * 4) ?? Data()
            var samples = [Int16](repeating: 0, count: 2 * wanted)
            samples.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
            for j in 0..<count {
                let o = j * hop
                for i in 0..<size {
                    e[i] = Double(samples[2 * (o + i)]) / 32768 * window[i]
                    d[i] = Double(samples[2 * (o + i) + 1]) / 32768 * window[i]
                }
                let es = fft.forward(e)
                let ds = fft.forward(d)
                try body(es, es.powers(), ds.powers())
            }
            t += count
        }
    }
}

/// Inverse STFT with the same sqrt-Hann window, written a hop at a time.
struct OverlapAdd {
    private let writer: MonoWriter
    private let limit: Int
    private let fft = RealFFT(atLeast: EchoSuppressor.size)
    private let window: [Double] = EchoRemover.hann(EchoSuppressor.size).map { $0.squareRoot() }
    private var overlap = [Double](repeating: 0, count: EchoSuppressor.size)
    private var written = 0
    private var powerSum = 0.0
    private var powerFilled = 0
    private let powerFrame = Int(EchoEvidence.frameSeconds * Double(EchoRemover.sampleRate))
    private(set) var cleanPower: [Float] = []

    init(writer: MonoWriter, limit: Int) {
        self.writer = writer
        self.limit = limit
    }

    mutating func add(_ spectrum: RealFFT.Spectrum) throws {
        let n = EchoSuppressor.size
        let hop = EchoSuppressor.hop
        let y = fft.inverse(spectrum)
        for i in 0..<n { overlap[i] += y[i] * window[i] }
        try write(Array(overlap[0..<hop]))
        overlap.replaceSubrange(0..<hop, with: overlap[hop..<n])
        for i in hop..<n { overlap[i] = 0 }
    }

    mutating func finish() throws {
        if written < limit { try write(Array(overlap.prefix(limit - written))) }
    }

    private mutating func write(_ all: [Double]) throws {
        let samples = Array(all.prefix(max(limit - written, 0)))
        guard !samples.isEmpty else { return }
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

/// Seeded, so the same recording always cleans to the same file.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension RealFFT.Spectrum {
    /// |X(k)|² for k = 0 … size/2.
    func powers() -> [Double] {
        let half = re.count
        var out = [Double](repeating: 0, count: half + 1)
        out[0] = re[0] * re[0]
        out[half] = im[0] * im[0]
        for k in 1..<half { out[k] = re[k] * re[k] + im[k] * im[k] }
        return out
    }

    /// Adds to bin k; DC and Nyquist are real, so they take only the real part.
    mutating func add(at k: Int, real: Double, imaginary: Double) {
        let half = re.count
        if k == 0 {
            re[0] += real
        } else if k == half {
            im[0] += real
        } else {
            re[k] += real
            im[k] += imaginary
        }
    }
}

// MARK: - The network

/// nres.py's NRES, frame by frame: Linear → LayerNorm → PReLU → two GRU layers → Linear →
/// sigmoid, over log powers of the first `inputBins` bins. PyTorch's GRU gate order
/// (reset, update, new) and its `r * (W_hn h + b_hn)` form.
struct NeuralMask {
    static let inputBins = EchoSuppressorWeights.bins
    static let hidden = EchoSuppressorWeights.hidden

    private static let weights: [Float] = {
        let text = EchoSuppressorWeights.base64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: text), data.count == EchoSuppressorWeights.count * 2 else {
            preconditionFailure("EchoSuppressorWeights is damaged; rerun scripts/aec-bench/export_nres.py")
        }
        var out = [Float](repeating: 0, count: EchoSuppressorWeights.count)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1,
                    width: vImagePixelCount(EchoSuppressorWeights.count), rowBytes: data.count)
                var target = vImage_Buffer(
                    data: dst.baseAddress!, height: 1, width: vImagePixelCount(EchoSuppressorWeights.count),
                    rowBytes: dst.count)
                let error = vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                precondition(error == kvImageNoError, "EchoSuppressorWeights didn't decode (\(error))")
            }
        }
        return out
    }()

    private struct Layout {
        var offset = 0
        mutating func take(_ count: Int) -> Range<Int> {
            defer { offset += count }
            return offset..<(offset + count)
        }
    }

    private let inputWeight, inputBias, normScale, normBias, slope: Range<Int>
    private let gru: [(ih: Range<Int>, hh: Range<Int>, bih: Range<Int>, bhh: Range<Int>)]
    private let outWeight, outBias: Range<Int>
    private var state: [[Float]]

    init() {
        let h = Self.hidden
        let features = 3 * Self.inputBins
        var layout = Layout()
        inputWeight = layout.take(h * features)
        inputBias = layout.take(h)
        normScale = layout.take(h)
        normBias = layout.take(h)
        slope = layout.take(1)
        gru = (0..<2).map { _ in
            (layout.take(3 * h * h), layout.take(3 * h * h), layout.take(3 * h), layout.take(3 * h))
        }
        outWeight = layout.take(Self.inputBins * h)
        outBias = layout.take(Self.inputBins)
        precondition(layout.offset == EchoSuppressorWeights.count, "EchoSuppressorWeights doesn't fit NRES")
        state = [[Float](repeating: 0, count: h), [Float](repeating: 0, count: h)]
    }

    /// The mask for every bin of one frame; above the network's bins, the mean of its top 20.
    mutating func mask(errorPower pe: [Double], estimatePower pd: [Double]) -> [Double] {
        let n = Self.inputBins
        var x = [Float](repeating: 0, count: 3 * n)
        for k in 0..<n {
            let le = Float((log(pe[k] + 1e-10) + 12) / 6)
            let ld = Float((log(pd[k] + 1e-10) + 12) / 6)
            x[k] = le
            x[n + k] = ld
            x[2 * n + k] = le - ld
        }
        var a = linear(inputWeight, inputBias, x, rows: Self.hidden)
        layerNorm(&a)
        let s = Self.weights[slope.lowerBound]
        for i in a.indices where a[i] < 0 { a[i] *= s }
        for layer in 0..<2 { a = gruStep(layer, a) }
        let logits = linear(outWeight, outBias, a, rows: n)
        var out = [Double](repeating: 0, count: EchoSuppressor.bins)
        for k in 0..<n { out[k] = 1 / (1 + exp(-Double(logits[k]))) }
        let top = out[(n - 20)..<n].reduce(0, +) / 20
        for k in n..<EchoSuppressor.bins { out[k] = top }
        return out
    }

    private func linear(_ w: Range<Int>, _ b: Range<Int>, _ x: [Float], rows: Int) -> [Float] {
        var y = [Float](repeating: 0, count: rows)
        Self.weights.withUnsafeBufferPointer { p in
            vDSP_mmul(p.baseAddress! + w.lowerBound, 1, x, 1, &y, 1, vDSP_Length(rows), 1, vDSP_Length(x.count))
            vDSP_vadd(y, 1, p.baseAddress! + b.lowerBound, 1, &y, 1, vDSP_Length(rows))
        }
        return y
    }

    private func layerNorm(_ a: inout [Float]) {
        let n = Float(a.count)
        let mean = a.reduce(0, +) / n
        let variance = a.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let scale = 1 / (variance + 1e-5).squareRoot()
        for i in a.indices {
            a[i] =
                (a[i] - mean) * scale * Self.weights[normScale.lowerBound + i] + Self.weights[normBias.lowerBound + i]
        }
    }

    private mutating func gruStep(_ layer: Int, _ x: [Float]) -> [Float] {
        let h = Self.hidden
        let g = gru[layer]
        let gi = linear(g.ih, g.bih, x, rows: 3 * h)
        let gh = linear(g.hh, g.bhh, state[layer], rows: 3 * h)
        var next = [Float](repeating: 0, count: h)
        for i in 0..<h {
            let r = 1 / (1 + exp(-(gi[i] + gh[i])))
            let z = 1 / (1 + exp(-(gi[h + i] + gh[h + i])))
            let n = tanh(gi[2 * h + i] + r * gh[2 * h + i])
            next[i] = (1 - z) * n + z * state[layer][i]
        }
        state[layer] = next
        return next
    }
}
