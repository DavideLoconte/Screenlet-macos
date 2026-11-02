import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Video encoding profile parameters, specifying target bitrate at 1920x1200 and VBV buffer frame allowance.
enum Priority {
    /// Returns bitrate in kilobits per second and VBV buffer capacity in frame equivalents for a profile name.
    static func settings(_ name: String) -> (kbps: Int, vbvFrames: Double) {
        switch name {
        case "latency": return (12000, 2)
        case "clarity": return (40000, 8)
        default: return (20000, 4)
        }
    }
}

/// Captures virtual display output using ScreenCaptureKit and encodes frames with VideoToolbox.
///
/// Encodes frames to low-latency H.264 or HEVC elementary streams formatted with Annex B start codes
/// and forwards encoded frames via `onFrame(data, keyframe, captureTimestampNs)`.
final class Video: NSObject, SCStreamOutput, SCStreamDelegate {
    static let keyframeSeconds = 10
    static let keepalive: TimeInterval = 0.1
    static let permissionWait: TimeInterval = 300
    static let screenRecording = "macOS does not permit Screenlet to record the display: enable Screen Recording in "
        + "System Settings → Privacy & Security, then restart the session"

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

    /// Supported hardware-accelerated video codecs matching PROTOCOL.md identifiers.
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

    /// Initializes video capture and hardware encoder session.
    ///
    /// - Parameters:
    ///   - display: CoreGraphics display identifier to capture.
    ///   - size: Capture frame dimensions `(width, height)`.
    ///   - fps: Target refresh rate in frames per second.
    ///   - bitrate: Initial target bitrate in kilobits per second.
    ///   - vbvFrames: Video Buffer Verifier capacity in frame equivalents.
    ///   - hevc: Indicates whether to encode in HEVC (`true`) or H.264 (`false`).
    ///   - keyframeSeconds: Maximum interval in seconds between IDR keyframes.
    ///   - onFrame: Callback invoked on completion of each encoded frame.
    ///   - onError: Callback invoked upon unrecoverable capture or encoding failure.
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
        // Select low-latency rate control specification if available; fall back to hardware acceleration.
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
            // Explicit colorimetry signaling matching ITU-R BT.709-2 standards.
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        // Low-latency encoders process frames immediately and reject maximum frame delay constraints.
        if !lowLatency { properties[kVTCompressionPropertyKey_MaxFrameDelayCount] = 0 }
        for (key, value) in properties where VTSessionSetProperty(session, key: key, value: value as CFTypeRef) != noErr {
            log("macOS: the encoder does not take", key)
        }
        rate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private var burst = 0.0  // seconds of the average bitrate a keyframe may use

    /// Dynamically adjusts the target encoder bitrate in kilobits per second.
    ///
    /// Executed outside the lock to avoid blocking the capture pipeline during bitrate adaptation.
    func rate(_ kbps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: kbps * 1000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [Int(Double(kbps) * 125 * burst), burst] as CFArray)
    }

    /// Commences screen capture and launches the background frame keepalive watchdog.
    func start() {
        Thread.detachNewThread { [self] in
            do {
                try open()
            } catch {
                return failed(error.localizedDescription)
            }
            // ScreenCaptureKit pauses delivery when screen contents are static; repeat the last frame to sustain transport.
            while !done {
                Thread.sleep(forTimeInterval: Video.keepalive)
                lock.lock()
                let frame = Date().timeIntervalSince(lastAt) >= Video.keepalive && !paused ? last : nil
                lock.unlock()
                if let frame { encode(frame, captured: nowNanos()) }
            }
        }
    }

    /// Retrieves shareable screen capture content, prompting for Screen Recording permissions if required.
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

    // SCStreamOutput sample buffer handler invoked on ScreenCaptureKit's queue.
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
        // Presentation timestamp represents host uptime at frame capture time, aligned with ping measurements.
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

    /// Converts sample buffers containing length-prefixed NAL units into Annex B byte streams with prefixed parameter sets.
    static func annexB(_ sample: CMSampleBuffer, hevc: Bool) -> (Data, Bool) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            // H.264 SPS and PPS, or HEVC VPS, SPS and PPS parameter sets.
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
        // Attempt zero-copy retrieval when the underlying block buffer is contiguous.
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

    /// Translates length-prefixed NAL units into 4-byte start code prefixed Annex B format.
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

    /// Forces generation of an instantaneous decoder refresh (IDR) keyframe on the subsequent frame.
    func keyframe() {
        lock.lock()
        force = true
        lock.unlock()
    }

    /// Suspends or resumes screen capture during client background or minimized state.
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

    /// Terminates screen capture, invalidates the VideoToolbox compression session, and releases buffer allocations.
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
