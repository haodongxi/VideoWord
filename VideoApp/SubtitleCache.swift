// Created by haodongsheng
import Foundation
import CryptoKit

struct Cue: Codable, Identifiable {
    let id: UUID
    let start: Double
    let end: Double
    let original: String
    let translated: String
    init(start: Double, end: Double, original: String, translated: String) {
        id = UUID(); self.start = start; self.end = end
        self.original = original; self.translated = translated
    }
}

struct SubtitleCache {
    let directory: URL
    private struct Identity: Codable {
        let version: Int
        let path: String
        let size: UInt64
        let modified: Double
        let track: Int32
        let language: String
        let target: String
    }
    private struct Entry: Codable {
        let version: Int
        let cues: [Cue]
    }
    func location(video: URL, track: Int32, language: String) throws -> URL {
        let path = video.standardizedFileURL.resolvingSymlinksInPath().path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw NSError(domain: "SubtitleCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取视频文件信息"])
        }
        let identity = Identity(version: 1, path: path, size: size.uint64Value, modified: modified.timeIntervalSince1970, track: track, language: language, target: "zh-Hans")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    func load(_ url: URL) throws -> [Cue]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard entry.version == 1 else { throw NSError(domain: "SubtitleCache", code: 2, userInfo: [NSLocalizedDescriptionKey: "字幕缓存版本不支持"]) }
        return entry.cues
    }
    func save(_ cues: [Cue], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(version: 1, cues: cues)).write(to: url, options: .atomic)
    }
    func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
