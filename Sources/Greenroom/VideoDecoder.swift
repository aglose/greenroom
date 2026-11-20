import AVFoundation
import CoreMedia

/// Turns the engine's Annex B access units into sample buffers for an AVSampleBufferDisplayLayer, which decodes
/// them on the GPU and shows each one at once.
final class VideoDecoder {
    private var format: CMVideoFormatDescription?
    private(set) var frames = 0

    /// The NAL units of an Annex B buffer (start codes 00 00 01 or 00 00 00 01), without their start codes.
    static func nalUnits(_ b: [UInt8]) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var start = -1
        var i = 0
        let n = b.count
        while i + 2 < n {
            if b[i] == 0, b[i+1] == 0, b[i+2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, b[end-1] == 0 { end -= 1 }   // the zero of a four-byte start code
                    units.append(start..<end)
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { units.append(start..<n) }
        return units
    }

    /// A sample buffer for one access unit, or nil until a keyframe has given the stream's parameter sets.
    func sampleBuffer(for frame: FrameChannel.Frame) -> CMSampleBuffer? {
        let b = frame.unit
        var sps: Range<Int>?, pps: Range<Int>?
        var picture: [UInt8] = []
        picture.reserveCapacity(b.count + 16)
        for r in Self.nalUnits(b) where !r.isEmpty {
            switch b[r.lowerBound] & 0x1f {
            case 7: sps = r
            case 8: pps = r
            default:
                let len = UInt32(r.count)
                picture.append(contentsOf: [UInt8(len >> 24), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff)])
                picture.append(contentsOf: b[r])
            }
        }
        if let sps, let pps {
            let s = Array(b[sps]), p = Array(b[pps])
            var made: CMVideoFormatDescription?
            s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    let sets = [sp.baseAddress!, pp.baseAddress!]
                    let sizes = [s.count, p.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: sets, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made)
                }
            }
            if let made { format = made }
        }
        guard let format, !picture.isEmpty else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: picture.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: picture.count, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: picture, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: picture.count) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = picture.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: frame.presentMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.keyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        frames += 1
        return sample
    }
}
