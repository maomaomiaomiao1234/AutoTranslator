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
    let imageURL: URL
    let width: Int
    let height: Int
}

enum ScreenCaptureService {
    private nonisolated static let interactiveCaptureTimeout: TimeInterval = 300

    @MainActor
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    nonisolated static func captureInteractively() async throws -> ScreenCaptureResult {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTranslator-OCR-\(UUID().uuidString).png")

        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-i", "-s", "-x", fileURL.path],
                timeout: interactiveCaptureTimeout
            )

            guard result.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                removeCapturedImage(at: fileURL)
                throw ScreenCaptureError.cancelled
            }

            guard let properties = imageProperties(at: fileURL) else {
                removeCapturedImage(at: fileURL)
                throw ScreenCaptureError.failed("无法读取截图图像")
            }

            // 临时文件交由调用方在 OCR 用完后通过 removeCapturedImage 清理。
            AppLog.debug("截图已捕获 image=\(properties.width)x\(properties.height)")
            return ScreenCaptureResult(
                imageURL: fileURL,
                width: properties.width,
                height: properties.height
            )
        } catch {
            removeCapturedImage(at: fileURL)
            throw error
        }
    }

    private nonisolated static func imageProperties(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// 删除截图临时文件。调用方在 OCR 用完截图后应调用此方法清理。
    nonisolated static func removeCapturedImage(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
