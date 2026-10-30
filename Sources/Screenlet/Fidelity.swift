import CoreMedia
import Foundation
import VideoToolbox

/// Measures how faithful the stream is. Every encoded frame is decoded here,
/// as the tablet does, and one in `every` is compared with the captured frame
/// by the PSNR of its luma. Above 50 dB the difference is invisible, below 30
/// it shows. Off unless enabled with "measure".
final class Fidelity {
    static var enabled = false
    static let every = 4

    private let queue = DispatchQueue(label: "screenlet.fidelity", qos: .utility)
    private var decoder: VTDecompressionSession?
    private var count = 0
    private let lock = NSLock()
    private var scores: [Double] = []

    /// Called on VideoToolbox's thread with an encoded frame and its source image.
    func encoded(_ sample: CMSampleBuffer, from image: CVPixelBuffer) {
        count += 1
        let source = count % Fidelity.every == 0 ? Fidelity.luma(image) : nil
        queue.async { [self] in decode(sample, against: source) }
    }

    /// The mean and lowest PSNR since the last call, or nil if there are none.
    func take() -> (Double, Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard !scores.isEmpty else { return nil }
        let result = (scores.reduce(0, +) / Double(scores.count), scores.min()!)
        scores.removeAll()
        return result
    }

    private func decode(_ sample: CMSampleBuffer, against source: (Data, Int, Int, Int)?) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if decoder == nil || !VTDecompressionSessionCanAcceptFormatDescription(decoder!, formatDescription: format) {
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                         imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &decoder)
        }
        guard let decoder else { return }
        // Synchronous, because each frame depends on the previous one.
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [self] status, _, image, _, _ in
            guard status == noErr, let image, let source else { return }
            let (decoded, _, _, _) = Fidelity.luma(image)
            let psnr = Fidelity.psnr(source.0, decoded, width: source.1, height: source.2, stride: source.3)
            lock.lock()
            scores.append(psnr)
            lock.unlock()
        }
    }

    /// The luma plane without row padding: bytes, width, height and row stride.
    static func luma(_ image: CVPixelBuffer) -> (Data, Int, Int, Int) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return (Data(), 0, 0, 0) }
        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { to in
            for row in 0 ..< height { memcpy(to.baseAddress! + row * width, base + row * stride, width) }
        }
        return (out, width, height, width)
    }

    /// PSNR in dB of b against a, both 8-bit and the same size. 100 when identical.
    static func psnr(_ a: Data, _ b: Data, width: Int, height: Int, stride: Int) -> Double {
        guard a.count == b.count, width * height > 0 else { return 0 }
        var sum: UInt64 = 0
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                for i in 0 ..< x.count {
                    let d = Int(x[i]) - Int(y[i])
                    sum &+= UInt64(d * d)
                }
            }
        }
        let mse = Double(sum) / Double(width * height)
        return mse == 0 ? 100 : 10 * log10(255 * 255 / mse)
    }

    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }
}
