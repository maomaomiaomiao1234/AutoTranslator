import AppKit
import CoreGraphics

/// 贴图色块的配色：底色来自原图边缘采样，文字色尽量沿用原文字色。
/// 以 sRGB 分量存储（Sendable），便于在后台线程采样后跨隔离边界回主线程。
nonisolated struct PatchStyle: Equatable, Sendable {
    let backgroundComponents: SIMD3<Double>
    let textComponents: SIMD3<Double>

    var background: NSColor {
        NSColor(srgbRed: CGFloat(backgroundComponents.x),
                green: CGFloat(backgroundComponents.y),
                blue: CGFloat(backgroundComponents.z),
                alpha: 1)
    }

    var text: NSColor {
        NSColor(srgbRed: CGFloat(textComponents.x),
                green: CGFloat(textComponents.y),
                blue: CGFloat(textComponents.z),
                alpha: 1)
    }

    init(backgroundComponents: SIMD3<Double>, textComponents: SIMD3<Double>) {
        self.backgroundComponents = backgroundComponents
        self.textComponents = textComponents
    }

    /// 便捷构造：从 NSColor 取 sRGB 分量（测试与兜底用）。
    init(background: NSColor, text: NSColor) {
        func components(_ color: NSColor) -> SIMD3<Double> {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            return SIMD3(Double(resolved.redComponent),
                         Double(resolved.greenComponent),
                         Double(resolved.blueComponent))
        }
        backgroundComponents = components(background)
        textComponents = components(text)
    }
}

/// 从原始截图中为每个文本块采样贴图配色。
/// 底色 = 块外沿环带像素的逐通道中位数（中位数对相邻字形等离群值稳健）；
/// 文字色 = 块内距底色最远的 10% 像素的中位数（即原文字形颜色），
/// 与底色对比度不足时回退为按底色亮度选黑/白。
nonisolated enum PatchStyleSampler {

    private static let ringMargin = 3
    private static let minimumContrastRatio: CGFloat = 2.2

    static func style(for blockPxRect: CGRect, in image: CGImage) -> PatchStyle {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let block = blockPxRect.integral.intersection(imageBounds)
        guard !block.isEmpty else { return fallbackStyle(backgroundIsLight: true) }

        let expanded = block
            .insetBy(dx: -CGFloat(ringMargin), dy: -CGFloat(ringMargin))
            .intersection(imageBounds)
            .integral
        guard let buffer = rgbaBuffer(of: image, in: expanded) else {
            return fallbackStyle(backgroundIsLight: true)
        }

        // 块矩形在缓冲区内的相对位置。
        let blockInBuffer = CGRect(
            x: block.minX - expanded.minX,
            y: block.minY - expanded.minY,
            width: block.width,
            height: block.height
        )

        let background = ringMedianColor(buffer: buffer, excluding: blockInBuffer)
            ?? borderMedianColor(buffer: buffer, of: blockInBuffer)
            ?? RGB(r: 1, g: 1, b: 1)
        let textColor = glyphColor(buffer: buffer, in: blockInBuffer, background: background)

        if let textColor, contrastRatio(textColor, background) >= minimumContrastRatio {
            return PatchStyle(
                backgroundComponents: background.components,
                textComponents: textColor.components
            )
        }
        // 对比度不足：按底色亮度回退黑/白，保证译文可读。
        let fallbackText: SIMD3<Double> = background.relativeLuminance > 0.45
            ? SIMD3(0, 0, 0)
            : SIMD3(1, 1, 1)
        return PatchStyle(backgroundComponents: background.components, textComponents: fallbackText)
    }

    // MARK: - 像素缓冲

    private nonisolated struct RGBABuffer {
        let pixels: [UInt8]   // RGBA8，每像素 4 字节
        let width: Int
        let height: Int

        func rgb(x: Int, y: Int) -> RGB {
            let offset = (y * width + x) * 4
            return RGB(
                r: CGFloat(pixels[offset]) / 255,
                g: CGFloat(pixels[offset + 1]) / 255,
                b: CGFloat(pixels[offset + 2]) / 255
            )
        }
    }

    fileprivate nonisolated struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        var components: SIMD3<Double> { SIMD3(Double(r), Double(g), Double(b)) }

        var relativeLuminance: CGFloat {
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        func squaredDistance(to other: RGB) -> CGFloat {
            let dr = r - other.r
            let dg = g - other.g
            let db = b - other.b
            return dr * dr + dg * dg + db * db
        }
    }

    private static func rgbaBuffer(of image: CGImage, in rect: CGRect) -> RGBABuffer? {
        guard rect.width >= 1, rect.height >= 1,
              let cropped = image.cropping(to: rect) else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABuffer(pixels: pixels, width: width, height: height)
    }

    // MARK: - 采样

    /// 环带（缓冲区内、块矩形外）像素的逐通道中位数。
    private static func ringMedianColor(buffer: RGBABuffer, excluding blockRect: CGRect) -> RGB? {
        var samples: [RGB] = []
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !blockRect.contains(point) {
                    samples.append(buffer.rgb(x: x, y: y))
                }
            }
        }
        return medianColor(of: samples)
    }

    /// 环带被图像边缘裁没时的兜底：取块矩形自身 1px 边框的中位数。
    private static func borderMedianColor(buffer: RGBABuffer, of blockRect: CGRect) -> RGB? {
        var samples: [RGB] = []
        let minX = max(0, Int(blockRect.minX))
        let maxX = min(buffer.width - 1, Int(blockRect.maxX) - 1)
        let minY = max(0, Int(blockRect.minY))
        let maxY = min(buffer.height - 1, Int(blockRect.maxY) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }
        for x in minX...maxX {
            samples.append(buffer.rgb(x: x, y: minY))
            samples.append(buffer.rgb(x: x, y: maxY))
        }
        for y in minY...maxY {
            samples.append(buffer.rgb(x: minX, y: y))
            samples.append(buffer.rgb(x: maxX, y: y))
        }
        return medianColor(of: samples)
    }

    /// 块内距底色最远的 10% 像素（≈原文字形）的中位数颜色。
    private static func glyphColor(buffer: RGBABuffer, in blockRect: CGRect, background: RGB) -> RGB? {
        var candidates: [(color: RGB, distance: CGFloat)] = []
        let minX = max(0, Int(blockRect.minX))
        let maxX = min(buffer.width, Int(blockRect.maxX))
        let minY = max(0, Int(blockRect.minY))
        let maxY = min(buffer.height, Int(blockRect.maxY))
        guard minX < maxX, minY < maxY else { return nil }
        for y in minY..<maxY {
            for x in minX..<maxX {
                let color = buffer.rgb(x: x, y: y)
                candidates.append((color, color.squaredDistance(to: background)))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.distance > $1.distance }
        let count = max(1, candidates.count / 10)
        return medianColor(of: candidates.prefix(count).map(\.color))
    }

    private static func medianColor(of samples: [RGB]) -> RGB? {
        guard !samples.isEmpty else { return nil }
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return RGB(
            r: median(samples.map(\.r)),
            g: median(samples.map(\.g)),
            b: median(samples.map(\.b))
        )
    }

    private static func contrastRatio(_ first: RGB, _ second: RGB) -> CGFloat {
        let l1 = first.relativeLuminance
        let l2 = second.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func fallbackStyle(backgroundIsLight: Bool) -> PatchStyle {
        PatchStyle(
            backgroundComponents: backgroundIsLight ? SIMD3(1, 1, 1) : SIMD3(0, 0, 0),
            textComponents: backgroundIsLight ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
        )
    }
}
