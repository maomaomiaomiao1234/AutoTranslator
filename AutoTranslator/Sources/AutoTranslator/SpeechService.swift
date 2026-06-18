import AVFoundation
import Foundation

@MainActor
final class SpeechService {
    nonisolated static let defaultModel = "cosyvoice-v3-flash"
    nonisolated static let defaultVoice = "longanyang"
    nonisolated static let defaultEndpoint = "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer"
    nonisolated private static let dashScopeSpeechSynthesizerPath = "/api/v1/services/audio/tts/SpeechSynthesizer"
    nonisolated private static let legacyMiniMaxModel = "MiniMax/speech-2.8-turbo"
    nonisolated private static let legacyMiniMaxVoice = "male-qn-qingse"
    nonisolated private static let legacyMultimodalGenerationPath = "/api/v1/services/aigc/multimodal-generation/generation"

    private nonisolated static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    private var player: AVAudioPlayer?
    /// 复用同一个 AVAudioEngine 实例，避免每次发音都销毁并立即重建引擎。
    /// 销毁与重建之间若无间隔（命中音频缓存即时重放时尤为明显），CoreAudio
    /// 尚未异步释放上一个引擎的输出节点，新引擎会静默无声——表现为“第二次划词不发音、
    /// 等十几秒后又正常”。保持引擎常驻可彻底规避该竞态。
    private let streamingPlayer = StreamingAudioPlayer()

    /// 当音频真正开始播放时回调（主线程）。供上层把朗读状态从「准备中」翻为「播放中」，
    /// 不再依赖固定估时——长句也能在真实播放期间持续显示播放态。
    var onPlaybackStarted: (() -> Void)?

    init() {
        streamingPlayer.onPlaybackStarted = { [weak self] in
            self?.onPlaybackStarted?()
        }
    }

    /// 缓存最近合成的音频：避免对同一文本（如词典自动朗读高频词）重复请求 TTS。
    /// 存储实时播放时入队的原始音频块，命中时按序重放，行为与现网一致。
    private var capturedChunks: [Data] = []
    private let audioCache = LRUCache<String, [Data]>(capacity: 32)
    nonisolated private static let maxCacheableAudioBytes = 8 * 1024 * 1024

    /// DashScope CosyVoice 按「字符数」限制单次合成（v3 系列：SDK/Android 2000、WebSocket 20000，
    /// 累计约 20 万）。本 app 走 HTTP+SSE，介于两档之间、官方未明示，故按最保守的 2000 设计。
    /// 关键：汉字（含简繁、日韩汉字）按 2 个字符计，其余按 1 个；故按此规则计数后再分段，
    /// 段上限留足余量低于 2000，避免中文文本因「汉字×2」实际超限。
    nonisolated private static let maxTotalInputLength = 10000
    nonisolated private static let speechSegmentSoftLimit = 1000
    nonisolated private static let speechSegmentHardLimit = 1800

    func speak(_ text: String, languageHint _: String) async throws {
        let input = Self.normalizedInput(text)
        guard !input.isEmpty else { return }

        stop()
        let format = Self.resolvedAudioFormat()
        let cacheKey = Self.audioCacheKey(input: input, format: format)

        if format == "wav" {
            // stop() 之上已清空上一段排队缓冲并保留常驻引擎，可直接复用。
            do {
                if let cached = audioCache.value(forKey: cacheKey) {
                    for chunk in cached {
                        try Task.checkCancellation()
                        try streamingPlayer.enqueue(chunk)
                    }
                } else {
                    capturedChunks = []
                    for segment in Self.splitIntoSpeechSegments(input) {
                        try Task.checkCancellation()
                        try await streamSpeechAudio(input: segment, player: streamingPlayer)
                    }
                    try Task.checkCancellation()
                    storeCapturedAudio(forKey: cacheKey)
                }
            } catch {
                stop()
                throw error
            }
            return
        }

        do {
            let data: Data
            if let cached = audioCache.value(forKey: cacheKey)?.first {
                data = cached
            } else {
                // 非 wav（如 mp3）走单次合成 + AVAudioPlayer 整段播放，无法无缝拼接多段；
                // 故取首个安全分段（已按接口字符上限切分）请求，避免超长文本报 InvalidParameter。
                let requestInput = Self.splitIntoSpeechSegments(input).first ?? input
                let fetched = try await Self.requestSpeechAudio(input: requestInput)
                try Task.checkCancellation()
                if fetched.count <= Self.maxCacheableAudioBytes {
                    audioCache.setValue([fetched], forKey: cacheKey)
                }
                data = fetched
            }
            try Task.checkCancellation()

            let nextPlayer = try AVAudioPlayer(data: data)
            nextPlayer.prepareToPlay()
            nextPlayer.play()
            player = nextPlayer
            onPlaybackStarted?()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        capturedChunks = []
        streamingPlayer.stopPlayback()
        player?.stop()
        player = nil
    }

    /// 当前正在播放音频的剩余时长（秒）；无播放时返回 nil。
    /// 流式 PCM 按已排队帧数/采样率精确推算，AVAudioPlayer 直接用 duration-currentTime。
    /// 供上层据此精确安排「播放结束」回到空闲态，避免固定估时把长句过早判为结束。
    func currentPlaybackRemainingDuration() -> TimeInterval? {
        if let player, player.isPlaying {
            let remaining = player.duration - player.currentTime
            return remaining > 0 ? remaining : nil
        }
        return streamingPlayer.remainingPlaybackDuration
    }

    /// 入队播放并同时记录音频块，供合成成功后写入缓存。
    private func enqueueAndCapture(_ data: Data, to player: StreamingAudioPlayer) throws {
        capturedChunks.append(data)
        try player.enqueue(data)
    }

    /// 将本次合成捕获的音频块写入缓存（受总大小上限约束）。
    private func storeCapturedAudio(forKey key: String) {
        let chunks = capturedChunks
        capturedChunks = []
        guard !chunks.isEmpty else { return }
        let total = chunks.reduce(0) { $0 + $1.count }
        guard total > 0, total <= Self.maxCacheableAudioBytes else { return }
        audioCache.setValue(chunks, forKey: key)
    }

    nonisolated private static func audioCacheKey(input: String, format: String) -> String {
        "\(resolvedSpeechModel())|\(resolvedSpeechVoice())|\(format)|\(input)"
    }

    private func streamSpeechAudio(input: String, player: StreamingAudioPlayer) async throws {
        let request = try Self.speechRequest(input: input)
        let (bytes, response) = try await Self.sharedSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count >= 1024 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            throw RuntimeError("TTS API HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        AppLog.debug("TTS 流式响应 Content-Type: \(contentType.isEmpty ? "<empty>" : contentType)")
        guard contentType.contains("text/event-stream") else {
            let data = try await Self.collect(bytes)
            let audio = if contentType.contains("audio/") || Self.isLikelyAudio(data) {
                data
            } else if Self.looksLikeSSE(data) {
                try Self.extractAudioDataFromSSE(data)
            } else {
                try await Self.extractAudioData(from: data)
            }
            try enqueueAndCapture(audio, to: player)
            return
        }

        var eventLines: [String] = []
        var dataEventCount = 0
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                try processStreamingEvent(eventLines.joined(separator: "\n"), player: player)
                eventLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataEventCount += 1
                if payload.hasPrefix("{") || payload == "[DONE]" {
                    try processStreamingEvent(payload, player: player)
                } else {
                    eventLines.append(payload)
                }
            }
        }
        if !eventLines.isEmpty {
            try processStreamingEvent(eventLines.joined(separator: "\n"), player: player)
        }

        guard player.hasStarted else {
            throw RuntimeError("TTS SSE 未找到音频数据，data 事件数=\(dataEventCount)")
        }
    }

    private func processStreamingEvent(_ event: String, player: StreamingAudioPlayer) throws {
        let payload = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return }

        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) else {
            if let audio = Self.decodeBase64Data(payload), audio.count > 32 {
                try enqueueAndCapture(audio, to: player)
            }
            return
        }

        if let audio = Self.findBase64AudioChunk(in: json) {
            AppLog.debug("TTS 流式音频块 bytes=\(audio.count)")
            try enqueueAndCapture(audio, to: player)
            return
        }
        if let message = Self.findErrorMessage(in: json),
           !Self.isNonFinalSynthesisEvent(json) {
            throw RuntimeError("TTS API 返回错误: \(message)")
        }
    }

    nonisolated private static func requestSpeechAudio(input: String) async throws -> Data {
        let request = try speechRequest(input: input)
        let (data, response) = try await sharedSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("TTS API HTTP \(http.statusCode): \(body.prefix(200))")
        }
        guard !data.isEmpty else {
            throw RuntimeError("TTS API 返回为空")
        }
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        if contentType.contains("audio/") || isLikelyAudio(data) {
            return data
        }
        if contentType.contains("text/event-stream") || looksLikeSSE(data) {
            return try extractAudioDataFromSSE(data)
        }
        return try await extractAudioData(from: data)
    }

    nonisolated private static func speechRequest(input: String) throws -> URLRequest {
        let apiKey = try resolvedAPIKey()
        let url = try speechURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")

        let body: [String: Any] = [
            "model": resolvedSpeechModel(),
            "input": [
                "text": input,
                "voice": resolvedSpeechVoice(),
                "format": resolvedAudioFormat(),
                "sample_rate": resolvedIntConfigValue("TTS_SAMPLE_RATE", fallback: 24000),
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private final class StreamingAudioPlayer {
        private let engine = AVAudioEngine()
        private let playerNode = AVAudioPlayerNode()
        private var pcmFormat: AVAudioFormat?
        private var bytesPerFrame = 2
        private var channelCount = 1
        private var scheduledFrameCount = 0
        private(set) var hasStarted = false

        /// 首个音频缓冲开始播放时回调（同步在调用 enqueue 的主线程上）。
        var onPlaybackStarted: (() -> Void)?
        /// 播放真正开始的时刻（systemUptime），用于推算剩余时长。
        private var playbackStartUptime: TimeInterval = 0

        init() {
            engine.attach(playerNode)
        }

        /// 已排队音频的剩余播放时长：总帧数/采样率 - 已播放时间；未开始播放返回 nil。
        var remainingPlaybackDuration: TimeInterval? {
            guard hasStarted, let pcmFormat, pcmFormat.sampleRate > 0 else { return nil }
            let total = Double(scheduledFrameCount) / pcmFormat.sampleRate
            let elapsed = ProcessInfo.processInfo.systemUptime - playbackStartUptime
            return max(0, total - elapsed)
        }

        func enqueue(_ data: Data) throws {
            guard !data.isEmpty else { return }

            let payload: Data
            if let description = SpeechService.wavDescription(data) {
                try configure(description: description)
                payload = data.subdata(in: description.payloadRange)
            } else {
                if pcmFormat == nil {
                    try configure(
                        sampleRate: Double(SpeechService.resolvedIntConfigValue("TTS_SAMPLE_RATE", fallback: 24000)),
                        channels: 1,
                        bitsPerSample: 16,
                        blockAlign: 2
                    )
                }
                payload = data
            }

            try enqueuePCM(payload)
        }

        /// 结束当前发音并清空排队的缓冲，但保持引擎常驻运行，
        /// 以便下一段发音即时复用、规避引擎重建竞态。
        func stopPlayback() {
            playerNode.stop()
            scheduledFrameCount = 0
            hasStarted = false
        }

        private func configure(description: WAVDescription) throws {
            try configure(
                sampleRate: description.sampleRate,
                channels: description.channels,
                bitsPerSample: description.bitsPerSample,
                blockAlign: description.blockAlign
            )
        }

        private func configure(sampleRate: Double, channels: Int, bitsPerSample: Int, blockAlign: Int) throws {
            guard bitsPerSample == 16 else {
                throw RuntimeError("TTS 流式播放仅支持 16-bit PCM WAV")
            }
            guard channels > 0, channels <= 2, sampleRate > 0, blockAlign > 0 else {
                throw RuntimeError("TTS 流式音频格式无效")
            }
            // 引擎常驻复用：若新内容格式与已配置的一致则无需重连。
            if let existing = pcmFormat,
               existing.sampleRate == sampleRate,
               Int(existing.channelCount) == channels,
               bytesPerFrame == blockAlign {
                return
            }
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ) else {
                throw RuntimeError("无法创建 TTS 流式音频格式")
            }

            // 切换格式需在节点停止状态下重连。
            if engine.isRunning {
                playerNode.stop()
            }
            pcmFormat = format
            bytesPerFrame = blockAlign
            channelCount = channels
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
            AppLog.debug("TTS 流式播放器初始化 sampleRate=\(Int(sampleRate)) channels=\(channels) blockAlign=\(blockAlign)")
        }

        private func enqueuePCM(_ data: Data) throws {
            guard let pcmFormat else {
                throw RuntimeError("TTS 流式音频格式未初始化")
            }

            let byteCount = (data.count / bytesPerFrame) * bytesPerFrame
            guard byteCount > 0 else { return }
            let frameCount = byteCount / bytesPerFrame
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw RuntimeError("无法创建 TTS 流式音频缓冲区")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channelData = buffer.floatChannelData else {
                throw RuntimeError("无法写入 TTS 流式音频缓冲区")
            }
            data.withUnsafeBytes { source in
                guard let bytes = source.bindMemory(to: UInt8.self).baseAddress else { return }
                for frame in 0..<frameCount {
                    let frameOffset = frame * bytesPerFrame
                    for channel in 0..<channelCount {
                        let sampleOffset = frameOffset + channel * 2
                        guard sampleOffset + 1 < byteCount else { continue }
                        let rawSample = UInt16(bytes[sampleOffset])
                            | (UInt16(bytes[sampleOffset + 1]) << 8)
                        let sample = Int16(bitPattern: rawSample)
                        channelData[channel][frame] = Float(sample) / 32768.0
                    }
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
            scheduledFrameCount += frameCount
            AppLog.debug("TTS 流式播放器排队 frames=\(frameCount) totalFrames=\(scheduledFrameCount)")
            if !hasStarted {
                playbackStartUptime = ProcessInfo.processInfo.systemUptime
                hasStarted = true
                onPlaybackStarted?()
            }
        }
    }

    nonisolated private static func resolvedAPIKey() throws -> String {
        let key = ProcessInfo.processInfo.environment["TTS_API_KEY"]
            ?? ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ProcessInfo.processInfo.environment["LLM_API_KEY"]
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw RuntimeError("未设置 TTS/DashScope API Key")
        }
        return trimmed
    }

    nonisolated private static func speechURL() throws -> URL {
        let configured = normalizedStoredEndpoint(ProcessInfo.processInfo.environment["TTS_BASE_URL"])
        let endpoint = configured.isEmpty ? defaultEndpoint : normalizeEndpoint(configured)
        guard let url = URL(string: endpoint) else {
            throw RuntimeError("TTS Endpoint 无效: \(endpoint)")
        }
        return url
    }

    nonisolated private static func normalizedInput(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTotalInputLength else { return trimmed }
        return String(trimmed.prefix(maxTotalInputLength))
    }

    /// 将长文本切分为若干不超过接口单次上限的小段，尽量在断句标点处切，
    /// 以保证每段都是较完整的语句、合成韵律更自然；无标点的超长文本按硬上限强制切。
    /// 短/中等长度（≤硬上限）的文本原样返回单段，保持既有单请求行为与缓存命中不变。
    nonisolated private static func splitIntoSpeechSegments(_ text: String) -> [String] {
        guard text.count > speechSegmentHardLimit else { return [text] }

        let terminators: Set<Character> = ["。", "！", "？", "；", "…", ".", "!", "?", ";", "\n"]
        var segments: [String] = []
        var current = ""
        var length = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
            length = 0
        }

        for char in text {
            current.append(char)
            length += Self.dashScopeCharCount(char)
            if length >= speechSegmentHardLimit {
                flush()
            } else if length >= speechSegmentSoftLimit, terminators.contains(char) {
                flush()
            }
        }
        flush()
        return segments.isEmpty ? [text] : segments
    }

    /// 按 DashScope 计数规则估算单个字符占用的「字符数」：汉字（含简繁、日韩汉字）计 2，其余计 1。
    nonisolated private static func dashScopeCharCount(_ char: Character) -> Int {
        for scalar in char.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value)      // CJK 统一表意文字
                || (0x3400...0x4DBF).contains(value)  // 扩展 A
                || (0xF900...0xFAFF).contains(value)  // 兼容表意文字
                || (0x20000...0x2A6DF).contains(value) // 扩展 B
                || (0x2A700...0x2EBEF).contains(value) { // 扩展 C–F
                return 2
            }
        }
        return 1
    }

    nonisolated private static func resolvedConfigValue(_ envKey: String, fallback: String) -> String {
        let value = ProcessInfo.processInfo.environment[envKey]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated private static func resolvedSpeechModel() -> String {
        let value = normalizedStoredModel(ProcessInfo.processInfo.environment["TTS_MODEL"])
        return value.isEmpty ? defaultModel : value
    }

    nonisolated private static func resolvedSpeechVoice() -> String {
        let value = normalizedStoredVoice(ProcessInfo.processInfo.environment["TTS_VOICE"])
        return value.isEmpty ? defaultVoice : value
    }

    nonisolated private static func resolvedAudioFormat() -> String {
        resolvedConfigValue("TTS_AUDIO_FORMAT", fallback: "wav")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
    }

    nonisolated static func normalizedStoredModel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed == legacyMiniMaxModel ? "" : trimmed
    }

    nonisolated static func normalizedStoredVoice(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed == legacyMiniMaxVoice ? "" : trimmed
    }

    nonisolated static func normalizedStoredEndpoint(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.contains(legacyMultimodalGenerationPath) ? "" : trimmed
    }

    nonisolated private static func resolvedIntConfigValue(_ envKey: String, fallback: Int) -> Int {
        let value = ProcessInfo.processInfo.environment[envKey]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(trimmed) ?? fallback
    }

    nonisolated private static func normalizeBaseURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated private static func normalizeEndpoint(_ value: String) -> String {
        let normalized = normalizeBaseURL(value)
        if normalized.hasSuffix(dashScopeSpeechSynthesizerPath) {
            return normalized
        }
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme,
              let host = components.host else {
            return normalized
        }

        let port = components.port.map { ":\($0)" } ?? ""
        let root = "\(scheme)://\(host)\(port)"
        if host == "dashscope.aliyuncs.com" {
            return root + dashScopeSpeechSynthesizerPath
        }
        return normalized + dashScopeSpeechSynthesizerPath
    }

    nonisolated private static func extractAudioDataFromSSE(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeError("TTS SSE 返回格式异常")
        }

        var chunks: [Data] = []
        var eventLines: [String] = []
        var lastMessage = ""

        func processEvent(_ event: String) {
            let payload = event.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { return }

            if let jsonData = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) {
                if let audio = findBase64AudioChunk(in: json) {
                    chunks.append(audio)
                    return
                }
                if let message = findErrorMessage(in: json) {
                    lastMessage = message
                }
                return
            }

            if let decoded = decodeBase64Data(payload), decoded.count > 32 {
                chunks.append(decoded)
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                processEvent(eventLines.joined(separator: "\n"))
                eventLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("data:") {
                eventLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !eventLines.isEmpty {
            processEvent(eventLines.joined(separator: "\n"))
        }

        guard !chunks.isEmpty else {
            if !lastMessage.isEmpty {
                throw RuntimeError("TTS API 返回错误: \(lastMessage)")
            }
            throw RuntimeError("TTS SSE 返回格式异常，未找到音频数据")
        }
        return concatenateAudioChunks(chunks)
    }

    nonisolated private static func extractAudioData(from data: Data) async throws -> Data {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("TTS API 返回格式异常: \(body.prefix(200))")
        }

        if let base64 = findBase64Audio(in: json),
           let decoded = decodeBase64Audio(base64) {
            return decoded
        }

        if let urlString = findAudioURL(in: json),
           let url = URL(string: urlString) {
            return try await downloadAudio(from: url)
        }

        if let message = findErrorMessage(in: json) {
            throw RuntimeError("TTS API 返回错误: \(message)")
        }

        throw RuntimeError("TTS API 返回格式异常，未找到音频数据")
    }

    nonisolated private static func downloadAudio(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await sharedSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("TTS 音频下载 HTTP \(http.statusCode): \(body.prefix(200))")
        }
        guard !data.isEmpty else {
            throw RuntimeError("TTS 音频下载为空")
        }
        return data
    }

    nonisolated private static func findBase64Audio(in value: Any, parentKey: String = "") -> String? {
        if let string = value as? String {
            guard isAudioDataKey(parentKey) else { return nil }
            return decodeBase64Audio(string) == nil ? nil : string
        }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["b64_json", "base64", "audio_base64", "audioData", "audio_data", "data"]
            for key in preferredKeys {
                if let string = dictionary[key] as? String,
                   decodeBase64Audio(string) != nil {
                    return string
                }
            }
            for (key, child) in dictionary {
                if let found = findBase64Audio(in: child, parentKey: key) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findBase64Audio(in: child, parentKey: parentKey) {
                    return found
                }
            }
        }

        return nil
    }

    nonisolated private static func findBase64AudioChunk(in value: Any, parentKey: String = "") -> Data? {
        if let string = value as? String {
            guard isAudioDataKey(parentKey) else { return nil }
            guard let decoded = decodeBase64Data(string), !decoded.isEmpty else {
                return nil
            }
            return decoded
        }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["audio", "audio_data", "audioData", "audio_base64", "base64", "data", "b64_json"]
            for key in preferredKeys {
                if let string = dictionary[key] as? String,
                   let decoded = decodeBase64Data(string),
                   !decoded.isEmpty {
                    return decoded
                }
            }
            for (key, child) in dictionary {
                if let found = findBase64AudioChunk(in: child, parentKey: key) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findBase64AudioChunk(in: child, parentKey: parentKey) {
                    return found
                }
            }
        }

        return nil
    }

    nonisolated private static func findAudioURL(in value: Any, parentKey: String = "") -> String? {
        if let string = value as? String {
            guard isAudioURLString(string, parentKey: parentKey) else { return nil }
            return string
        }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["audio_url", "audioUrl", "file_url", "fileUrl", "url"]
            for key in preferredKeys {
                if let string = dictionary[key] as? String,
                   isAudioURLString(string, parentKey: key) {
                    return string
                }
            }
            for (key, child) in dictionary {
                if let found = findAudioURL(in: child, parentKey: key) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findAudioURL(in: child, parentKey: parentKey) {
                    return found
                }
            }
        }

        return nil
    }

    nonisolated private static func findErrorMessage(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in ["message", "error_message"] {
                if let string = dictionary[key] as? String, !string.isEmpty {
                    return string
                }
            }
            if let code = dictionary["code"] as? String,
               !code.isEmpty,
               code != "20000000" {
                return code
            }
            if let error = dictionary["error"] {
                if let string = error as? String, !string.isEmpty {
                    return string
                }
                if let found = findErrorMessage(in: error) {
                    return found
                }
            }
            for child in dictionary.values {
                if let found = findErrorMessage(in: child) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findErrorMessage(in: child) {
                    return found
                }
            }
        }

        return nil
    }

    nonisolated private static func isNonFinalSynthesisEvent(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else {
            return false
        }
        if let output = dictionary["output"] as? [String: Any] {
            if let type = output["type"] as? String,
               type.hasPrefix("sentence-") {
                return true
            }
            if let finishReason = output["finish_reason"] as? String,
               finishReason == "null" || finishReason == "stop" {
                return true
            }
        }
        return false
    }

    nonisolated private static func decodeBase64Audio(_ value: String) -> Data? {
        guard let decoded = decodeBase64Data(value), decoded.count > 32 else {
            return nil
        }
        return isLikelyAudio(decoded) ? decoded : nil
    }

    nonisolated private static func decodeBase64Data(_ value: String) -> Data? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = raw.firstIndex(of: ","),
           raw[..<comma].lowercased().contains("base64") {
            raw = String(raw[raw.index(after: comma)...])
        }
        raw = raw.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = raw.count % 4
        if padding > 0 {
            raw += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: raw)
    }

    nonisolated private static func isAudioDataKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("audio")
            || lowercased.contains("base64")
            || lowercased == "data"
            || lowercased == "b64_json"
    }

    nonisolated private static func isAudioURLString(_ value: String, parentKey: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            return false
        }
        let key = parentKey.lowercased()
        if key.contains("audio") || key.contains("url") {
            return true
        }
        return lowercased.contains(".mp3")
            || lowercased.contains(".wav")
            || lowercased.contains(".m4a")
            || lowercased.contains(".aac")
    }

    nonisolated private static func isLikelyAudio(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return true
        }
        if bytes.count >= 2, bytes[0] == 0xff, (bytes[1] & 0xe0) == 0xe0 {
            return true
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
            return true
        }
        if bytes.count >= 8,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return true
        }
        return false
    }

    nonisolated private static func looksLikeSSE(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return text.contains("data:")
    }

    nonisolated private static func concatenateAudioChunks(_ chunks: [Data]) -> Data {
        guard chunks.count > 1 else {
            return chunks.first ?? Data()
        }
        return concatenateWAVChunks(chunks) ?? chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
    }

    nonisolated private struct WAVLayout {
        let dataSizeOffset: Int
        let dataStart: Int
        let dataSize: Int
    }

    nonisolated private struct WAVDescription {
        let sampleRate: Double
        let channels: Int
        let bitsPerSample: Int
        let blockAlign: Int
        let payloadRange: Range<Int>
    }

    nonisolated private static func concatenateWAVChunks(_ chunks: [Data]) -> Data? {
        guard let first = chunks.first,
              let firstLayout = wavLayout(first) else {
            return nil
        }

        var output = first.prefix(firstLayout.dataStart)
        var audioPayload = Data()

        for chunk in chunks {
            if let layout = wavLayout(chunk),
               chunk.count >= layout.dataStart + layout.dataSize {
                audioPayload.append(chunk.subdata(in: layout.dataStart..<(layout.dataStart + layout.dataSize)))
            } else {
                audioPayload.append(chunk)
            }
        }

        output.append(audioPayload)
        writeUInt32LE(UInt32(max(0, output.count - 8)), to: &output, at: 4)
        writeUInt32LE(UInt32(audioPayload.count), to: &output, at: firstLayout.dataSizeOffset)
        return output
    }

    nonisolated private static func wavLayout(_ data: Data) -> WAVLayout? {
        guard data.count >= 44,
              fourCC(data, at: 0) == "RIFF",
              fourCC(data, at: 8) == "WAVE" else {
            return nil
        }

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = fourCC(data, at: offset)
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let chunkDataStart = offset + 8
            if chunkID == "data" {
                let availableSize = max(0, data.count - chunkDataStart)
                return WAVLayout(
                    dataSizeOffset: offset + 4,
                    dataStart: chunkDataStart,
                    dataSize: min(chunkSize, availableSize)
                )
            }
            guard chunkDataStart + chunkSize <= data.count else { return nil }
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }
        return nil
    }

    nonisolated private static func wavDescription(_ data: Data) -> WAVDescription? {
        guard data.count >= 44,
              fourCC(data, at: 0) == "RIFF",
              fourCC(data, at: 8) == "WAVE" else {
            return nil
        }

        var sampleRate: Double?
        var channels: Int?
        var bitsPerSample: Int?
        var blockAlign: Int?
        var payloadRange: Range<Int>?

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = fourCC(data, at: offset)
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let chunkDataStart = offset + 8

            if chunkID == "fmt " {
                guard chunkDataStart + 16 <= data.count else { return nil }
                let audioFormat = readUInt16LE(data, at: chunkDataStart)
                guard audioFormat == 1 else { return nil }
                channels = Int(readUInt16LE(data, at: chunkDataStart + 2))
                sampleRate = Double(readUInt32LE(data, at: chunkDataStart + 4))
                blockAlign = Int(readUInt16LE(data, at: chunkDataStart + 12))
                bitsPerSample = Int(readUInt16LE(data, at: chunkDataStart + 14))
            } else if chunkID == "data" {
                let availableSize = max(0, data.count - chunkDataStart)
                let payloadSize = min(chunkSize, availableSize)
                payloadRange = chunkDataStart..<(chunkDataStart + payloadSize)
                if let sampleRate, let channels, let bitsPerSample, let blockAlign {
                    return WAVDescription(
                        sampleRate: sampleRate,
                        channels: channels,
                        bitsPerSample: bitsPerSample,
                        blockAlign: blockAlign,
                        payloadRange: payloadRange!
                    )
                }
            }

            guard chunkDataStart + chunkSize <= data.count else { break }
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }

        guard let sampleRate, let channels, let bitsPerSample, let blockAlign, let payloadRange else {
            return nil
        }
        return WAVDescription(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            blockAlign: blockAlign,
            payloadRange: payloadRange
        )
    }

    nonisolated private static func fourCC(_ data: Data, at offset: Int) -> String? {
        guard offset + 4 <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
    }

    nonisolated private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    nonisolated private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated private static func writeUInt32LE(_ value: UInt32, to data: inout Data, at offset: Int) {
        guard offset + 4 <= data.count else { return }
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}
