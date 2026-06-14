import Foundation
import Vision

final class OCRService {
    func recognizeText(inFileAt imageURL: URL,
                       imageWidth: Int,
                       imageHeight: Int,
                       sourceLanguage: String) async throws -> String {
        do {
            let text = try await recognizeTextOutOfProcess(
                inFileAt: imageURL,
                sourceLanguage: sourceLanguage
            )
            AppLog.debug("OCR 子进程完成 image=\(imageWidth)x\(imageHeight) chars=\(text.count)")
            return text
        } catch {
            AppLog.error("OCR 子进程失败，回退到主进程识别: \(error.localizedDescription)")
            return try await recognizeTextInProcess(
                inFileAt: imageURL,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                sourceLanguage: sourceLanguage
            )
        }
    }

    static func recognizeTextForCommandLine(inFileAt imageURL: URL,
                                            sourceLanguage: String) throws -> String {
        try recognizeTextSynchronously(inFileAt: imageURL, sourceLanguage: sourceLanguage)
    }

    private func recognizeTextOutOfProcess(inFileAt imageURL: URL,
                                           sourceLanguage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let executableURL = Bundle.main.executableURL else {
                        throw ScreenCaptureError.failed("无法定位 OCR 子进程可执行文件")
                    }

                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = [
                        "--autotranslator-ocr",
                        "--image", imageURL.path,
                        "--source-language", sourceLanguage,
                    ]

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    var outputData = Data()
                    var errorData = Data()
                    let readGroup = DispatchGroup()

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    try process.run()
                    process.waitUntilExit()
                    readGroup.wait()

                    if !errorData.isEmpty,
                       let stderrText = String(data: errorData, encoding: .utf8),
                       !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AppLog.debug(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8) ?? "OCR 子进程退出码 \(process.terminationStatus)"
                        throw ScreenCaptureError.failed(String(message.prefix(200)))
                    }

                    continuation.resume(returning: String(data: outputData, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func recognizeTextInProcess(inFileAt imageURL: URL,
                                        imageWidth: Int,
                                        imageHeight: Int,
                                        sourceLanguage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        let text = try Self.recognizeTextSynchronously(
                            inFileAt: imageURL,
                            sourceLanguage: sourceLanguage
                        )
                        AppLog.debug("OCR 主进程回退完成 image=\(imageWidth)x\(imageHeight) chars=\(text.count)")
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func recognizeText(in image: CGImage, imageURL: URL?, sourceLanguage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        let attempts = Self.recognitionLanguageAttempts(for: sourceLanguage)
                        var attemptSummaries: [String] = []

                        if let imageURL {
                            for languages in attempts {
                                let result = try Self.recognizeText(inFileAt: imageURL, languages: languages)
                                attemptSummaries.append(
                                    "file/\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")):\(result.observationCount)"
                                )
                                let text = result.text
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    AppLog.debug("OCR 识别成功 source=file image=\(image.width)x\(image.height) languages=\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")) observations=\(result.observationCount) chars=\(text.count)")
                                    continuation.resume(returning: text)
                                    return
                                }
                            }
                        }

                        for languages in attempts {
                            let result = try Self.recognizeText(in: image, languages: languages)
                            attemptSummaries.append(
                                "cgImage/\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")):\(result.observationCount)"
                            )
                            let text = result.text
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                AppLog.debug("OCR 识别成功 source=cgImage image=\(image.width)x\(image.height) languages=\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")) observations=\(result.observationCount) chars=\(text.count)")
                                continuation.resume(returning: text)
                                return
                            }
                        }

                        AppLog.debug("OCR 未识别到文字 image=\(image.width)x\(image.height) attempts=\(attemptSummaries.joined(separator: ","))")
                        continuation.resume(returning: "")
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func recognizeText(in image: CGImage, sourceLanguage: String) async throws -> String {
        try await recognizeText(in: image, imageURL: nil, sourceLanguage: sourceLanguage)
    }

    private nonisolated static func recognizeTextSynchronously(inFileAt imageURL: URL,
                                                               sourceLanguage: String) throws -> String {
        let attempts = recognitionLanguageAttempts(for: sourceLanguage)
        var attemptSummaries: [String] = []

        for languages in attempts {
            let result = try recognizeText(inFileAt: imageURL, languages: languages)
            attemptSummaries.append(
                "file/\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")):\(result.observationCount)"
            )
            let text = result.text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppLog.debug("OCR 识别成功 source=file languages=\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")) observations=\(result.observationCount) chars=\(text.count)")
                return text
            }
        }

        AppLog.debug("OCR 未识别到文字 attempts=\(attemptSummaries.joined(separator: ","))")
        return ""
    }

    private nonisolated static func recognizeText(inFileAt url: URL,
                                                  languages: [String]) throws -> RecognitionResult {
        let request = makeTextRequest(languages: languages)
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        return recognitionResult(from: request)
    }

    private nonisolated static func recognizeText(in image: CGImage,
                                                  languages: [String]) throws -> RecognitionResult {
        let request = makeTextRequest(languages: languages)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return recognitionResult(from: request)
    }

    private nonisolated static func makeTextRequest(languages: [String]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0

        let supportedLanguages = supportedLanguages(from: languages, request: request)
        if !supportedLanguages.isEmpty {
            request.recognitionLanguages = supportedLanguages
        }

        return request
    }

    private nonisolated static func recognitionResult(from request: VNRecognizeTextRequest) -> RecognitionResult {
        let observations = request.results ?? []
        let lines = observations
            .sorted(by: readingOrder)
            .compactMap { observation -> String? in
                let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? nil : text
            }

        return RecognitionResult(
            text: lines.joined(separator: "\n"),
            languages: request.recognitionLanguages,
            observationCount: observations.count
        )
    }

    private struct RecognitionResult {
        let text: String
        let languages: [String]
        let observationCount: Int
    }

    private nonisolated static func readingOrder(_ lhs: VNRecognizedTextObservation,
                                                 _ rhs: VNRecognizedTextObservation) -> Bool {
        let yDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
        if yDelta > 0.025 {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    private nonisolated static func recognitionLanguageAttempts(for sourceLanguage: String) -> [[String]] {
        var attempts: [[String]] = []

        if let language = visionLanguageCode(for: sourceLanguage) {
            attempts.append([language])
        }

        attempts.append(["zh-Hans", "zh-Hant", "en-US"])
        attempts.append(["en-US"])
        attempts.append([])

        var seen = Set<String>()
        return attempts.filter { languages in
            let key = languages.joined(separator: "|")
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private nonisolated static func supportedLanguages(from candidates: [String],
                                                       request: VNRecognizeTextRequest) -> [String] {
        guard !candidates.isEmpty else { return [] }
        guard let supported = try? request.supportedRecognitionLanguages() else {
            return candidates
        }
        return candidates.filter { supported.contains($0) }
    }

    private nonisolated static func visionLanguageCode(for languageCode: String) -> String? {
        switch languageCode {
        case "zh-CN": return "zh-Hans"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "ru": return "ru-RU"
        default: return nil
        }
    }
}
