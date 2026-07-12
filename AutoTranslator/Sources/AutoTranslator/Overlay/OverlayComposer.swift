import AppKit

/// 单个文本块的最终排版：屏显（SwiftUI）与导出（位图合成）共用同一份数据，
/// 保证两边几何一致。所有矩形均为"相对贴图图像区左上角"的点坐标。
struct BlockLayout {
    let blockIndex: Int
    /// 文本排版矩形（原文块矩形换算成点）。
    let ptRect: CGRect
    /// 色块矩形（ptRect 外扩，盖住原字形边缘）。
    let patchRect: CGRect
    let patchColor: NSColor
    let textColor: NSColor
    let font: NSFont
    let alignment: NSTextAlignment
    let text: String
}

/// 贴图排版与平铺导出。
enum OverlayComposer {

    /// 译文允许比原文块稍高一点（8%），避免为一两个像素牺牲整档字号。
    private static let heightAllowance: CGFloat = 1.08
    private static let fontShrinkStep: CGFloat = 0.92

    // MARK: - 排版

    /// 为翻译完成的块计算排版：字号从原文行高出发向下适配到块内放得下。
    /// - Parameter scale: 图像像素 / 窗口点 的比例（Retina 为 2）。
    static func layout(blockIndex: Int,
                       block: TextBlock,
                       translatedText: String,
                       style: PatchStyle,
                       scale: CGFloat) -> BlockLayout {
        let safeScale = max(scale, 0.01)
        let ptRect = CGRect(
            x: block.pxRect.minX / safeScale,
            y: block.pxRect.minY / safeScale,
            width: block.pxRect.width / safeScale,
            height: block.pxRect.height / safeScale
        )
        let alignment = detectAlignment(of: block)
        let fontSize = fittedFontSize(
            for: translatedText,
            in: ptRect.size,
            startingAt: (block.medianLineHeightPx / safeScale) * 0.8,
            alignment: alignment
        )
        return BlockLayout(
            blockIndex: blockIndex,
            ptRect: ptRect,
            patchRect: ptRect.insetBy(dx: -OVERLAY_PATCH_INFLATE_X, dy: -OVERLAY_PATCH_INFLATE_Y),
            patchColor: style.background,
            textColor: style.text,
            font: NSFont.systemFont(ofSize: fontSize),
            alignment: alignment,
            text: translatedText
        )
    }

    /// 带段落样式的属性字符串；屏显与导出统一从这里取，避免样式漂移。
    static func attributedString(for layout: BlockLayout) -> NSAttributedString {
        attributedString(
            text: layout.text,
            font: layout.font,
            color: layout.textColor,
            alignment: layout.alignment
        )
    }

    /// 文本在块内的实际绘制矩形：高度按测量结果收紧并垂直居中，
    /// 避免单行译文贴着块顶。超出块高时保留块矩形（绘制时按矩形截断）。
    static func textDrawRect(for layout: BlockLayout) -> CGRect {
        let measured = measuredHeight(
            of: attributedString(for: layout),
            width: layout.ptRect.width
        )
        guard measured < layout.ptRect.height else { return layout.ptRect }
        var rect = layout.ptRect
        rect.origin.y += (layout.ptRect.height - measured) / 2
        rect.size.height = measured
        return rect
    }

    /// 适配字号：初始值来自原文行高，逐步收缩直到换行后的高度放得进块内。
    static func fittedFontSize(for text: String,
                               in boxSize: CGSize,
                               startingAt initialSize: CGFloat,
                               alignment: NSTextAlignment) -> CGFloat {
        var size = max(OVERLAY_MIN_FONT_SIZE, initialSize)
        let maxHeight = boxSize.height * heightAllowance
        while size > OVERLAY_MIN_FONT_SIZE {
            let attributed = attributedString(
                text: text,
                font: .systemFont(ofSize: size),
                color: .black,
                alignment: alignment
            )
            if measuredHeight(of: attributed, width: boxSize.width) <= maxHeight {
                break
            }
            size = max(OVERLAY_MIN_FONT_SIZE, size * fontShrinkStep)
        }
        return size
    }

    /// 对齐检测：各行中心都贴近块中心 → 居中；否则按左对齐处理。
    /// 单行块没有可参照的行际关系，按左对齐（最不易出错）。
    static func detectAlignment(of block: TextBlock) -> NSTextAlignment {
        guard block.lines.count > 1, block.pxRect.width > 0 else { return .natural }
        let tolerance = block.pxRect.width * 0.04
        let blockMidX = block.pxRect.midX
        let allCentered = block.lines.allSatisfy { abs($0.rect.midX - blockMidX) <= tolerance }
        return allCentered ? .center : .natural
    }

    // MARK: - 平铺导出（复制/保存用）

    /// 把原图 + 全部色块 + 译文合成为一张与原图同像素尺寸的位图。
    /// `imagePtSize` 写入 rep.size，使导出 PNG 保留 Retina DPI 元数据。
    static func renderFlat(baseImage: CGImage,
                           imagePtSize: CGSize,
                           layouts: [BlockLayout]) -> NSImage? {
        guard imagePtSize.width > 0, imagePtSize.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: baseImage.width,
            pixelsHigh: baseImage.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // 此时 rep 尚未设置点尺寸，上下文用户空间恒为像素（CTM=单位阵）；
        // 显式缩放后统一以点坐标绘制，与屏显共用同一几何。
        let pixelScale = CGFloat(baseImage.width) / imagePtSize.width
        context.cgContext.scaleBy(x: pixelScale, y: pixelScale)

        let fullRect = CGRect(origin: .zero, size: imagePtSize)
        NSImage(cgImage: baseImage, size: imagePtSize).draw(in: fullRect)

        for layout in layouts {
            layout.patchColor.setFill()
            NSBezierPath(
                roundedRect: flip(layout.patchRect, containerHeight: imagePtSize.height),
                xRadius: OVERLAY_PATCH_RADIUS,
                yRadius: OVERLAY_PATCH_RADIUS
            ).fill()

            let drawRect = flip(textDrawRect(for: layout), containerHeight: imagePtSize.height)
            attributedString(for: layout).draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // 绘制完成后再写入点尺寸：导出 PNG 携带正确的 Retina DPI 元数据。
        rep.size = imagePtSize

        let image = NSImage(size: imagePtSize)
        image.addRepresentation(rep)
        return image
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            guard let tiff = image.tiffRepresentation,
                  let fallback = NSBitmapImageRep(data: tiff) else { return nil }
            return fallback.representation(using: .png, properties: [:])
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 私有

    private static func attributedString(text: String,
                                         font: NSFont,
                                         color: NSColor,
                                         alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let rect = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    /// 左上原点 → 左下原点（AppKit 非翻转绘制坐标）。
    private static func flip(_ rect: CGRect, containerHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: containerHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
