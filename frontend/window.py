import Quartz
import objc
from Cocoa import NSObject
from AppKit import (
    NSWindow, NSTextField, NSBackingStoreBuffered,
    NSFloatingWindowLevel, NSColor, NSFont,
    NSMenu, NSMenuItem
)

# ---------------- 辅助：带样式的文本框 ----------------
def create_styled_label():
    label = NSTextField.alloc().init()
    label.setEditable_(False)
    label.setBordered_(False)
    label.setDrawsBackground_(True)
    # 浅灰色背景
    label.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.96, 1.0))
    label.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.2, 1.0))
    label.setFont_(NSFont.systemFontOfSize_(13))
    
    # 启用 Layer 以支持圆角
    label.setWantsLayer_(True)
    label.layer().setCornerRadius_(6.0)
    label.layer().setMasksToBounds_(True)
    return label


# ---------------- 悬浮窗口 ----------------
class FloatingWindow(NSObject):
    def init(self):
        self = objc.super(FloatingWindow, self).init()
        if self is None: return None

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (400, 300)),
            0,
            NSBackingStoreBuffered,
            False
        )

        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(True)
        # 纯白底色
        self.window.setBackgroundColor_(NSColor.whiteColor())
        self.window.setHasShadow_(True)
        self.window.setReleasedWhenClosed_(False)
        self.window.setMovableByWindowBackground_(True)

        # 1. 原文框
        self.src_label = create_styled_label()
        self.window.contentView().addSubview_(self.src_label)

        # 2. 中间信息框 (灰色小条)
        self.info_label = create_styled_label()
        self.info_label.setFont_(NSFont.systemFontOfSize_(11))
        self.info_label.setAlignment_(1)  # 居中
        self.info_label.setTextColor_(NSColor.grayColor())
        self.window.contentView().addSubview_(self.info_label)

        # 3. 译文框
        self.dest_label = create_styled_label()
        self.dest_label.setTextColor_(NSColor.blackColor())
        self.dest_label.setFont_(NSFont.systemFontOfSize_(14))
        self.window.contentView().addSubview_(self.dest_label)

        self.is_pinned = False
        self.setup_menu()
        
        return self

    @objc.python_method
    def setup_menu(self):
        self.menu = NSMenu.alloc().initWithTitle_("Options")
        pin_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("固定位置/跟随鼠标", "togglePin:", "")
        pin_item.setTarget_(self)
        self.menu.addItem_(pin_item)
        
        close_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("隐藏窗口", "hideWindow:", "")
        close_item.setTarget_(self)
        self.menu.addItem_(close_item)
        self.window.contentView().setMenu_(self.menu)

    def togglePin_(self, sender):
        self.is_pinned = not self.is_pinned

    def hideWindow_(self, sender):
        self.window.orderOut_(None)

    @objc.python_method
    def show(self, src_text, dest_text=None, info="自动检测 ➔ 中文"):
        self.src_label.setStringValue_(src_text)
        self.info_label.setStringValue_(info)
        self.dest_label.setStringValue_(dest_text if dest_text else "正在翻译...")

        # 布局计算
        padding = 12
        spacing = 8
        width = 360
        inner_width = width - (padding * 2)

        # 计算各个框的高度
        def get_height(label, text, w):
            label.setStringValue_(text)
            cell = label.cell()
            rect = cell.cellSizeForBounds_(((0, 0), (w - 10, 1000)))
            return max(30, rect.height + 10)

        h1 = get_height(self.src_label, src_text, inner_width)
        h2 = 24  # 信息条固定高度
        h3 = get_height(self.dest_label, dest_text if dest_text else "正在翻译...", inner_width)

        total_height = h1 + h2 + h3 + (spacing * 2) + (padding * 2)

        # 设置各个组件的 Frame (从下往上堆叠)
        y = padding
        self.dest_label.setFrame_(((padding, y), (inner_width, h3)))
        y += h3 + spacing
        self.info_label.setFrame_(((padding, y), (inner_width, h2)))
        y += h2 + spacing
        self.src_label.setFrame_(((padding, y), (inner_width, h1)))

        # 更新窗口尺寸
        if self.is_pinned:
            frame = self.window.frame()
            old_top_y = frame.origin.y + frame.size.height
            self.window.setFrame_display_(((frame.origin.x, old_top_y - total_height), (width, total_height)), True)
        else:
            loc = Quartz.NSEvent.mouseLocation()
            self.window.setFrame_display_(((loc.x + 10, loc.y - total_height - 10), (width, total_height)), True)
        
        self.window.makeKeyAndOrderFront_(None)

    @objc.python_method
    def hide(self):
        self.window.orderOut_(None)
