// Created by haodongsheng
import AppKit
import AVFoundation
import CoreAudio
import Speech

struct Source { let id: AudioObjectID; let pid: pid_t; let name: String }
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func sources() -> [Source] {
    var a = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var running: UInt32 = 0; var n = UInt32(MemoryLayout<UInt32>.size)
        var prop = address(kAudioProcessPropertyIsRunningOutput)
        guard AudioObjectGetPropertyData(id, &prop, 0, nil, &n, &running) == noErr, running != 0 else { return nil }
        var pid: pid_t = 0; n = UInt32(MemoryLayout<pid_t>.size); prop = address(kAudioProcessPropertyPID)
        guard AudioObjectGetPropertyData(id, &prop, 0, nil, &n, &pid) == noErr, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return Source(id: id, pid: pid, name: app?.localizedName ?? "进程 \(pid)")
    }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}

final class AudioCaptions: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private let state = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
    private let audioState = NSMenuItem(title: "音频：尚未开始", action: nil, keyEquivalent: "")
    private let previousCaption = NSMenuItem(title: "上一段字幕", action: nil, keyEquivalent: "")
    private let caption = NSMenuItem(title: "字幕将在这里显示", action: nil, keyEquivalent: "")
    private let fullTranscript = NSMenuItem(title: "当前识别片段：暂无", action: nil, keyEquivalent: "")
    private var lastCompletedCaption = ""
    private var currentCaption = ""
    private let toggleItem = NSMenuItem(title: "开始监听", action: #selector(toggle), keyEquivalent: "s")
    private let sourceItem = NSMenuItem(title: "音频来源", action: nil, keyEquivalent: "")
    private var selected: Source?
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let captureQueue = DispatchQueue(label: "audio.captions.capture")
    private let recognitionQueue = DispatchQueue(label: "audio.captions.recognition")
    private let bufferLock = NSLock()
    private var capturedAudio: [AVAudioPCMBuffer] = []
    private var capturedDuration: Double = 0
    private var drainScheduled = false
    private var droppedDuration: Double = 0
    private let bufferStatus = NSMenuItem(title: "音频缓冲：正常", action: nil, keyEquivalent: "")
    private var historyWindow: NSWindow?
    private var historyView: NSTextView?
    private var completedTranscripts: [String] = []
    private var latestTranscript = ""
    private var request: SFSpeechAudioBufferRecognitionRequest?
    // Accessed only on the audio queue. Keep a bounded bridge across recognition restarts.
    private var pendingAudio: [AVAudioPCMBuffer] = []
    private var pendingDuration: Double = 0
    private var lastMeterUpdate = 0.0
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var generation = 0
    private var recognitionSession = 0
    private var consecutiveErrors = 0
    private var active = false
    private var starting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "字幕"
        menu.delegate = self
        state.isEnabled = false; audioState.isEnabled = false; caption.isEnabled = false; previousCaption.isEnabled = false; fullTranscript.isEnabled = false; bufferStatus.isEnabled = false
        menu.addItem(state); menu.addItem(audioState); menu.addItem(bufferStatus); menu.addItem(previousCaption); menu.addItem(caption); menu.addItem(fullTranscript); menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "查看字幕历史", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self; menu.addItem(historyItem)
        menu.addItem(sourceItem); toggleItem.target = self; menu.addItem(toggleItem)
        menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        let submenu = NSMenu()
        let all = NSMenuItem(title: "全部来源（混合）", action: #selector(selectSource(_:)), keyEquivalent: "")
        all.target = self; all.state = selected == nil ? .on : .off; submenu.addItem(all)
        let list = sources()
        if list.isEmpty { let item = NSMenuItem(title: "没有检测到正在输出的进程", action: nil, keyEquivalent: ""); item.isEnabled = false; submenu.addItem(item) }
        for source in list {
            let item = NSMenuItem(title: "\(source.name) (PID \(source.pid))", action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = NSNumber(value: source.id); item.state = selected?.id == source.id ? .on : .off
            submenu.addItem(item)
        }
        sourceItem.submenu = submenu
        sourceItem.isEnabled = !active && !starting
    }
    @objc private func selectSource(_ item: NSMenuItem) {
        if let id = item.representedObject as? NSNumber { selected = sources().first { $0.id == id.uint32Value } } else { selected = nil }
        state.title = selected.map { "已选择：\($0.name) (PID \($0.pid))" } ?? "已选择：全部来源"
    }
    @objc private func toggle() {
        if active || starting { stop(); return }
        starting = true; bufferStatus.title = "音频缓冲：正常"; generation += 1; lastCompletedCaption = ""; currentCaption = ""; previousCaption.title = "上一段字幕"; caption.title = "字幕将在这里显示"; fullTranscript.title = "当前识别片段：暂无"; completedTranscripts.removeAll(); latestTranscript = ""; refreshHistory(); let current = generation
        state.title = "正在请求语音识别权限…"
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.starting else { return }
                guard auth == .authorized else { self.fail("请在系统设置中允许语音识别"); return }
                guard self.recognizer?.isAvailable == true else { self.fail("语音识别暂不可用"); return }
                do {
                    try self.startAudio()
                    self.active = true; self.starting = false
                    self.startRecognition()
                    self.toggleItem.title = "停止监听"
                    self.state.title = "监听中：\(self.selected?.name ?? "全部来源（混合）")"
                } catch { self.fail("无法捕获系统音频：\(error.localizedDescription)") }
            }
        }
    }
    private func check(_ result: OSStatus, _ operation: String) throws {
        if result != noErr { throw NSError(domain: operation, code: Int(result), userInfo: [NSLocalizedDescriptionKey: "\(operation) (\(result))"]) }
    }
    private func startAudio() throws {
        if let selected, !sources().contains(where: { $0.id == selected.id }) { throw NSError(domain: "source", code: 1, userInfo: [NSLocalizedDescriptionKey: "所选进程已停止输出，请重新选择"]) }
        let description = selected.map { CATapDescription(stereoMixdownOfProcesses: [$0.id]) } ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "创建音频 tap")
        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var prop = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tap, &prop, 0, nil, &size, &asbd), "读取音频格式")
        guard let audioFormat = AVAudioFormat(streamDescription: &asbd) else { throw NSError(domain: "format", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的音频格式"]) }
        format = audioFormat
        let uid = UUID().uuidString
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "音频字幕", kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]]
        try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &device), "创建音频设备")
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, captureQueue) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.format else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, format.streamDescription.pointee.mBytesPerFrame > 0 else { return }
            let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard destination.count == list.count else { return }
            for i in 0..<list.count {
                guard let src = list[i].mData, let dst = destination[i].mData else { continue }
                memcpy(dst, src, min(Int(list[i].mDataByteSize), Int(destination[i].mDataByteSize)))
            }
            self.enqueueAudio(buffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastMeterUpdate >= 1 {
                self.lastMeterUpdate = now
                var peak: Float = 0
                if format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
                    let channelCount = Int(format.channelCount)
                    let stride = format.isInterleaved ? channelCount : 1
                    for channel in 0..<(format.isInterleaved ? 1 : channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            for offset in 0..<(format.isInterleaved ? channelCount : 1) {
                                peak = max(peak, abs(channels[channel][frame * stride + offset]))
                            }
                        }
                    }
                }
                let level = peak
                let supportsMeter = format.commonFormat == .pcmFormatFloat32
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.audioState.title = supportsMeter ? (level > 0.0001 ? "音频：收到声音" : "音频：收到数据，但接近静音") : "音频：收到数据（此格式不支持音量检测）"
                }
            }
        }, "创建音频回调")
        try check(AudioDeviceStart(device, io), "启动音频捕获（请检查系统音频录制权限）")
    }
    // The capture callback never waits for speech recognition. The queue has a
    // fixed budget; overload is reported explicitly instead of silently growing.
    private func enqueueAudio(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        bufferLock.lock()
        capturedAudio.append(buffer); capturedDuration += duration
        while capturedDuration > 5, !capturedAudio.isEmpty {
            let removed = capturedAudio.removeFirst()
            let removedDuration = Double(removed.frameLength) / removed.format.sampleRate
            capturedDuration -= removedDuration; droppedDuration += removedDuration
        }
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        bufferLock.unlock()
        if shouldSchedule { recognitionQueue.async { [weak self] in self?.drainAudio() } }
    }
    private func drainAudio() {
        // Yield regularly so session changes are not starved by continuous audio.
        for _ in 0..<16 {
            bufferLock.lock()
            guard !capturedAudio.isEmpty else { drainScheduled = false; bufferLock.unlock(); return }
            let buffer = capturedAudio.removeFirst()
            capturedDuration -= Double(buffer.frameLength) / buffer.format.sampleRate
            let backlog = max(0, capturedDuration); let dropped = droppedDuration
            bufferLock.unlock()
            if let request { request.append(buffer) }
            else {
                pendingAudio.append(buffer)
                pendingDuration += Double(buffer.frameLength) / buffer.format.sampleRate
                while pendingDuration > 5, !pendingAudio.isEmpty {
                    let removed = pendingAudio.removeFirst()
                    let duration = Double(removed.frameLength) / removed.format.sampleRate
                    pendingDuration -= duration
                    bufferLock.lock(); droppedDuration += duration; bufferLock.unlock()
                }
            }
            if dropped > 0 || backlog > 1 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.bufferStatus.title = String(format: "音频缓冲：积压 %.1f 秒，丢弃 %.1f 秒", backlog, dropped)
                }
            }
        }
        recognitionQueue.async { [weak self] in self?.drainAudio() }
    }
    @objc private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "字幕历史"; window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false; view.isSelectable = true; view.font = NSFont.systemFont(ofSize: 16)
            view.isVerticallyResizable = true; view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view; window.contentView?.addSubview(scroll)
            historyWindow = window; historyView = view
        }
        refreshHistory(); historyWindow?.center(); historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func refreshHistory() {
        let text = (completedTranscripts + (latestTranscript.isEmpty ? [] : [latestTranscript])).joined(separator: "\n")
        historyView?.string = text
        if let view = historyView { view.scrollRangeToVisible(NSRange(location: (view.string as NSString).length, length: 0)) }
    }
    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else { fail("语音识别暂不可用"); return }
        let req = SFSpeechAudioBufferRecognitionRequest(); req.shouldReportPartialResults = true
        req.addsPunctuation = true
        let current = generation
        recognitionSession += 1
        let session = recognitionSession
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.active, self.recognitionSession == session else { return }
                if let result, !result.bestTranscription.formattedString.isEmpty {
                    self.consecutiveErrors = 0
                    self.state.title = "监听中：\(self.selected?.name ?? "全部来源（混合）")"
                    self.showTranscription(result.bestTranscription)
                }
                if result?.isFinal == true || error != nil {
                    if !self.currentCaption.isEmpty { self.lastCompletedCaption = self.currentCaption }
                    if !self.latestTranscript.isEmpty {
                        self.completedTranscripts.append(self.latestTranscript)
                        self.latestTranscript = ""
                        self.refreshHistory()
                    }
                    self.recognitionSession += 1
                    self.recognitionQueue.sync { self.request = nil }; self.task = nil
                    if let error {
                        let nsError = error as NSError
                        let noSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                        if !noSpeech { self.consecutiveErrors += 1 }
                        self.state.title = noSpeech ? "未检测到语音，继续监听" : "识别中断，正在重试：\(error.localizedDescription)（\(nsError.domain) \(nsError.code)）"
                        let delay = noSpeech ? 0.3 : min(5.0, 0.5 * pow(2.0, Double(min(self.consecutiveErrors, 4))))
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard self.generation == current, self.active else { return }; self.startRecognition()
                        }
                    } else {
                        self.startRecognition()
                    }
                }
            }
        }
        recognitionQueue.sync {
            request = req
            for buffer in pendingAudio { req.append(buffer) }
            pendingAudio.removeAll(); pendingDuration = 0
        }
    }
    private func showTranscription(_ transcription: SFTranscription) {
        latestTranscript = transcription.formattedString
        refreshHistory()
        let text = transcription.formattedString as NSString
        fullTranscript.title = "当前识别片段：" + transcription.formattedString
        let segments = transcription.segments
        var boundaries = [0]
        let punctuation = CharacterSet(charactersIn: "。！？!?；;，,\n")
        for index in 0..<text.length {
            if let scalar = UnicodeScalar(text.character(at: index)), punctuation.contains(scalar), index + 1 < text.length {
                boundaries.append(index + 1)
            }
        }
        if segments.count > 1 {
            for index in 1..<segments.count {
                let previous = segments[index - 1]
                let current = segments[index]
                if current.timestamp - (previous.timestamp + previous.duration) >= 0.8,
                   current.substringRange.location < text.length {
                    boundaries.append(current.substringRange.location)
                }
            }
        }
        boundaries = Array(Set(boundaries)).sorted()
        let start = boundaries.last ?? 0
        let current = text.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        let previous: String
        if boundaries.count > 1 {
            let priorStart = boundaries[boundaries.count - 2]
            previous = text.substring(with: NSRange(location: priorStart, length: start - priorStart)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            previous = lastCompletedCaption
        }
        guard !current.isEmpty else { return }
        currentCaption = current
        previousCaption.title = previous.isEmpty ? "上一段字幕" : "上一段：" + previous
        caption.title = "当前：" + current
        status.button?.title = "字幕: " + (current.count > 18 ? "…" : "") + String(current.suffix(18))
        status.button?.toolTip = [previous, current].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func fail(_ message: String) { stop(); state.title = message }
    private func stop() {
        generation += 1; recognitionSession += 1; consecutiveErrors = 0; active = false; starting = false
        if device != 0, let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        captureQueue.sync { format = nil; lastMeterUpdate = 0 }
        bufferLock.lock(); capturedAudio.removeAll(); capturedDuration = 0; droppedDuration = 0; bufferLock.unlock()
        recognitionQueue.sync { request?.endAudio(); request = nil; pendingAudio.removeAll(); pendingDuration = 0 }
        if !latestTranscript.isEmpty { completedTranscripts.append(latestTranscript); latestTranscript = ""; refreshHistory() }
        task?.cancel(); task = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        toggleItem.title = "开始监听"; status.button?.title = "字幕"; state.title = "已停止"; audioState.title = "音频：尚未开始"
    }
    func applicationWillTerminate(_ notification: Notification) { stop() }
}
let app = NSApplication.shared
let delegate = AudioCaptions()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
