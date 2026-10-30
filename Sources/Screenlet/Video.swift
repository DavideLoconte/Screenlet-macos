import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// What the encoder favours, as kbit/s at 1920x1200 and how many average
/// frames a keyframe may take. Smaller bursts arrive sooner, more bits look
/// sharper.
enum Priority {
    static func settings(_ name: String) -> (kbps: Int, vbvFrames: Double) {
        switch name {
        case "latency": return (12000, 2)
        case "clarity": return (40000, 8)
        default: return (20000, 4)
        }
    }
}

/// Captures a display with ScreenCaptureKit (NV12) and encodes it with
/// VideoToolbox (H.264 or HEVC) for low latency. Each frame goes to
/// onFrame(Annex B, keyframe, capture time in ns) on VideoToolbox's thread.
final class Video: NSObject, SCStreamOutput, SCStreamDelegate {
    static let keyframeSeconds = 10  // unless the settings say otherwise
    static let keepalive: TimeInterval = 0.1  // resend the last frame when nothing changes
    static let permissionWait: TimeInterval = 300
    static let screenRecording = "macOS does not let Screenlet record the screen: allow it in System Settings → "
        + "Privacy & Security → Screen Recording, then start it again"

    private let displayID: CGDirectDisplayID
    private let size: (Int, Int)
    private let fps: Int
    private let hevc: Bool
    private let onFrame: (Data, Bool, Int64) -> Void
    private let onError: (String) -> Void
    private var session: VTCompressionSession?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screenlet.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var last: CVPixelBuffer?
    private var lastAt = Date.distantPast
    private var force = false
    private var paused = false
    private var done = false

    let fidelity = Fidelity.enabled ? Fidelity() : nil

    /// The codecs this Mac encodes in hardware, by their PROTOCOL.md names.
    static let hardwareCodecs: Set<String> = {
        let names: [CMVideoCodecType: String] = [kCMVideoCodecType_H264: "avc", kCMVideoCodecType_HEVC: "hevc"]
        var list: CFArray?
        VTCopyVideoEncoderList(nil, &list)
        return Set(((list as? [[String: Any]]) ?? []).compactMap { encoder in
            guard encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool == true,
                  let type = encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber else { return nil }
            return names[type.uint32Value]
        })
    }()

    /// bitrate in kbit/s; vbvFrames from Priority.
    init(display: CGDirectDisplayID, size: (Int, Int), fps: Int, bitrate: Int, vbvFrames: Double, hevc: Bool,
         keyframeSeconds: Int, onFrame: @escaping (Data, Bool, Int64) -> Void, onError: @escaping (String) -> Void) {
        displayID = display
        self.size = size
        self.fps = fps
        self.hevc = hevc
        self.onFrame = onFrame
        self.onError = onError
        super.init()
        let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // The hardware encoder with low-latency rate control; without it, the
        // hardware encoder; the default otherwise.
        var lowLatency = false
        let specs: [CFDictionary?] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            nil,
        ]
        for (i, spec) in specs.enumerated() where session == nil {
            VTCompressionSessionCreate(allocator: nil, width: Int32(size.0), height: Int32(size.1), codecType: codec,
                                       encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            lowLatency = session != nil && i == 0
            if session != nil && i > 0 { log("macOS: no low-latency \(hevc ? "HEVC" : "H.264") encoder: encoder \(i)") }
        }
        guard let session else { return }
        burst = vbvFrames / Double(fps)
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: false,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                                         : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * keyframeSeconds,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // Said in the stream, so the tablet's decoder does not guess the colours.
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        // The low-latency encoder never holds a frame back and refuses to be told so.
        if !lowLatency { properties[kVTCompressionPropertyKey_MaxFrameDelayCount] = 0 }
        for (key, value) in properties where VTSessionSetProperty(session, key: key, value: value as CFTypeRef) != noErr {
            log("macOS: the encoder does not take", key)
        }
        rate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private var burst = 0.0  // seconds of the average bitrate a keyframe may use

    /// Sets the bitrate in kbit/s, as Streamer adapts it to the network. Not
    /// under lock: VideoToolbox takes properties while it encodes, and the
    /// capture queue must not wait for this.
    func rate(_ kbps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: kbps * 1000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [Int(Double(kbps) * 125 * burst), burst] as CFArray)
    }

    func start() {
        Thread.detachNewThread { [self] in
            do {
                try open()
            } catch {
                return failed(error.localizedDescription)
            }
            // ScreenCaptureKit sends nothing while the screen is still, so resend
            // the last frame to repair lost packets and keep the app reporting.
            while !done {
                Thread.sleep(forTimeInterval: Video.keepalive)
                lock.lock()
                let frame = Date().timeIntervalSince(lastAt) >= Video.keepalive && !paused ? last : nil
                lock.unlock()
                if let frame { encode(frame, captured: nowNanos()) }
            }
        }
    }

    /// The content ScreenCaptureKit can capture. The first time, macOS asks for
    /// permission and the session waits with its link open.
    private func shareable() throws -> SCShareableContent {
        let deadline = Date().addingTimeInterval(Video.permissionWait)
        var asked = false
        while true {
            let got = DispatchSemaphore(value: 0)
            var result: Result<SCShareableContent, Error> = .failure(Failure("macOS did not list the displays"))
            SCShareableContent.getWithCompletionHandler { content, error in
                if let content { result = .success(content) } else if let error { result = .failure(error) }
                got.signal()
            }
            _ = got.wait(timeout: .now() + 5)
            switch result {
            case .success(let content): return content
            case .failure(let error as NSError) where error.code == -3801:
                if !asked {
                    asked = true
                    log("macOS: waiting for Screen Recording to be allowed")
                    CGRequestScreenCaptureAccess()
                }
                if done || Date() > deadline { throw Failure(Video.screenRecording) }
                Thread.sleep(forTimeInterval: 1)
            case .failure(let error): throw error
            }
        }
    }

    private func open() throws {
        var display: SCDisplay?
        for _ in 0 ..< 30 {  // a new display reaches ScreenCaptureKit a moment later
            display = try shareable().displays.first { $0.displayID == displayID }
            if display != nil || done { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let display else { throw Failure("the virtual display did not show up for capture") }
        let config = SCStreamConfiguration()
        config.width = size.0
        config.height = size.1
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // BT.709, as the encoder says in the stream: colours as on the Mac.
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 4  // one is held for the keepalive
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try capture(true)
    }

    private func capture(_ on: Bool) throws {
        guard let stream else { return }
        let got = DispatchSemaphore(value: 0)
        var failure: Error?
        let handler: (Error?) -> Void = { failure = $0; got.signal() }
        on ? stream.startCapture(completionHandler: handler) : stream.stopCapture(completionHandler: handler)
        _ = got.wait(timeout: .now() + 5)
        if let failure = failure as NSError?, on {
            throw failure.code == -3801 ? Failure(Video.screenRecording) : failure
        }
    }

    // On ScreenCaptureKit's queue: encode the frame if it is new.
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              let raw = attachments.first?[SCStreamFrameInfo.status.rawValue] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = CMSampleBufferGetImageBuffer(sample) else { return }  // idle, blank or suspended
        lock.lock()
        let skip = paused
        if !skip {
            last = image
            lastAt = Date()
        }
        lock.unlock()
        guard !skip else { return }
        // The presentation time is the host clock at capture, the same as the pings'.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let captured = pts.isValid ? Int64(CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value) : nowNanos()
        encode(image, captured: captured)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failed("the capture stopped: \(error.localizedDescription)")
    }

    private func encode(_ image: CVPixelBuffer, captured: Int64) {
        lock.lock()
        defer { lock.unlock() }  // shared by the capture queue and the keepalive thread
        guard !done, let session else { return }
        let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        force = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                                        presentationTimeStamp: CMTime(value: nowNanos() / 1000, timescale: 1_000_000),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            let (data, keyframe) = Video.annexB(sample, hevc: self.hevc)
            self.onFrame(data, keyframe, captured)
            self.fidelity?.encoded(sample, from: image)
        }
    }

    /// Converts VideoToolbox's length-prefixed NAL units to Annex B for the app's
    /// decoder, with a keyframe's parameter sets first.
    static func annexB(_ sample: CMSampleBuffer, hevc: Bool) -> (Data, Bool) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            // H.264's SPS and PPS, or HEVC's VPS, SPS and PPS.
            let parameterSet = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
                                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            var count = 0
            _ = parameterSet(format, 0, nil, nil, &count, &lengthSize)
            if keyframe {
                for i in 0 ..< count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    _ = parameterSet(format, i, &pointer, &size, nil, nil)
                    if let pointer {
                        out.append(contentsOf: start)
                        out.append(pointer, count: size)
                    }
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return (out, keyframe) }
        let length = CMBlockBufferGetDataLength(block)
        out.reserveCapacity(out.count + length + 64)
        // Straight from the encoder's memory when it is one piece (it is): one copy.
        var pointer: UnsafeMutablePointer<CChar>?
        var contiguous = 0
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil,
                                       dataPointerOut: &pointer) == noErr, contiguous == length, let pointer {
            let raw = UnsafeRawBufferPointer(start: pointer, count: length)
            return (convert(raw, lengthSize: Int(lengthSize), into: out), keyframe)
        }
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        return (data.withUnsafeBytes { convert($0, lengthSize: Int(lengthSize), into: out) }, keyframe)
    }

    /// Appends length-prefixed NAL units to out with start codes.
    static func convert(_ data: UnsafeRawBufferPointer, lengthSize: Int, into out: Data) -> Data {
        var out = out
        var at = 0
        while at + lengthSize <= data.count {
            var n = 0
            for i in 0 ..< lengthSize { n = n << 8 | Int(data[at + i]) }
            at += lengthSize
            out.append(contentsOf: [0, 0, 0, 1])
            let end = min(at + n, data.count)
            out.append(data.baseAddress!.advanced(by: at).assumingMemoryBound(to: UInt8.self), count: end - at)
            at = end
        }
        return out
    }

    static func convert(_ data: Data, lengthSize: Int, into out: Data) -> Data {
        data.withUnsafeBytes { convert($0, lengthSize: lengthSize, into: out) }
    }

    func keyframe() {
        lock.lock()
        force = true  // the next frame, or the keepalive's at the latest
        lock.unlock()
    }

    /// Pauses capture and encoding while the app does not show the desktop.
    func pause(_ now: Bool) {
        lock.lock()
        paused = now
        lock.unlock()
        Thread.detachNewThread { [self] in try? capture(!now) }
    }

    private func failed(_ message: String) {
        guard !done else { return }
        log("macOS: video:", message)
        onError(message)
    }

    func stop() {
        lock.lock()
        done = true
        lock.unlock()
        try? capture(false)
        stream = nil
        lock.lock()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        last = nil
        lock.unlock()
    }
}
