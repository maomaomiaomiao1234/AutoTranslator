import CoreGraphics

/// CGEvent/AX 使用主屏左上角为原点；AppKit 使用主屏左下角。
/// 所有显示器共享同一原点，不能用鼠标所在屏幕的高度翻转。
nonisolated enum SelectionScreenGeometry {
    static func appKitPoint(fromQuartz point: CGPoint, primaryScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }
}
