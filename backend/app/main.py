#!/usr/bin/env python3

import sys
import time
import signal

import Quartz
import objc

from Cocoa import NSObject, NSApplication, NSWorkspace
from AppKit import (
    NSWindow, NSTextField, NSBackingStoreBuffered,
    NSFloatingWindowLevel, NSColor, NSFont, NSPasteboard,
    NSMenu, NSMenuItem, NSView, CALayer
)
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    kAXSelectedTextAttribute,
    kAXFocusedUIElementAttribute,
    AXIsProcessTrusted,
)

from deep_translator import GoogleTranslator


TARGET_LANG = "zh-CN"


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


# ---------------- 主逻辑 ----------------
class AutoTranslator(NSObject):
    def init(self):
        self = objc.super(AutoTranslator, self).init()
        if self is None: return None

        self.last_text = ""
        self.translator = GoogleTranslator(source="auto", target=TARGET_LANG)
        self.window = FloatingWindow.alloc().init()

        self.last_copy_time = 0
        self.copy_interval = 0.4
        return self

    def start_mouse_monitor(self):
        def callback(proxy, type_, event, refcon):
            if type_ == Quartz.kCGEventLeftMouseUp:
                self.on_mouse_up()
            return event

        mask = Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseUp)
        self.event_tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionListenOnly, mask, callback, None
        )

        if not self.event_tap:
            print("❌ 无法创建 EventTap")
            return

        run_loop_source = Quartz.CFMachPortCreateRunLoopSource(None, self.event_tap, 0)
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), run_loop_source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(self.event_tap, True)

    def on_mouse_up(self):
        time.sleep(0.05)
        text = self.get_selected_text()
        if not text or text == self.last_text:
            return

        self.last_text = text
        self.window.show(text, None) # 显示“正在翻译...”

        try:
            translated = self.translator.translate(text)
            if translated:
                self.window.show(text, translated)
            else:
                self.window.show(text, "翻译结果为空")
        except Exception as e:
            self.window.show(text, f"错误: {str(e)[:50]}")

    def get_selected_text(self):
        front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if not front_app: return None
        pid = front_app.processIdentifier()
        try:
            app_ref = AXUIElementCreateApplication(pid)
            focused, err = AXUIElementCopyAttributeValue(app_ref, kAXFocusedUIElementAttribute, None)
            if err == 0 and focused:
                selected, err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, None)
                if err == 0 and selected and selected.strip():
                    return selected.strip()
        except: pass
        return self.get_by_clipboard()

    def get_by_clipboard(self):
        now = time.time()
        if now - self.last_copy_time < self.copy_interval: return None
        self.last_copy_time = now

        pb = NSPasteboard.generalPasteboard()
        old_text = pb.stringForType_("public.utf8-plain-text")
        old_count = pb.changeCount()
        self.simulate_cmd_c()

        new_text = None
        for _ in range(20):
            time.sleep(0.01)
            if pb.changeCount() != old_count:
                new_text = pb.stringForType_("public.utf8-plain-text")
                break

        if old_text is not None:
            pb.clearContents()
            pb.declareTypes_owner_(["public.utf8-plain-text", "org.nspasteboard.TransientType"], None)
            pb.setString_forType_(old_text, "public.utf8-plain-text")

        if new_text:
            new_text = new_text.strip()
            return new_text if new_text and new_text != self.last_text else None
        return None

    def simulate_cmd_c(self):
        keycode = 8
        event_down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
        event_up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)


def main():
    if not AXIsProcessTrusted():
        print("❌ 需要辅助功能权限")
        sys.exit(1)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    t = AutoTranslator.alloc().init()
    t.start_mouse_monitor()

    print("🚀 启动成功：白底三段式界面 (右键可固定)")
    app.run()


if __name__ == "__main__":
    main()
