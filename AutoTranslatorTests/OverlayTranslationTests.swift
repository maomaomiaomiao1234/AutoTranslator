//
//  OverlayTranslationTests.swift
//  AutoTranslatorTests
//
//  贴图翻译纯逻辑单测：坐标换算、行聚合、取色采样、字号适配与平铺合成。
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AutoTranslator

// MARK: - 坐标换算

struct OverlayGeometryTests {
    @Test
    func visionNormalizedRectConvertsToTopLeftPixelRect() {
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let pixel = OverlayGeometry.pixelRect(
            fromNormalized: normalized,
            imageWidth: 400,
            imageHeight: 200
        )
        // 左下原点 y=0.5、高 0.25 → 顶部占比 1-0.5-0.25=0.25 → 顶左 y=50。
        #expect(pixel == CGRect(x: 100, y: 50, width: 200, height: 50))
    }

    @Test
    func appKitRectConvertsToCGTopLeftGlobalRect() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let appKit = CGRect(x: 100, y: 700, width: 50, height: 50)
        let cg = OverlayGeometry.cgGlobalRect(fromAppKit: appKit, primaryScreenFrame: primary)
        // AppKit maxY=750（距底），CG y = 800-750 = 50（距顶）。
        #expect(cg == CGRect(x: 100, y: 50, width: 50, height: 50))
    }
}

// MARK: - 行聚合

struct TextBlockGrouperTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test
    func stackedLeftAlignedLinesMergeIntoOneParagraph() {
        let lines = [
            line("The quick brown", x: 0, y: 0, w: 180, h: 20),
            line("fox jumps over", x: 0, y: 26, w: 170, h: 20),
            line("the lazy dog", x: 0, y: 52, w: 140, h: 20),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "The quick brown fox jumps over the lazy dog")
        #expect(blocks[0].pxRect == CGRect(x: 0, y: 0, width: 180, height: 72))
        #expect(blocks[0].medianLineHeightPx == 20)
    }

    @Test
    func sideBySideColumnsStaySeparate() {
        let lines = [
            line("Left column", x: 0, y: 0, w: 180, h: 20),
            line("Right column", x: 400, y: 0, w: 180, h: 20),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 2)
    }

    @Test
    func titleAndBodyWithDifferentHeightsStaySeparate() {
        let lines = [
            line("Big Title", x: 0, y: 0, w: 200, h: 36),
            line("Body text here", x: 0, y: 44, w: 220, h: 16),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 2)
    }

    @Test
    func distantParagraphsStaySeparate() {
        let lines = [
            line("First paragraph", x: 0, y: 0, w: 180, h: 20),
            line("Second paragraph", x: 0, y: 100, w: 180, h: 20),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 2)
    }

    @Test
    func chineseLinesJoinWithoutSpaces() {
        let lines = [
            line("你好世界", x: 0, y: 0, w: 120, h: 22),
            line("翻译测试", x: 0, y: 26, w: 120, h: 22),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "你好世界翻译测试")
    }

    @Test
    func outOfOrderInputIsSortedIntoReadingOrder() {
        let lines = [
            line("second", x: 0, y: 26, w: 100, h: 20),
            line("first", x: 0, y: 0, w: 100, h: 20),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "first second")
    }
}

// MARK: - 取色采样

@MainActor
struct PatchStyleSamplerTests {
    /// 生成纯色底 + 中央矩形"字形"的合成图。所有矩形垂直居中，规避坐标翻转歧义。
    private func syntheticImage(size: CGSize,
                                background: (CGFloat, CGFloat, CGFloat),
                                glyphRect: CGRect,
                                glyph: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(red: glyph.0, green: glyph.1, blue: glyph.2, alpha: 1)
        context.fill(glyphRect)
        return context.makeImage()
    }

    @Test
    func samplesWhiteBackgroundAndBlackGlyph() throws {
        // 60×30 白底；黑"字形"位于 (20,10,20,10)，垂直居中。
        let image = try #require(syntheticImage(
            size: CGSize(width: 60, height: 30),
            background: (1, 1, 1),
            glyphRect: CGRect(x: 20, y: 10, width: 20, height: 10),
            glyph: (0, 0, 0)
        ))
        let style = PatchStyleSampler.style(
            for: CGRect(x: 16, y: 6, width: 28, height: 18),
            in: image
        )
        let bg = style.background.usingColorSpace(.sRGB)!
        let text = style.text.usingColorSpace(.sRGB)!
        #expect(bg.redComponent > 0.9 && bg.greenComponent > 0.9 && bg.blueComponent > 0.9)
        #expect(text.redComponent < 0.1 && text.greenComponent < 0.1 && text.blueComponent < 0.1)
    }

    @Test
    func lowContrastGlyphFallsBackToBlackOnLightBackground() throws {
        // 白底 + 近白"字形"：对比度不足，回退黑字保证可读。
        let image = try #require(syntheticImage(
            size: CGSize(width: 60, height: 30),
            background: (1, 1, 1),
            glyphRect: CGRect(x: 20, y: 10, width: 20, height: 10),
            glyph: (0.92, 0.92, 0.92)
        ))
        let style = PatchStyleSampler.style(
            for: CGRect(x: 16, y: 6, width: 28, height: 18),
            in: image
        )
        let text = style.text.usingColorSpace(.sRGB)!
        #expect(text.redComponent < 0.1)
    }

    @Test
    func preservesColoredGlyph() throws {
        // 白底 + 纯红字形：文字色应保留红色而非回退黑白。
        let image = try #require(syntheticImage(
            size: CGSize(width: 60, height: 30),
            background: (1, 1, 1),
            glyphRect: CGRect(x: 20, y: 10, width: 20, height: 10),
            glyph: (0.8, 0, 0)
        ))
        let style = PatchStyleSampler.style(
            for: CGRect(x: 16, y: 6, width: 28, height: 18),
            in: image
        )
        let text = style.text.usingColorSpace(.sRGB)!
        #expect(text.redComponent > 0.6)
        #expect(text.greenComponent < 0.2)
    }

    @Test
    func largeBlockSubsamplingStillDetectsColors() throws {
        // 1200×800 大块（96 万像素 >> 1 万样本上限），走网格子采样 + 直方图路径；
        // 结果应与全量采样一致：白底、红字形。
        let image = try #require(syntheticImage(
            size: CGSize(width: 1280, height: 880),
            background: (1, 1, 1),
            glyphRect: CGRect(x: 340, y: 240, width: 600, height: 400),
            glyph: (0.8, 0, 0)
        ))
        let style = PatchStyleSampler.style(
            for: CGRect(x: 40, y: 40, width: 1200, height: 800),
            in: image
        )
        let bg = style.background.usingColorSpace(.sRGB)!
        let text = style.text.usingColorSpace(.sRGB)!
        #expect(bg.redComponent > 0.9 && bg.greenComponent > 0.9 && bg.blueComponent > 0.9)
        #expect(text.redComponent > 0.6)
        #expect(text.greenComponent < 0.2)
    }

    @Test
    func twoPhaseAPIMatchesConvenienceEntryPoint() throws {
        let image = try #require(syntheticImage(
            size: CGSize(width: 60, height: 30),
            background: (0.1, 0.1, 0.1),
            glyphRect: CGRect(x: 20, y: 10, width: 20, height: 10),
            glyph: (1, 1, 0)
        ))
        let blockRect = CGRect(x: 16, y: 6, width: 28, height: 18)
        let region = PatchStyleSampler.samplingRegion(for: blockRect, in: image)
        #expect(PatchStyleSampler.style(for: region) == PatchStyleSampler.style(for: blockRect, in: image))
    }
}

// MARK: - 字号适配与排版

@MainActor
struct OverlayComposerLayoutTests {
    @Test
    func longChineseTextShrinksToFitNarrowBlock() {
        let text = "这是一段比较长的中文文本，需要换行显示才能放进较窄的块里，验证字号会收缩。"
        let box = CGSize(width: 120, height: 44)
        let size = OverlayComposer.fittedFontSize(
            for: text,
            in: box,
            startingAt: 26,
            alignment: .natural
        )
        #expect(size >= OVERLAY_MIN_FONT_SIZE)
        #expect(size < 26)
    }

    @Test
    func shortTextKeepsInitialSize() {
        let size = OverlayComposer.fittedFontSize(
            for: "Hi",
            in: CGSize(width: 200, height: 30),
            startingAt: 16,
            alignment: .natural
        )
        #expect(size == 16)
    }

    @Test
    func tallerBoxNeverProducesSmallerFont() {
        let text = "多行文本适配字号的单调性验证，盒子越高字号不应更小。"
        let small = OverlayComposer.fittedFontSize(
            for: text, in: CGSize(width: 100, height: 30), startingAt: 20, alignment: .natural
        )
        let large = OverlayComposer.fittedFontSize(
            for: text, in: CGSize(width: 100, height: 90), startingAt: 20, alignment: .natural
        )
        #expect(large >= small)
    }

    @Test
    func centeredLinesDetectCenterAlignment() {
        let lines = [
            OCRLine(text: "居中标题", rect: CGRect(x: 40, y: 0, width: 120, height: 20)),
            OCRLine(text: "副标题", rect: CGRect(x: 70, y: 26, width: 60, height: 20)),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 1)
        #expect(OverlayComposer.detectAlignment(of: blocks[0]) == .center)
    }

    @Test
    func leftAlignedLinesDetectNaturalAlignment() {
        let lines = [
            OCRLine(text: "left line one", rect: CGRect(x: 0, y: 0, width: 180, height: 20)),
            OCRLine(text: "left two", rect: CGRect(x: 0, y: 26, width: 90, height: 20)),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        #expect(blocks.count == 1)
        #expect(OverlayComposer.detectAlignment(of: blocks[0]) == .natural)
    }
}

// MARK: - 平铺合成

@MainActor
struct OverlayComposerRenderTests {
    private func solidImage(width: Int, height: Int,
                            red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @Test
    func flatRenderKeepsPixelDimensionsAndPaintsPatch() throws {
        let base = try #require(solidImage(width: 100, height: 50, red: 0.8, green: 0.1, blue: 0.1))
        let block = TextBlock(
            lines: [OCRLine(text: "hello", rect: CGRect(x: 20, y: 20, width: 60, height: 10))],
            pxRect: CGRect(x: 20, y: 20, width: 60, height: 10),
            text: "hello",
            medianLineHeightPx: 10
        )
        let layout = OverlayComposer.layout(
            blockIndex: 0,
            block: block,
            translatedText: "你好",
            style: PatchStyle(background: .white, text: .black),
            scale: 1
        )
        let image = try #require(OverlayComposer.renderFlat(
            baseImage: base,
            imagePtSize: CGSize(width: 100, height: 50),
            layouts: [layout]
        ))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == 100)
        #expect(rep.pixelsHigh == 50)

        // 色块中心（图像正中，垂直居中规避翻转歧义）应接近白色而非底图红色。
        let center = try #require(rep.colorAt(x: 50, y: 25)?.usingColorSpace(.sRGB))
        #expect(center.greenComponent > 0.5)

        // 未被色块覆盖的角落仍是底图红色。
        let corner = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(corner.redComponent > 0.6)
        #expect(corner.greenComponent < 0.3)

        #expect(OverlayComposer.pngData(from: image) != nil)
    }
}
