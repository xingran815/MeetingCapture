import Foundation
import AVFoundation
import CoreMedia

// ─────────────────────────────────────────────────────────────────────────────
// CMSampleBuffer → AVAudioPCMBuffer
//
// ScreenCaptureKit delivers audio as:
//   kAudioFormatLinearPCM · float32 · non-interleaved · 48 kHz · stereo
//
// The AudioBufferList inside the CMSampleBuffer has one ABL entry per channel.
// CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer fills it in, but the
// ABL struct only has room for 1 AudioBuffer — we must allocate the correct
// byte size ourselves before calling it.
//
// We copy each channel's samples directly into the AVAudioPCMBuffer's
// floatChannelData array (non-interleaved → non-interleaved).
// ─────────────────────────────────────────────────────────────────────────────

extension CMSampleBuffer {

    /// Convert this CMSampleBuffer to an AVAudioPCMBuffer.
    /// Returns nil on any error (malformed buffer, unsupported format, etc.)
    func toPCMBuffer() -> AVAudioPCMBuffer? {

        // 1. Extract the AVAudioFormat from the format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(self) else {
            fputs("toPCMBuffer: could not get format description from sample buffer\n", stderr)
            return nil
        }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0 else { return nil }

        // 2. Allocate the AudioBufferList with the right size
        //    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer needs a big
        //    enough chunk of memory — the plain AudioBufferList struct only has
        //    room for one AudioBuffer.  Ask CoreMedia how large it needs to be.
        var abl1Size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &abl1Size,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard abl1Size > 0 else {
            fputs("toPCMBuffer: failed to get ABL size\n", stderr)
            return nil
        }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: abl1Size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }
        let ablPtr = rawABL.assumingMemoryBound(to: AudioBufferList.self)

        // 3. Fill the ABL
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: abl1Size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            fputs("toPCMBuffer: CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer → \(status)\n", stderr)
            return nil
        }

        // 4. Destination is always interleaved float32 (WAV-friendly).
        let channelCount = Int(srcFormat.channelCount)
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount) else {
            fputs("toPCMBuffer: failed to allocate AVAudioPCMBuffer\n", stderr)
            return nil
        }
        pcmBuffer.frameLength = frameCount

        // 5. Fill destination (interleaved) from source (whichever layout)
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let dstBase = pcmBuffer.floatChannelData?[0] else { return nil }
        let frames = Int(frameCount)

        if srcFormat.isInterleaved {
            guard abl.count >= 1, let src = abl[0].mData else { return nil }
            let bytes = min(
                Int(abl[0].mDataByteSize),
                frames * channelCount * MemoryLayout<Float>.size
            )
            memcpy(dstBase, src, bytes)
        } else {
            // Interleave channel-planar source into destination
            for ch in 0 ..< min(channelCount, abl.count) {
                guard let srcRaw = abl[ch].mData else { continue }
                let src = srcRaw.assumingMemoryBound(to: Float.self)
                let srcFrames = min(frames, Int(abl[ch].mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0 ..< srcFrames {
                    dstBase[i * channelCount + ch] = src[i]
                }
            }
        }

        return pcmBuffer
    }
}
