// Created by haodongsheng
import SwiftUI
import AVKit
import AVFoundation
import Speech
import Translation
import UniformTypeIdentifiers

@MainActor final class VideoModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var file: URL?
    @Published var tracks: [AVAssetTrack] = []
    @Published var selectedTrack = 0
    @Published var language = "en-US"
    @Published var state = "请选择本地视频"
    @Published var cues: [Cue] = []
    @Published var time: Double = 0
    @Published var isProcessing = false
    @Published var translationConfig: TranslationSession.Configuration?
    @Published var translationRun = UUID()
    private var ffmpegPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path }
    private var whisperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-cli").path }
    @Published private(set) var customModelPath = UserDefaults.standard.string(forKey: "customWhisperModelPath") ?? ""
    private var bundledModelPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ggml-base.bin").path }
    private var whisperModelPath: String { customModelPath.isEmpty ? bundledModelPath : customModelPath }
    var modelName: String { customModelPath.isEmpty ? "内置 base（多语言）" : URL(fileURLWithPath: customModelPath).lastPathComponent }
    func chooseModel() {
        let panel = NSOpenPanel()
        panel.message = "选择 whisper.cpp 兼容的多语言 GGML 模型文件"
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else { state = "无法读取模型文件"; return }
        guard !url.lastPathComponent.lowercased().contains(".en.") else { state = "请选择多语言模型，不支持仅英语的 .en 模型"; return }
        customModelPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        UserDefaults.standard.set(customModelPath, forKey: "customWhisperModelPath")
        if tracks.isEmpty { state = "已选择本地模型：\(modelName)" } else { loadCachedSubtitles() }
    }
    func useBundledModel() {
        customModelPath = ""
        UserDefaults.standard.removeObject(forKey: "customWhisperModelPath")
        if tracks.isEmpty { state = "已选择内置 base 多语言模型" } else { loadCachedSubtitles() }
    }
    private func cacheLanguage() -> String {
        if customModelPath.isEmpty { return "\(language)|whisper-v2-silence|base-465707469ff3a37a2b9b8d8f89f2f99de7299dac" }
        let attributes = try? FileManager.default.attributesOfItem(atPath: customModelPath)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(language)|whisper-v2-silence|\(customModelPath)|\(size)|\(modified)"
    }
    private var ffmpegProcess: Process?
    private func stopFFmpeg() {
        if let process = ffmpegProcess, process.isRunning { process.terminate() }
        ffmpegProcess = nil
    }
    private let cache = SubtitleCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.haodongsheng.videosubtitles/subtitles", isDirectory: true))
    private var processingCacheURL: URL?
    private var observer: Any?
    private var generation = 0
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<SFTranscription, Error>?
    private var recognitionID: UUID?
    private func cancelRecognition() {
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionID = nil
        let continuation = recognitionContinuation
        recognitionContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }
    private var phase = 0
    private func showPhase(_ message: String, hint: String? = nil) {
        phase += 1
        let currentPhase = phase, currentGeneration = generation
        state = message
        if let hint {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard generation == currentGeneration, phase == currentPhase, isProcessing else { return }
                state = "\(message)（等待较久：\(hint)）"
            }
        }
    }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.time = time.seconds.isFinite ? time.seconds : 0 }
        }
    }
    var currentCue: Cue? { cues.first { time >= $0.start && time < $0.end } }
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importVideo(url)
    }
    func importVideo(_ url: URL) {
        guard url.isFileURL else { state = "请选择本地视频文件"; return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            state = "请选择存在的本地视频文件"; return
        }
        generation += 1; cancelRecognition(); stopFFmpeg()
        isProcessing = false; translationConfig = nil; translationRun = UUID()
        player.pause(); player.replaceCurrentItem(with: nil)
        file = url; cues = []; tracks = []; selectedTrack = 0; time = 0
        let asset = AVURLAsset(url: url)
        let current = generation
        state = "正在读取视频…"
        Task {
            do {
                let found = try await asset.loadTracks(withMediaType: .audio)
                let playable = try await asset.load(.isPlayable)
                guard generation == current else { return }
                guard playable else { state = "系统无法播放此文件，请检查格式或编码"; return }
                tracks = found
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                if found.isEmpty { state = "没有找到可读取的音轨" }
                else { loadCachedSubtitles() }
            } catch { if generation == current { state = "读取失败：\(error.localizedDescription)" } }
        }
    }
    func loadCachedSubtitles() {
        guard !isProcessing, let file, tracks.indices.contains(selectedTrack) else { return }
        cues = []
        do {
            let url = try cache.location(video: file, track: tracks[selectedTrack].trackID, language: cacheLanguage())
            if let saved = try cache.load(url) {
                cues = saved
                state = "已加载字幕缓存：\(saved.count) 条；点击「生成字幕」可重新识别"
            } else {
                state = "没有找到字幕缓存；点击「生成字幕」开始识别"
            }
        } catch { state = "字幕缓存读取失败：\(error.localizedDescription)；可点击「生成字幕」重试" }
    }
    func start() {
        guard let file, tracks.indices.contains(selectedTrack), !isProcessing else { return }
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else { state = "应用缺少内置 FFmpeg，请重新安装完整版本"; return }
        guard FileManager.default.isExecutableFile(atPath: whisperPath) else { state = "应用缺少内置 whisper-cli，请重新安装完整版本"; return }
        guard FileManager.default.isReadableFile(atPath: whisperModelPath) else { state = customModelPath.isEmpty ? "应用缺少内置多语言模型，请重新安装完整版本" : "所选模型无法读取，请重新选择或切回内置模型"; return }
        do {
            let url = try cache.location(video: file, track: tracks[selectedTrack].trackID, language: cacheLanguage())
            try cache.remove(url)
            processingCacheURL = url
        } catch { state = "无法清除字幕缓存：\(error.localizedDescription)"; return }
        generation += 1; cancelRecognition(); stopFFmpeg(); cues = []; isProcessing = true
        translationConfig = nil; translationRun = UUID()
        let current = generation
        if language.hasPrefix("zh") {
            state = "正在准备中文语音识别…"
            let run = translationRun
            Task { await process(session: nil, run: run) }
        } else {
            let source = Locale.Language(identifier: String(language.prefix(2)))
            showPhase("正在检查翻译语言…", hint: "可取消后重试，并检查系统翻译语言是否已下载")
            Task { @MainActor in
                let target = Locale.Language(identifier: "zh-Hans")
                let availability = await LanguageAvailability().status(from: source, to: target)
                guard generation == current, isProcessing else { return }
                if availability == .unsupported {
                    isProcessing = false
                    state = "当前设备不支持所选语言翻译成中文"
                    return
                }
                showPhase("正在等待系统翻译会话…", hint: "可取消后重新生成；如果仍停在此处，请重启应用")
                translationConfig = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }
    func cancel() {
        generation += 1; cancelRecognition(); stopFFmpeg()
        isProcessing = false; translationConfig = nil; translationRun = UUID(); state = "已取消字幕生成"
    }
    func process(session: TranslationSession?, run: UUID) async {
        guard run == translationRun, isProcessing, let url = file, tracks.indices.contains(selectedTrack) else { return }
        let current = generation
        let track = tracks[selectedTrack]
        do {
            if let session {
                showPhase("正在准备系统翻译语言…", hint: "请检查语言包下载是否完成，或取消后重试")
                try await session.prepareTranslation()
            }
            try checkCurrent(current)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw issue("无法读取视频时长") }
            var offset = 0.0
            while offset < duration {
                try checkCurrent(current)
                let length = min(20.0, duration - offset)
                let progress = String(format: "%.0f%%，已生成 %d 条", offset / duration * 100, cues.count)
                showPhase("正在提取音频（\(progress)）", hint: "当前片段处理时间较长")
                let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("video-subtitles-\(UUID().uuidString).wav")
                do {
                    try await exportAudio(video: url, track: track, trackIndex: selectedTrack, start: offset, duration: length, to: audioURL)
                    try checkCurrent(current)
                    if try AudioSilence.isSilent(audioURL) {
                        try? FileManager.default.removeItem(at: audioURL)
                        offset += length
                        continue
                    }
                    showPhase("正在识别语音（\(progress)）", hint: "识别服务响应较慢，可检查网络和语音识别权限")
                    let groups = try await recognizeLocally(url: audioURL)
                    try checkCurrent(current)
                    for group in groups {
                        try checkCurrent(current)
                        let translated: String
                        if let session {
                            showPhase("正在翻译文字（\(progress)）", hint: "翻译服务响应较慢，可取消后重试")
                            translated = try await session.translate(group.text).targetText
                        } else {
                            translated = group.text
                        }
                        try checkCurrent(current)
                        let localStart = max(0, min(length, group.start))
                        let localEnd = max(localStart, min(length, group.end))
                        guard localStart < length, localEnd > localStart else { continue }
                        cues.append(Cue(start: offset + localStart, end: min(duration, offset + length, offset + max(localEnd + 0.6, localStart + 1.0)), original: session == nil ? "" : group.text, translated: translated))
                    }
                } catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
                        offset += length; continue
                    }
                    throw error
                }
                try? FileManager.default.removeItem(at: audioURL)
                offset += length
            }
            try checkCurrent(current)
            guard let cacheURL = processingCacheURL,
                  try cache.location(video: url, track: track.trackID, language: cacheLanguage()) == cacheURL else {
                isProcessing = false; state = "字幕已生成，但视频文件发生变化，未保存缓存"; return
            }
            do {
                try cache.save(cues, to: cacheURL)
                state = "字幕生成完成并已缓存：\(cues.count) 条"
            } catch {
                state = "字幕已生成，但缓存保存失败：\(error.localizedDescription)"
            }
            isProcessing = false
        } catch {
            guard generation == current else { return }
            isProcessing = false; state = "生成失败：\(error.localizedDescription)"
        }
    }
    private func checkCurrent(_ current: Int) throws {
        if generation != current || Task.isCancelled { throw CancellationError() }
    }
    private func issue(_ message: String) -> NSError { NSError(domain: "VideoSubtitles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func exportAudio(video: URL, track: AVAssetTrack, trackIndex: Int, start: Double, duration: Double, to url: URL) async throws {
        if !ffmpegPath.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else { throw issue("FFmpeg 路径不可用，请重新选择") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-ss", String(start), "-i", video.path, "-t", String(duration), "-map", "0:a:\(trackIndex)", "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            ffmpegProcess = process
            do { try process.run() } catch { ffmpegProcess = nil; throw issue("无法启动 FFmpeg：\(error.localizedDescription)") }
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
            if ffmpegProcess === process { ffmpegProcess = nil }
            guard result == 0 else { throw issue("FFmpeg 音轨提取失败（退出码 \(result)）") }
            return
        }
        throw issue("请先设置 FFmpeg")
    }
    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Double; let to: Double }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }
    private func recognizeLocally(url: URL) async throws -> [(text: String, start: Double, end: Double)] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)")
        let output = base.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["-m", whisperModelPath, "-f", url.path, "-l", String(language.prefix(2)), "-oj", "-of", base.path, "-nt"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        ffmpegProcess = process
        do { try process.run() } catch { ffmpegProcess = nil; throw issue("无法启动本地识别引擎：\(error.localizedDescription)") }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); continuation.resume(returning: process.terminationStatus) }
        }
        if ffmpegProcess === process { ffmpegProcess = nil }
        guard status == 0 else { throw issue("本地语音识别失败（退出码 \(status)），请检查模型和引擎") }
        do {
            let result = try JSONDecoder().decode(WhisperOutput.self, from: Data(contentsOf: output))
            return result.transcription.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (text, segment.offsets.from / 1000, segment.offsets.to / 1000)
            }
        } catch { throw issue("无法读取本地识别结果：\(error.localizedDescription)") }
    }

}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .floating; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct TranslationHost: View {
    @ObservedObject var model: VideoModel
    let run: UUID
    var body: some View {
        Color.clear.translationTask(model.translationConfig) { session in
            await model.process(session: session, run: run)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = VideoModel()
    @State private var isDragTargeted = false
    @State private var showStylePanel = false
    @State private var showPreview = false
    @AppStorage("subtitleColorRGB") private var subtitleColorRGB = "FFFFFF"
    @AppStorage("subtitleBackgroundRGB") private var backgroundColorRGB = "000000"
    private func colorBinding(_ storage: Binding<String>) -> Binding<Color> {
        Binding(get: {
            let rgb = UInt32(storage.wrappedValue, radix: 16) ?? 0
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            storage.wrappedValue = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
    private var subtitleColor: Color { colorBinding($subtitleColorRGB).wrappedValue }
    private var backgroundColor: Color { colorBinding($backgroundColorRGB).wrappedValue }
    @AppStorage("subtitleFont") private var fontName = "系统默认"
    @AppStorage("subtitleSize") private var fontSize = 24.0
    @AppStorage("subtitleOpacity") private var textOpacity = 1.0
    @AppStorage("subtitleBackgroundOpacity") private var backgroundOpacity = 0.75
    @AppStorage("subtitleX") private var positionX = 0.5
    @AppStorage("subtitleY") private var positionY = 0.80
    @AppStorage("subtitleShowOriginal") private var showOriginal = true
    private var fontFamilies: [String] { ["系统默认"] + NSFontManager.shared.availableFontFamilies.sorted() }
    private func subtitleFont(_ size: Double) -> Font {
        fontName == "系统默认" ? .system(size: size, weight: .semibold) : .custom(fontName, size: size)
    }
    private var stylePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("字幕样式").font(.headline); Spacer(); Button("重置") { resetStyle() } }
                Toggle("显示示例字幕", isOn: $showPreview)
                Toggle("显示原文", isOn: $showOriginal)
                Picker("字体", selection: $fontName) {
                    ForEach(fontFamilies, id: \.self) { name in Text(name).tag(name) }
                }
                ColorPicker("字幕颜色", selection: colorBinding($subtitleColorRGB), supportsOpacity: false)
                ColorPicker("背景颜色", selection: colorBinding($backgroundColorRGB), supportsOpacity: false)
                styleSlider("字号", value: $fontSize, range: 14...60, suffix: "pt")
                styleSlider("文字不透明度", value: $textOpacity, range: 0...1, suffix: "%", percent: true)
                styleSlider("背景不透明度", value: $backgroundOpacity, range: 0...1, suffix: "%", percent: true)
                styleSlider("水平位置", value: $positionX, range: 0.1...0.9, suffix: "%", percent: true)
                styleSlider("垂直位置", value: $positionY, range: 0.1...0.9, suffix: "%", percent: true)
                Text("开启示例字幕后，可在没有实际字幕时预览样式。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }.frame(width: 260).background(Color(nsColor: .controlBackgroundColor))
    }
    private func styleSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text("\(Int((percent ? value.wrappedValue * 100 : value.wrappedValue).rounded()))\(suffix)").foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
    private func resetStyle() {
        fontName = "系统默认"; fontSize = 24; textOpacity = 1; backgroundOpacity = 0.75
        positionX = 0.5; positionY = 0.8; showOriginal = true
        subtitleColorRGB = "FFFFFF"; backgroundColorRGB = "000000"
    }
    private func subtitleOverlay(translated: String, original: String, size: CGSize) -> some View {
        VStack(spacing: 4) {
            Text(translated).font(subtitleFont(fontSize))
            if showOriginal && !original.isEmpty { Text(original).font(subtitleFont(fontSize * 0.7)) }
        }
        .foregroundStyle(subtitleColor.opacity(textOpacity))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(backgroundColor.opacity(backgroundOpacity))
        .cornerRadius(8)
        .frame(maxWidth: max(100, size.width * 0.8))
        .position(x: size.width * positionX, y: size.height * positionY)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("打开视频") { model.chooseFile() }
                Menu("识别模型") {
                    Button("使用内置 base 模型") { model.useBundledModel() }
                    Button("选择其他本地模型…") { model.chooseModel() }
                }.disabled(model.isProcessing)
                Text(model.file?.lastPathComponent ?? "未选择视频").lineLimit(1)
                Spacer()
                Picker("语言", selection: $model.language) {
                    Text("英语").tag("en-US"); Text("日语").tag("ja-JP")
                    Text("汉语（普通话）").tag("zh-CN"); Text("韩语").tag("ko-KR"); Text("泰语").tag("th-TH")
                }.frame(width: 140).disabled(model.isProcessing)
                Picker("音轨", selection: $model.selectedTrack) {
                    ForEach(model.tracks.indices, id: \.self) { index in Text("音轨 \(index + 1)").tag(index) }
                }.frame(width: 140).disabled(model.isProcessing || model.tracks.isEmpty)
                if model.isProcessing { Button("取消") { model.cancel() } }
                else { Button("生成字幕") { model.start() }.disabled(model.tracks.isEmpty) }
                Button(showStylePanel ? "收起字幕设置" : "字幕设置") { showStylePanel.toggle() }
            }
            HStack(spacing: 12) {
                ZStack {
                    NativePlayer(player: model.player)
                    if model.file == nil {
                        Text("将本地视频拖到窗口，或点击「打开视频」")
                            .font(.title3).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    GeometryReader { geometry in
                        if let cue = model.currentCue {
                            subtitleOverlay(translated: cue.translated, original: cue.original, size: geometry.size)
                        } else if showStylePanel && showPreview {
                            subtitleOverlay(translated: "这里是中文字幕预览", original: "Subtitle preview", size: geometry.size)
                        }
                    }.allowsHitTesting(false)
                }.frame(minWidth: 400, minHeight: 360)
                if showStylePanel { stylePanel }
            }
            Text(model.state).font(.callout).textSelection(.enabled)
            Text("常见兼容格式：MP4、MOV；推荐 H.264 / HEVC 视频 + AAC 音频。具体取决于 macOS 和文件编码；MKV 暂不保证支持。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("识别模型：\(model.modelName)；音频在本地识别，翻译使用系统翻译。")
                .font(.caption).foregroundStyle(.secondary)
            Text("字幕按 20 秒分段生成，可先处理一段再播放。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().frame(minWidth: 850, minHeight: 520)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isDragTargeted ? Color.accentColor : .clear, lineWidth: 3).allowsHitTesting(false))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                DispatchQueue.main.async {
                    if let url { model.importVideo(url) }
                    else { model.state = "无法读取拖入的文件\(error.map { "：" + $0.localizedDescription } ?? "")" }
                }
            }
            return true
        }
        .onChange(of: model.language) { _, _ in model.loadCachedSubtitles() }
        .onChange(of: model.selectedTrack) { _, _ in model.loadCachedSubtitles() }
        .background {
            TranslationHost(model: model, run: model.translationRun).id(model.translationRun)
        }
    }
}
@main struct VideoSubtitlesApp: App {
    var body: some Scene { WindowGroup("视频翻译字幕") { ContentView() } }
}
