import Foundation
import Vision

final class OCRService {
    func recognizeText(in image: CGImage, imageURL: URL?, sourceLanguage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
                                fputs(
                                    "[AutoTranslator] OCR 识别成功 source=file image=\(image.width)x\(image.height) languages=\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")) observations=\(result.observationCount) chars=\(text.count)\n",
                                    stderr
                                )
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
                            fputs(
                                "[AutoTranslator] OCR 识别成功 source=cgImage image=\(image.width)x\(image.height) languages=\(result.languages.isEmpty ? "default" : result.languages.joined(separator: "+")) observations=\(result.observationCount) chars=\(text.count)\n",
                                stderr
                            )
                            continuation.resume(returning: text)
                            return
                        }
                    }

                    fputs(
                        "[AutoTranslator] OCR 未识别到文字 image=\(image.width)x\(image.height) attempts=\(attemptSummaries.joined(separator: ","))\n",
                        stderr
                    )
                    continuation.resume(returning: "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func recognizeText(in image: CGImage, sourceLanguage: String) async throws -> String {
        try await recognizeText(in: image, imageURL: nil, sourceLanguage: sourceLanguage)
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
