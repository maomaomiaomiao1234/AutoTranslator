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

    func speak(_ text: String, languageHint _: String) async throws {
        let input = Self.normalizedInput(text)
        guard !input.isEmpty else { return }

        stop()
        let data = try await Self.requestSpeechAudio(input: input)
        try Task.checkCancellation()

        let nextPlayer = try AVAudioPlayer(data: data)
        nextPlayer.prepareToPlay()
        nextPlayer.play()
        player = nextPlayer
    }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated private static func requestSpeechAudio(input: String) async throws -> Data {
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
                "format": resolvedConfigValue("TTS_AUDIO_FORMAT", fallback: "wav"),
                "sample_rate": resolvedIntConfigValue("TTS_SAMPLE_RATE", fallback: 24000),
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        guard trimmed.count > 4096 else { return trimmed }
        return String(trimmed.prefix(4096))
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
            return decodeBase64Data(string)
        }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["audio", "audio_data", "audioData", "audio_base64", "base64", "data", "b64_json"]
            for key in preferredKeys {
                if let string = dictionary[key] as? String,
                   let decoded = decodeBase64Data(string) {
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
            for key in ["message", "error_message", "code"] {
                if let string = dictionary[key] as? String, !string.isEmpty {
                    return string
                }
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
            guard chunkDataStart + chunkSize <= data.count else { return nil }
            if chunkID == "data" {
                return WAVLayout(
                    dataSizeOffset: offset + 4,
                    dataStart: chunkDataStart,
                    dataSize: chunkSize
                )
            }
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }
        return nil
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

    nonisolated private static func writeUInt32LE(_ value: UInt32, to data: inout Data, at offset: Int) {
        guard offset + 4 <= data.count else { return }
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}
