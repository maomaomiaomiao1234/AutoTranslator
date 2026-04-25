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
    NSMenu, NSMenuItem
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


# ---------------- 悬浮窗口 ----------------
class FloatingWindow(NSObject):
    def init(self):
        self = objc.super(FloatingWindow, self).init()
        if self is None: return None

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (400, 200)),
            0,
            NSBackingStoreBuffered,
            False
        )

        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0, 0.9))
        self.window.setHasShadow_(True)
        self.window.setReleasedWhenClosed_(False)
        self.window.setMovableByWindowBackground_(True)

        self.label = NSTextField.alloc().initWithFrame_(((15, 15), (370, 170)))
        self.label.setEditable_(False)
        self.label.setBordered_(False)
        self.label.setDrawsBackground_(False)
        self.label.setTextColor_(NSColor.whiteColor())
        self.label.setFont_(NSFont.systemFontOfSize_(14))
        
        self.window.contentView().addSubview_(self.label)

        self.is_pinned = False
        self.setup_menu()
        
        return self

    @objc.python_method
    def setup_menu(self):
        self.menu = NSMenu.alloc().initWithTitle_("Options")
        
        self.pin_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "固定当前位置",
            "togglePin:",
            ""
        )
        self.pin_item.setTarget_(self)
        self.menu.addItem_(self.pin_item)
        
        close_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "隐藏窗口",
            "hideWindow:",
            ""
        )
        close_item.setTarget_(self)
        self.menu.addItem_(close_item)
        self.window.contentView().setMenu_(self.menu)

    def togglePin_(self, sender):
        self.is_pinned = not self.is_pinned
        self.pin_item.setTitle_("跟随鼠标" if self.is_pinned else "固定当前位置")

    def hideWindow_(self, sender):
        self.window.orderOut_(None)

    @objc.python_method
    def show(self, text):
        self.label.setStringValue_(text)
        
        max_width = 500
        padding = 30
        cell = self.label.cell()
        rect = cell.cellSizeForBounds_(((0, 0), (max_width - padding, 1000)))
        
        new_width = max(240, min(max_width, rect.width + padding))
        new_height = max(60, min(600, rect.height + padding))
        
        self.label.setFrame_(((15, 15), (new_width - padding, new_height - padding)))
        
        if self.is_pinned:
            frame = self.window.frame()
            old_top_y = frame.origin.y + frame.size.height
            new_origin_y = old_top_y - new_height
            self.window.setFrame_display_(((frame.origin.x, new_origin_y), (new_width, new_height)), True)
        else:
            loc = Quartz.NSEvent.mouseLocation()
            self.window.setFrame_display_(((loc.x + 10, loc.y - new_height - 10), (new_width, new_height)), True)
        
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
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionListenOnly,
            mask,
            callback,
            None
        )

        if not self.event_tap:
            print("❌ 无法创建 EventTap（请开启输入监控权限）")
            return

        run_loop_source = Quartz.CFMachPortCreateRunLoopSource(None, self.event_tap, 0)
        Quartz.CFRunLoopAddSource(
            Quartz.CFRunLoopGetCurrent(),
            run_loop_source,
            Quartz.kCFRunLoopCommonModes
        )
        Quartz.CGEventTapEnable(self.event_tap, True)

    def on_mouse_up(self):
        time.sleep(0.05)
        text = self.get_selected_text()
        if not text or text == self.last_text:
            return

        self.last_text = text
        self.window.show("正在翻译...")

        try:
            translated = self.translator.translate(text)
            if translated:
                display = f"{text}\n\n───\n\n{translated}"
                self.window.show(display)
            else:
                self.window.show("翻译结果为空")
        except Exception as e:
            print(f"翻译异常: {e}")
            self.window.show(f"翻译出错: {str(e)[:50]}")

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
        except:
            pass

        return self.get_by_clipboard()

    def get_by_clipboard(self):
        now = time.time()
        if now - self.last_copy_time < self.copy_interval:
            return None
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
            types = [
                "public.utf8-plain-text",
                "org.nspasteboard.TransientType",
                "org.nspasteboard.ConcealedType",
                "org.nspasteboard.AutoGeneratedType"
            ]
            pb.declareTypes_owner_(types, None)
            pb.setString_forType_(old_text, "public.utf8-plain-text")

        if new_text:
            new_text = new_text.strip()
            if not new_text or new_text == self.last_text:
                return None
            return new_text
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

    print("🚀 已启动：鼠标松开即翻译 (右键窗口可固定位置)")
    app.run()


if __name__ == "__main__":
    main()
