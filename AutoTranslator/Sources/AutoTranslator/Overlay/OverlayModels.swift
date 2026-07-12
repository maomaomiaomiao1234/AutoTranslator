import CoreGraphics
import Foundation

// MARK: - 结构化 OCR 模型

/// OCR 识别出的一行文字。坐标为图像像素、左上原点（区别于 Vision 的
/// 归一化左下原点），这样子进程 JSON、块聚合与绘制共用同一坐标系。
/// nonisolated：在 OCR 后台队列与子进程 JSON 编解码中使用。
nonisolated struct OCRLine: Codable, Equatable, Sendable {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(text: String, rect: CGRect) {
        self.text = text
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

/// 结构化 OCR 结果；子进程通过 `--structured --output <path>` 写出同构 JSON。
nonisolated struct OCRStructuredResult: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let lines: [OCRLine]
}

/// 由相邻 OCR 行聚合出的段落块：整块送翻译（避免按行翻译拆散句子），
/// 译文按块矩形排版回填。
nonisolated struct TextBlock: Equatable, Sendable {
    let lines: [OCRLine]
    /// 所有行矩形的并集（图像像素、左上原点）。
    let pxRect: CGRect
    /// 送翻译的整块文本（按脚本决定行间以空格或直接相连）。
    let text: String
    /// 行高中位数（像素），用作译文初始字号的依据。
    let medianLineHeightPx: CGFloat
}

// MARK: - 坐标换算（纯函数，便于单测）

nonisolated enum OverlayGeometry {
    /// Vision 归一化框（[0,1]、左下原点）→ 图像像素框（左上原点）。
    static func pixelRect(fromNormalized normalized: CGRect,
                          imageWidth: Int,
                          imageHeight: Int) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        return CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.minY - normalized.height) * height,
            width: normalized.width * width,
            height: normalized.height * height
        )
    }

    /// AppKit 全局屏幕矩形（左下原点）→ CG 全局矩形（左上原点）。
    /// `screencapture -R` 使用 CG 坐标；主屏（`NSScreen.screens[0]`）的
    /// AppKit origin 恒为 (0,0)，两套坐标以主屏高度互为翻转。
    static func cgGlobalRect(fromAppKit rect: CGRect,
                             primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
