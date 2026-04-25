#!/usr/bin/env python3

import sys
import time
import signal

import Quartz
import objc

from Cocoa import NSObject, NSApplication, NSWorkspace
from AppKit import (
    NSWindow, NSTextField, NSBackingStoreBuffered,
    NSFloatingWindowLevel, NSColor, NSFont, NSPasteboard
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
class FloatingWindow:
    def __init__(self):
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

        # 文本容器
        self.label = NSTextField.alloc().initWithFrame_(((15, 15), (370, 170)))
        self.label.setEditable_(False)
        self.label.setBordered_(False)
        self.label.setDrawsBackground_(False)
        self.label.setTextColor_(NSColor.whiteColor())
        self.label.setFont_(NSFont.systemFontOfSize_(14))
        
        self.window.contentView().addSubview_(self.label)

    def show(self, text):
        self.label.setStringValue_(text)
        
        # 计算最适合文本的尺寸
        max_width = 500
        padding = 30
        
        # 获取文本渲染所需的大小
        cell = self.label.cell()
        rect = cell.cellSizeForBounds_(((0, 0), (max_width - padding, 1000)))
        
        new_width = max(240, min(max_width, rect.width + padding))
        new_height = max(60, min(600, rect.height + padding))
        
        # 更新组件尺寸
        self.label.setFrame_(((15, 15), (new_width - padding, new_height - padding)))
        
        # 定位窗口 (显示在鼠标右下方)
        loc = Quartz.NSEvent.mouseLocation()
        self.window.setFrame_display_(((loc.x + 10, loc.y - new_height - 10), (new_width, new_height)), True)
        self.window.makeKeyAndOrderFront_(None)

    def hide(self):
        self.window.orderOut_(None)


# ---------------- 主逻辑 ----------------
class AutoTranslator(NSObject):
    def init(self):
        self.last_text = ""
        self.translator = GoogleTranslator(source="auto", target=TARGET_LANG)
        self.window = FloatingWindow()

        # 防止频繁 Cmd+C
        self.last_copy_time = 0
        self.copy_interval = 0.4

        # 切窗口冷却
        self.last_app_pid = None
        self.last_switch_time = 0
        self.switch_cooldown = 0.5
        return self

    # ---------- 鼠标监听 ----------
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

    # ---------- 鼠标松开 ----------
    def on_mouse_up(self):
        time.sleep(0.05)  # 等待选区稳定

        text = self.get_selected_text()
        if not text or text == self.last_text:
            return

        self.last_text = text
        
        # 显示加载状态，告知用户程序已响应
        self.window.show("正在翻译...")

        try:
            translated = self.translator.translate(text)
            if translated:
                # 移除硬截断，改为完整显示原文和译文
                display = f"{text}\n\n───\n\n{translated}"
                self.window.show(display)
            else:
                self.window.show("翻译结果为空")
        except Exception as e:
            print(f"翻译异常: {e}")
            self.window.show(f"翻译出错: {str(e)[:50]}")

    # ---------- 获取选区 ----------
    def get_selected_text(self):
        front_app = NSWorkspace.sharedWorkspace().frontmostApplication()

        if not front_app:
            return None

        #print(f"前台应用: {front_app.localizedName()} (PID: {front_app.processIdentifier()})")

        pid = front_app.processIdentifier()

        # AX 尝试
        try:
            app_ref = AXUIElementCreateApplication(pid)

            focused, err = AXUIElementCopyAttributeValue(
                app_ref,
                kAXFocusedUIElementAttribute,
                None
            )

            #print(f"AX 获取焦点元素: {focused}, err={err}")

            if err == 0 and focused:
                selected, err = AXUIElementCopyAttributeValue(
                    focused,
                    kAXSelectedTextAttribute,
                    None
                )

                if err == 0 and selected and selected.strip():
                    return selected.strip()
        except Exception as e:
            import traceback
            print(f"get_selected_text 异常: {e}")
            traceback.print_exc()
            return None

        # fallback
        return self.get_by_clipboard()

    # ---------- 剪贴板 ----------
    def get_by_clipboard(self):
        now = time.time()
        if now - self.last_copy_time < self.copy_interval:
            return None
        self.last_copy_time = now

        pb = NSPasteboard.generalPasteboard()
        old_text = pb.stringForType_("public.utf8-plain-text")
        old_count = pb.changeCount()

        # 模拟复制
        self.simulate_cmd_c()

        # 等待剪贴板更新 (最多等待 0.2s)
        new_text = None
        for _ in range(20):
            time.sleep(0.01)
            if pb.changeCount() != old_count:
                new_text = pb.stringForType_("public.utf8-plain-text")
                break

        # 恢复原始剪贴板
        if old_text is not None:
            pb.clearContents()
            # 写入原始值，并标记为临时内容，大多数剪切板管理器会忽略带这些标记的写入
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
            # 如果内容为空，或者与上一次翻译的内容相同，则跳过
            if not new_text or new_text == self.last_text:
                return None
            return new_text

        return None

    # ---------- 模拟 Cmd+C ----------
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
        print("❌ 需要辅助功能权限")
        sys.exit(1)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)  # 无 Dock 图标

    signal.signal(signal.SIGINT, signal.SIG_DFL)

    #t = AutoTranslator()
    #t = AutoTranslator()配合__init__() VS init() 的区别：前者会调用__init__()，后者需要手动调用init()。由于我们重写了init()，所以需要使用后者并手动调用init()来正确初始化对象。
    t = AutoTranslator.alloc().init()
    t.start_mouse_monitor()

    print("🚀 已启动：鼠标松开即翻译")
    app.run()


if __name__ == "__main__":
    main()
