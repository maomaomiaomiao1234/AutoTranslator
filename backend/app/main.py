#!/usr/bin/env python3

import os
import sys
import time
import signal

import Quartz
import objc

# 动态添加项目根目录到 sys.path，以便导入 frontend 模块
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(os.path.dirname(current_dir))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from Cocoa import NSObject, NSApplication, NSWorkspace
from AppKit import NSPasteboard
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    kAXSelectedTextAttribute,
    kAXFocusedUIElementAttribute,
    AXIsProcessTrusted,
)

from deep_translator import GoogleTranslator

# 导入前端窗口组件
from frontend.window import FloatingWindow

TARGET_LANG = "zh-CN"


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
        self.window.show(text, None) # 显示加载状态

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

    print("🚀 启动成功：模块化结构 (右键可固定)")
    app.run()


if __name__ == "__main__":
    main()
