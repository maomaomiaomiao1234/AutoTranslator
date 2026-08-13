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
///
/// 性能约束：每个区域最多取约 1 万个样本（大块按网格步进子采样），
/// 通道中位数用 256 桶直方图 O(n) 求得；统计阶段不触碰 CGImage，
/// 可放到后台线程（见 `samplingRegion(for:in:)` / `style(for:)` 两段式 API）。
nonisolated enum PatchStyleSampler {

    private static let ringMargin = 3
    private static let minimumContrastRatio: CGFloat = 2.2
    /// 单个采样区域（环带/块内）的样本数上限。1 万足以让中位数稳定，
    /// 又把最坏情况（数百万像素大块）的统计成本压到毫秒级。
    private static let maxSamplesPerRegion = 10_000

    /// 一次性完成提取+统计的便捷入口（小图与测试用）。
    static func style(for blockPxRect: CGRect, in image: CGImage) -> PatchStyle {
        style(for: samplingRegion(for: blockPxRect, in: image))
    }

    // MARK: - 两段式 API

    /// 阶段一（调用方线程，通常主线程）：从 CGImage 取出块外扩环带的 RGBA 缓冲。
    /// 只做一次 CGContext 位图绘制，代价与区域像素量线性但无逐像素 Swift 循环。
    /// 返回值 Sendable，可送进后台任务执行阶段二。
    static func samplingRegion(for blockPxRect: CGRect, in image: CGImage) -> SamplingRegion? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let block = blockPxRect.integral.intersection(imageBounds)
        guard !block.isEmpty else { return nil }

        let expanded = block
            .insetBy(dx: -CGFloat(ringMargin), dy: -CGFloat(ringMargin))
            .intersection(imageBounds)
            .integral
        guard let buffer = rgbaBuffer(of: image, in: expanded) else { return nil }

        // 块矩形在缓冲区内的相对位置。
        let blockInBuffer = CGRect(
            x: block.minX - expanded.minX,
            y: block.minY - expanded.minY,
            width: block.width,
            height: block.height
        )
        return SamplingRegion(buffer: buffer, blockInBuffer: blockInBuffer)
    }

    /// 阶段二（任意线程）：对缓冲做纯统计，得出配色。
    static func style(for region: SamplingRegion?) -> PatchStyle {
        guard let region else { return fallbackStyle(backgroundIsLight: true) }
        let buffer = region.buffer
        let blockInBuffer = region.blockInBuffer

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

    nonisolated struct SamplingRegion: Sendable {
        let buffer: RGBABuffer
        let blockInBuffer: CGRect
    }

    nonisolated struct RGBABuffer: Sendable {
        let pixels: [UInt8]   // RGBA8，每像素 4 字节
        let width: Int
        let height: Int

        func rgb8(x: Int, y: Int) -> RGB8 {
            let offset = (y * width + x) * 4
            return RGB8(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
        }
    }

    /// 原始字节色值。统计阶段全程用整数运算，中位数走 256 桶直方图。
    nonisolated struct RGB8 {
        let r: UInt8
        let g: UInt8
        let b: UInt8

        func squaredDistance(to other: RGB8) -> Int {
            let dr = Int(r) - Int(other.r)
            let dg = Int(g) - Int(other.g)
            let db = Int(b) - Int(other.b)
            return dr * dr + dg * dg + db * db
        }
    }

    fileprivate nonisolated struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(_ byte: RGB8) {
            self.init(r: CGFloat(byte.r) / 255, g: CGFloat(byte.g) / 255, b: CGFloat(byte.b) / 255)
        }

        var byte: RGB8 {
            RGB8(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()), b: UInt8((b * 255).rounded()))
        }

        var components: SIMD3<Double> { SIMD3(Double(r), Double(g), Double(b)) }

        var relativeLuminance: CGFloat {
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
    }

    private static func rgbaBuffer(of image: CGImage, in rect: CGRect) -> RGBABuffer? {
        guard rect.width >= 1, rect.height >= 1,
              let cropped = image.cropping(to: rect) else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // CGContext 会在本作用域外继续持有 data 指针；必须在 withUnsafeMutableBytes
        // 闭包内完成创建+绘制+释放，用 &pixels 直接传会构成悬垂指针 UB。
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return RGBABuffer(pixels: pixels, width: width, height: height)
    }

    // MARK: - 采样

    /// 网格子采样步长：让样本数落在 maxSamplesPerRegion 附近。
    private static func sampleStep(forArea area: Int) -> Int {
        max(1, Int((Double(area) / Double(maxSamplesPerRegion)).squareRoot().rounded(.up)))
    }

    /// 环带（缓冲区内、块矩形外）像素的逐通道中位数。
    /// 按上下左右四条带独立遍历——环带本身面积很小，若按整个缓冲区面积
    /// 取步长会把薄带整条跳过。
    private static func ringMedianColor(buffer: RGBABuffer, excluding blockRect: CGRect) -> RGB? {
        let blockMinX = max(0, Int(blockRect.minX))
        let blockMaxX = min(buffer.width, Int(blockRect.maxX))
        let blockMinY = max(0, Int(blockRect.minY))
        let blockMaxY = min(buffer.height, Int(blockRect.maxY))

        // (x range, y range) 四条带：上、下、左、右。
        let bands: [(Range<Int>, Range<Int>)] = [
            (0..<buffer.width, 0..<blockMinY),
            (0..<buffer.width, blockMaxY..<buffer.height),
            (0..<blockMinX, blockMinY..<blockMaxY),
            (blockMaxX..<buffer.width, blockMinY..<blockMaxY),
        ].filter { !$0.0.isEmpty && !$0.1.isEmpty }

        let ringArea = bands.reduce(0) { $0 + $1.0.count * $1.1.count }
        guard ringArea > 0 else { return nil }
        let step = sampleStep(forArea: ringArea)

        var samples: [RGB8] = []
        samples.reserveCapacity(min(ringArea, maxSamplesPerRegion + ringArea / max(1, step * step)))
        for (xRange, yRange) in bands {
            for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: step) {
                for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: step) {
                    samples.append(buffer.rgb8(x: x, y: y))
                }
            }
        }
        return medianColor(of: samples)
    }

    /// 环带被图像边缘裁没时的兜底：取块矩形自身 1px 边框的中位数。
    private static func borderMedianColor(buffer: RGBABuffer, of blockRect: CGRect) -> RGB? {
        var samples: [RGB8] = []
        let minX = max(0, Int(blockRect.minX))
        let maxX = min(buffer.width - 1, Int(blockRect.maxX) - 1)
        let minY = max(0, Int(blockRect.minY))
        let maxY = min(buffer.height - 1, Int(blockRect.maxY) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }
        let perimeter = 2 * ((maxX - minX + 1) + (maxY - minY + 1))
        let step = sampleStep(forArea: perimeter)
        for x in stride(from: minX, through: maxX, by: step) {
            samples.append(buffer.rgb8(x: x, y: minY))
            samples.append(buffer.rgb8(x: x, y: maxY))
        }
        for y in stride(from: minY, through: maxY, by: step) {
            samples.append(buffer.rgb8(x: minX, y: y))
            samples.append(buffer.rgb8(x: maxX, y: y))
        }
        return medianColor(of: samples)
    }

    /// 块内距底色最远的 10% 像素（≈原文字形）的中位数颜色。
    private static func glyphColor(buffer: RGBABuffer, in blockRect: CGRect, background: RGB) -> RGB? {
        let minX = max(0, Int(blockRect.minX))
        let maxX = min(buffer.width, Int(blockRect.maxX))
        let minY = max(0, Int(blockRect.minY))
        let maxY = min(buffer.height, Int(blockRect.maxY))
        guard minX < maxX, minY < maxY else { return nil }

        let area = (maxX - minX) * (maxY - minY)
        let step = sampleStep(forArea: area)
        let backgroundByte = background.byte

        var candidates: [(color: RGB8, distance: Int)] = []
        candidates.reserveCapacity(area / (step * step) + 1)
        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                let color = buffer.rgb8(x: x, y: y)
                candidates.append((color, color.squaredDistance(to: backgroundByte)))
            }
        }
        guard !candidates.isEmpty else { return nil }
        // 样本数已被子采样封顶（约 1 万），这里的排序是常数级成本。
        candidates.sort { $0.distance > $1.distance }
        let count = max(1, candidates.count / 10)
        return medianColor(of: candidates.prefix(count).map(\.color))
    }

    /// 逐通道中位数，256 桶直方图 O(n)：与「排序取 sorted[count/2]」结果一致。
    private static func medianColor(of samples: [RGB8]) -> RGB? {
        guard !samples.isEmpty else { return nil }
        var redHistogram = [Int](repeating: 0, count: 256)
        var greenHistogram = [Int](repeating: 0, count: 256)
        var blueHistogram = [Int](repeating: 0, count: 256)
        for sample in samples {
            redHistogram[Int(sample.r)] += 1
            greenHistogram[Int(sample.g)] += 1
            blueHistogram[Int(sample.b)] += 1
        }
        let target = samples.count / 2
        func median(_ histogram: [Int]) -> UInt8 {
            var cumulative = 0
            for value in 0..<256 {
                cumulative += histogram[value]
                if cumulative > target { return UInt8(value) }
            }
            return 255
        }
        return RGB(RGB8(
            r: median(redHistogram),
            g: median(greenHistogram),
            b: median(blueHistogram)
        ))
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
