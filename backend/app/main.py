#!/usr/bin/env python3

import os
import sys
import time
import signal

import Quartz
import objc

# 动态添加项目根目录到 sys.path
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
from frontend.window import FloatingWindow

# 常用语言映射 (名称 -> 代码)
LANGUAGES = {
    "自动检测": "auto",
    "中文简体": "zh-CN",
    "英语": "en",
    "日语": "ja",
    "韩语": "ko",
    "法语": "fr",
    "德语": "de",
    "俄语": "ru"
}

class AutoTranslator(NSObject):
    def init(self):
        self = objc.super(AutoTranslator, self).init()
        if self is None: return None

        self.src_lang = "auto"
        self.dest_lang = "zh-CN"
        self.last_text = ""
        
        self.translator = GoogleTranslator(source=self.src_lang, target=self.dest_lang)
        
        self.window = FloatingWindow.alloc().init()
        self.window.delegate = self
        self.window.set_languages(LANGUAGES, self.src_lang, self.dest_lang)

        self.last_copy_time = 0
        self.copy_interval = 0.4
        return self

    @objc.python_method
    def language_changed(self, src_name, dest_name):
        self.src_lang = LANGUAGES.get(src_name, "auto")
        self.dest_lang = LANGUAGES.get(dest_name, "zh-CN")
        print(f"语言切换: {src_name}({self.src_lang}) -> {dest_name}({self.dest_lang})")
        
        # 更新翻译器
        self.translator = GoogleTranslator(source=self.src_lang, target=self.dest_lang)
        
        # 如果当前有选中的文本，立即重新翻译
        if self.last_text:
            self.on_mouse_up(force=True)

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

    def on_mouse_up(self, force=False):
        time.sleep(0.05)
        text = self.get_selected_text()
        
        if not text:
            return
            
        if not force and text == self.last_text:
            return

        self.last_text = text
        self.window.show(text, None)

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

    print("🚀 翻译器已启动：左上角固定，支持语言切换")
    app.run()


if __name__ == "__main__":
    main()
