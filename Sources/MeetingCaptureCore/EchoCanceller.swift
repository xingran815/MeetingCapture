import Foundation
import AVFoundation
import Speexdsp

// Real-time acoustic echo canceller wrapping speexdsp's MDF echo canceller.
//
// Sits between MicCapture and MixingWriter:
//
//   SCStream ──► AudioCapture ─► (a) MixingWriter (system channel)
//                           └─► (b) EchoCanceller.pushReference
//
//   AVAudioEngine ► MicCapture ─► EchoCanceller.pushMic
//                                          │
//                                onCleanMic ▼
//                                   MixingWriter (clean mic)
//
// Why software AEC instead of Apple's AVAudioEngine voice-processing? VPIO
// switches the audio HAL into "voice chat" mode, which ducks output and
// claims the mic exclusively — Zoom (or any concurrent VoIP app) can't
// capture audio while we record. Speex runs entirely in user-space against
// our own sample buffers, so it doesn't touch the HAL session.
//
// Threading: pushReference and pushMic may be called concurrently from
// different capture queues. All buffer mutation and processing is serialized
// onto an internal serial queue. The onCleanMic callback fires on that queue.
//
// Alignment: this first cut relies on Speex's adaptive delay tracker
// (robust to ~75 ms of initial offset) rather than explicit timestamp
// alignment between SCStream's CMSampleBuffer PTS and AVAudioEngine's
// AVAudioTime. AVAudioEngine input typically starts within tens of ms of
// SCStream, well inside Speex's tracking range. If real recordings show
// unconvergent residual in the first ~500 ms, add timestamp anchoring.
final class EchoCanceller {

    // 10 ms frames at 48 kHz.
    static let frameSize: Int = 480
    static let sampleRate: Int = 48_000

    // 150 ms tail covers typical speaker→mic round-trip + processing latency
    // for built-in mac speakers and mic. Longer tail = more CPU and slower
    // convergence for marginal cancellation benefit.
    static let tailMs: Int = 150
    static let tailSamples: Int = sampleRate * tailMs / 1000

    // Cap each ring buffer at 1 s. Past that, we're losing sync — drop oldest
    // to bound memory and let Speex re-converge on fresher data.
    private static let maxBufferedSamples: Int = sampleRate

    var onCleanMic: ((UnsafePointer<Float>, Int) -> Void)?

    private var echoState: OpaquePointer?
    private var preprocessState: OpaquePointer?

    // Mono ring buffers. Reference = downmixed system audio, mic = mono mic.
    private var refBuf: [Float] = []
    private var micBuf: [Float] = []

    // Reusable int16 scratch buffers for the Speex C API.
    private var refI16 = [Int16](repeating: 0, count: frameSize)
    private var micI16 = [Int16](repeating: 0, count: frameSize)
    private var outI16 = [Int16](repeating: 0, count: frameSize)
    private var outF32 = [Float](repeating: 0, count: frameSize)

    private let queue = DispatchQueue(label: "EchoCanceller.serial")

    init() {
        echoState = speex_echo_state_init(Int32(Self.frameSize), Int32(Self.tailSamples))
        preprocessState = speex_preprocess_state_init(Int32(Self.frameSize), Int32(Self.sampleRate))

        // Tell the preprocessor about the echo state so it can do residual-echo
        // suppression on top of the MDF's primary cancellation.
        if let es = echoState {
            _ = speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(es))
        }
        // Enable noise suppression — helps with mic self-noise and very small
        // residual echoes the MDF doesn't catch. AGC stays off (default) to
        // avoid pumping artifacts on the mic.
        var on: Int32 = 1
        _ = withUnsafeMutablePointer(to: &on) {
            speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_DENOISE, UnsafeMutableRawPointer($0))
        }
    }

    deinit {
        if let preprocessState { speex_preprocess_state_destroy(preprocessState) }
        if let echoState { speex_echo_state_destroy(echoState) }
    }

    // MARK: - Push

    // System audio (interleaved stereo float32 at 48 kHz from SCStream).
    func pushReference(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.isInterleaved,
              buffer.format.channelCount == 2,
              let src = buffer.floatChannelData?[0]
        else { return }

        let frames = Int(buffer.frameLength)
        // Downmix to mono on the caller's queue while the buffer is live;
        // the Speex queue only sees a fresh [Float].
        var mono = [Float](repeating: 0, count: frames)
        for i in 0 ..< frames {
            mono[i] = (src[2 * i] + src[2 * i + 1]) * 0.5
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.refBuf.append(contentsOf: mono)
            if self.refBuf.count > Self.maxBufferedSamples {
                self.refBuf.removeFirst(self.refBuf.count - Self.maxBufferedSamples)
            }
            self.process()
        }
    }

    // Mono mic samples at 48 kHz.
    func pushMic(_ samples: UnsafePointer<Float>, frameCount: Int) {
        let copy = Array(UnsafeBufferPointer(start: samples, count: frameCount))
        queue.async { [weak self] in
            guard let self else { return }
            self.micBuf.append(contentsOf: copy)
            if self.micBuf.count > Self.maxBufferedSamples {
                self.micBuf.removeFirst(self.micBuf.count - Self.maxBufferedSamples)
            }
            self.process()
        }
    }

    // MARK: - Process

    // Pulls matched mic+ref frames out of the ring buffers and runs them
    // through Speex. Called on `queue`.
    private func process() {
        let n = Self.frameSize
        while micBuf.count >= n && refBuf.count >= n {
            // Convert to int16 (Speex's native format).
            for i in 0 ..< n {
                micI16[i] = Self.floatToInt16(micBuf[i])
                refI16[i] = Self.floatToInt16(refBuf[i])
            }
            micBuf.removeFirst(n)
            refBuf.removeFirst(n)

            micI16.withUnsafeBufferPointer { mic in
                refI16.withUnsafeBufferPointer { ref in
                    outI16.withUnsafeMutableBufferPointer { out in
                        speex_echo_cancellation(echoState, mic.baseAddress, ref.baseAddress, out.baseAddress)
                    }
                }
            }
            outI16.withUnsafeMutableBufferPointer { out in
                _ = speex_preprocess_run(preprocessState, out.baseAddress)
            }
            for i in 0 ..< n {
                outF32[i] = Self.int16ToFloat(outI16[i])
            }

            outF32.withUnsafeBufferPointer { ptr in
                onCleanMic?(ptr.baseAddress!, n)
            }
        }
    }

    // MARK: - Conversion

    @inline(__always)
    private static func floatToInt16(_ f: Float) -> Int16 {
        let scaled = f * 32767.0
        if scaled >= 32767.0 { return 32767 }
        if scaled <= -32768.0 { return -32768 }
        return Int16(scaled.rounded())
    }

    @inline(__always)
    private static func int16ToFloat(_ i: Int16) -> Float {
        return Float(i) / 32767.0
    }
}
