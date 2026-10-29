// Created by haodongsheng
import AVFoundation
import Foundation

enum AudioSilence {
    // Only skip effectively silent audio. This is not a voice activity detector.
    static func isSilent(_ url: URL, threshold: Double = 0.0001) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192), format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "AudioSilence", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法检查音频静音状态"])
        }
        var total: Double = 0
        var count = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else { throw NSError(domain: "AudioSilence", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取音频采样"]) }
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    let sample = Double(channels[c][i * Int(buffer.stride)])
                    total += sample * sample
                    count += 1
                }
            }
        }
        return count == 0 || sqrt(total / Double(count)) < threshold
    }
}
