import CoreGraphics
import Foundation

/// 把 OCR 行聚合为段落块。整块送翻译能保住被换行拆散的句子语义，
/// 也免去"译文行数与原文行数对齐"这类脆弱映射。纯函数、无隔离要求。
nonisolated enum TextBlockGrouper {

    static func group(lines: [OCRLine]) -> [TextBlock] {
        guard !lines.isEmpty else { return [] }

        let sorted = lines.sorted(by: readingOrder)
        var blocks: [[OCRLine]] = []
        var current: [OCRLine] = [sorted[0]]

        for line in sorted.dropFirst() {
            if let last = current.last, belongsToSameBlock(last, line) {
                current.append(line)
            } else {
                blocks.append(current)
                current = [line]
            }
        }
        blocks.append(current)

        return blocks.map(makeBlock)
    }

    // MARK: - 合并判定

    /// 相邻两行是否属于同一段落块。
    private static func belongsToSameBlock(_ previous: OCRLine, _ next: OCRLine) -> Bool {
        let a = previous.rect
        let b = next.rect
        let minHeight = min(a.height, b.height)
        guard minHeight > 0 else { return false }

        // 行高差异过大（如大标题 vs 正文）不合并。
        let heightRatio = a.height / b.height
        guard heightRatio >= 0.6, heightRatio <= 1.67 else { return false }

        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if verticalOverlap >= 0.5 * minHeight {
            // 同一视觉行被拆成多个片段：水平间距近才算同块（远则是并排栏目）。
            let horizontalGap = max(b.minX - a.maxX, a.minX - b.maxX)
            return horizontalGap <= 2.0 * minHeight
        }

        // 上下相邻行：行距不超过约一行高，且水平位置对齐或区间重叠。
        let verticalGap = b.minY - a.maxY
        guard verticalGap >= -0.25 * minHeight, verticalGap <= 0.7 * minHeight else {
            return false
        }

        let overlapWidth = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let narrowerWidth = min(a.width, b.width)
        let overlapEnough = narrowerWidth > 0 && overlapWidth >= 0.3 * narrowerWidth
        let leftAligned = abs(a.minX - b.minX) <= 1.5 * minHeight
        return overlapEnough || leftAligned
    }

    private static func readingOrder(_ lhs: OCRLine, _ rhs: OCRLine) -> Bool {
        // 图像像素坐标为左上原点：y 小者在上。行中心接近视为同一行，再按 x 排。
        let yDelta = abs(lhs.rect.midY - rhs.rect.midY)
        if yDelta > 0.5 * min(lhs.rect.height, rhs.rect.height) {
            return lhs.rect.midY < rhs.rect.midY
        }
        return lhs.rect.minX < rhs.rect.minX
    }

    // MARK: - 组块

    private static func makeBlock(from lines: [OCRLine]) -> TextBlock {
        let unionRect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
        let separator = usesSpacelessJoin(lines) ? "" : " "
        let text = lines.map(\.text).joined(separator: separator)
        return TextBlock(
            lines: lines,
            pxRect: unionRect,
            text: text,
            medianLineHeightPx: median(lines.map(\.rect.height))
        )
    }

    /// 中文/日文书写不使用词间空格，行间直接相连；
    /// 韩文与拉丁文字保留空格（韩文正字法本身用空格分词）。
    private static func usesSpacelessJoin(_ lines: [OCRLine]) -> Bool {
        let text = lines.map(\.text).joined()
        var cjkCount = 0
        var letterCount = 0
        for scalar in text.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) || isNoSpaceScript(scalar) else { continue }
            letterCount += 1
            if isNoSpaceScript(scalar) {
                cjkCount += 1
            }
        }
        guard letterCount > 0 else { return false }
        return Double(cjkCount) / Double(letterCount) >= 0.4
    }

    private static func isNoSpaceScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 统一表意
             0xF900...0xFAFF,   // CJK 兼容
             0x3040...0x309F,   // 平假名
             0x30A0...0x30FF,   // 片假名
             0x31F0...0x31FF:   // 片假名音标扩展
            return true
        default:
            return false
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
