import AppKit
import CoreGraphics
import ImageIO

enum ScreenCaptureError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消截图翻译"
        case .failed(let message):
            return message
        }
    }
}

struct ScreenCaptureResult {
    let image: CGImage
    let debugURL: URL?
}

enum ScreenCaptureService {
    @MainActor
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    nonisolated static func captureInteractively() async throws -> ScreenCaptureResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AutoTranslator-OCR-\(UUID().uuidString).png")

                defer {
                    try? FileManager.default.removeItem(at: fileURL)
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-s", "-x", fileURL.path]

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard process.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    continuation.resume(throwing: ScreenCaptureError.cancelled)
                    return
                }

                let debugURL = saveDebugCapture(from: fileURL)

                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(throwing: ScreenCaptureError.failed("无法读取截图图像"))
                    return
                }

                fputs(
                    "[AutoTranslator] 原始截图已保存 image=\(image.width)x\(image.height) debugImage=\(debugURL?.path ?? "none")\n",
                    stderr
                )
                continuation.resume(returning: ScreenCaptureResult(image: image, debugURL: debugURL))
            }
        }
    }

    private nonisolated static func saveDebugCapture(from sourceURL: URL) -> URL? {
        let debugURL = URL(fileURLWithPath: "/tmp/AutoTranslator-last-capture.png")
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: debugURL.path) {
                try fileManager.removeItem(at: debugURL)
            }
            try fileManager.copyItem(at: sourceURL, to: debugURL)
            return debugURL
        } catch {
            fputs("[AutoTranslator] 保存原始截图失败: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
