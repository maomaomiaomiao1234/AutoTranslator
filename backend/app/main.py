#!/usr/bin/env python3

import sys
import time
import signal
import subprocess

import Quartz
from Cocoa import NSObject, NSApplication, NSWorkspace
from AppKit import (
    NSWindow, NSTextField, NSBackingStoreBuffered,
    NSFloatingWindowLevel, NSColor, NSFont, NSPasteboard
)
from Foundation import NSTimer
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    kAXSelectedTextAttribute,
    kAXFocusedUIElementAttribute,
    AXIsProcessTrusted,
)

from deep_translator import GoogleTranslator


TARGET_LANG = "zh-CN"
CHECK_INTERVAL = 0.6


# ---------------- UI 窗口 ----------------
class FloatingWindow:
    def __init__(self):
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (320, 100)),
            0,  # 无边框
            NSBackingStoreBuffered,
            False
        )

        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0, 0.8))
        self.window.setHasShadow_(True)

        self.label = NSTextField.alloc().initWithFrame_(((10, 10), (300, 80)))
        self.label.setEditable_(False)
        self.label.setBordered_(False)
        self.label.setDrawsBackground_(False)
        self.label.setTextColor_(NSColor.whiteColor())
        self.label.setFont_(NSFont.systemFontOfSize_(13))
        self.label.setLineBreakMode_(0)

        self.window.contentView().addSubview_(self.label)

    def show(self, text):
        self.label.setStringValue_(text)

        # 获取鼠标位置
        loc = Quartz.NSEvent.mouseLocation()

        self.window.setFrameTopLeftPoint_((loc.x + 10, loc.y - 10))
        self.window.makeKeyAndOrderFront_(None)

    def hide(self):
        self.window.orderOut_(None)


# ---------------- 主逻辑 ----------------
class AutoTranslator(NSObject):
    def init(self):
        #self = NSObject.init()
        if self is None:
            return None

        self.last_text = ""
        self.translator = GoogleTranslator(source="auto", target=TARGET_LANG)
        self.window = FloatingWindow()
        self.active = True
        return self

    def start(self):
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            CHECK_INTERVAL,
            self,
            "tick:",
            None,
            True
        )

    def tick_(self, _):
        text = self.get_selected_text()

        if not text or text == self.last_text:
            return

        self.last_text = text

        try:
            translated = self.translator.translate(text)
            display = f"{text[:60]}\n——\n{translated[:100]}"
            self.window.show(display)
        except Exception as e:
            print("翻译失败:", e)

    # -------- 核心：选区获取 --------
    def get_selected_text(self):
        # AX 尝试
        try:
            front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
            if front_app:
                pid = front_app.processIdentifier()
                app_ref = AXUIElementCreateApplication(pid)

                focused, err = AXUIElementCopyAttributeValue(
                    app_ref,
                    kAXFocusedUIElementAttribute,
                    None
                )

                if err == 0 and focused:
                    selected, err = AXUIElementCopyAttributeValue(
                        focused,
                        kAXSelectedTextAttribute,
                        None
                    )

                    if err == 0 and selected and selected.strip():
                        return selected.strip()
        except:
            pass

        # fallback：Cmd+C
        return self.get_by_clipboard()

    def get_by_clipboard(self):
        pb = NSPasteboard.generalPasteboard()

        old = pb.stringForType_("public.utf8-plain-text")

        pb.clearContents()
        self.simulate_cmd_c()

        time.sleep(0.05)

        new = pb.stringForType_("public.utf8-plain-text")

        if old:
            pb.clearContents()
            pb.setString_forType_(old, "public.utf8-plain-text")

        if new and new != old:
            return new.strip()

        return None

    def simulate_cmd_c(self):
        keycode = 8

        event_down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)

        event_up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)

        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)


# ---------------- 入口 ----------------
def main():
    if not AXIsProcessTrusted():
        print("需要辅助功能权限")
        sys.exit(1)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)  # 无 Dock 图标

    signal.signal(signal.SIGINT, signal.SIG_DFL)

    t = AutoTranslator()
    t.start()

    print("🚀 悬浮翻译已启动")
    app.run()


if __name__ == "__main__":
    main()