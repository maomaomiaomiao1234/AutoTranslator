#!/usr/bin/env python3

import logging
import os
import sys
import time
import signal
import threading

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)

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
from backend.LLM_set import LLMTranslator
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

        self.translator_backend = os.environ.get("TRANSLATOR_BACKEND", "google")
        self.translator = self._create_translator()

        self.window = FloatingWindow.alloc().init()
        self.window.delegate = self
        self.window.set_languages(LANGUAGES, self.src_lang, self.dest_lang)
        self.window.set_backend_label(self.translator_backend)

        self.last_copy_time = 0
        self.copy_interval = 0.4
        self._translate_version = 0
        return self

    @objc.python_method
    def _create_translator(self):
        if self.translator_backend == "llm":
            try:
                logging.info("使用大模型翻译 (LLM)")
                return LLMTranslator(source=self.src_lang, target=self.dest_lang)
            except ValueError:
                logging.warning("大模型翻译初始化失败，回退到谷歌翻译")
                self.translator_backend = "google"
                if hasattr(self, "window") and self.window:
                    self.window.set_backend_label("google")
        logging.info("使用谷歌翻译 (Google)")
        return GoogleTranslator(source=self.src_lang, target=self.dest_lang)

    @objc.python_method
    def toggle_translator(self):
        self.translator_backend = "llm" if self.translator_backend == "google" else "google"
        self.translator = self._create_translator()
        logging.info("翻译后端切换为: %s", self.translator_backend)

        if self.last_text:
            self.on_mouse_up(force=True)

    @objc.python_method
    def language_changed(self, src_name, dest_name):
        self.src_lang = LANGUAGES.get(src_name, "auto")
        self.dest_lang = LANGUAGES.get(dest_name, "zh-CN")
        logging.info("语言切换: %s(%s) -> %s(%s)", src_name, self.src_lang, dest_name, self.dest_lang)
        
        self.translator = self._create_translator()
        
        # 如果当前有选中的文本，立即重新翻译
        if self.last_text:
            self.on_mouse_up(force=True)

    @objc.python_method
    def swap_languages(self):
        if self.src_lang == "auto":
            logging.info("源语言为自动检测，跳过语言互换")
            return

        self.src_lang, self.dest_lang = self.dest_lang, self.src_lang
        self.window.set_languages(LANGUAGES, self.src_lang, self.dest_lang)
        self.translator = self._create_translator()
        logging.info("语言互换完成: %s -> %s", self.src_lang, self.dest_lang)

        if self.last_text:
            self.on_mouse_up(force=True)

    @objc.python_method
    def retranslate_current(self):
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
            logging.error("无法创建 EventTap")
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

        self._translate_version += 1
        version = self._translate_version
        threading.Thread(
            target=self._do_translate,
            args=(text, version),
            daemon=True
        ).start()

    def _do_translate(self, text, version):
        try:
            if hasattr(self.translator, 'translate_stream'):
                buffer = ""
                last_update = 0
                for token in self.translator.translate_stream(text):
                    buffer += token
                    now = time.time()
                    if now - last_update > 0.08:
                        last_update = now
                        if version == self._translate_version:
                            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                                "updateDestText:", buffer, False
                            )
                result = (text, buffer) if buffer else (text, "翻译结果为空")
            else:
                translated = self.translator.translate(text)
                result = (text, translated) if translated else (text, "翻译结果为空")
        except Exception as e:
            result = (text, f"错误: {str(e)[:50]}")

        if version == self._translate_version:
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "showTranslationResult:", result, False
            )

    def updateDestText_(self, text):
        self.window.update_dest_text(text)

    def showTranslationResult_(self, result):
        text, translated = result
        self.window.show(text, translated)

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
        except Exception:
            logging.debug("Accessibility API 获取选中文本失败，回退到剪贴板", exc_info=True)
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
        event_down = Quartz.CGEventCreateKeyboardEvent(None, 8, True)
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
        event_up = Quartz.CGEventCreateKeyboardEvent(None, 8, False)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)


def main():
    if not AXIsProcessTrusted():
        logging.error("需要辅助功能权限")
        sys.exit(1)

    backend = os.environ.get("TRANSLATOR_BACKEND", "google")
    if backend == "llm":
        api_key = os.environ.get("DEEPSEEK_API_KEY") or os.environ.get("LLM_API_KEY")
        if not api_key:
            logging.warning("未设置 API Key，回退到谷歌翻译。设置 DEEPSEEK_API_KEY 后可在窗口内切换。")
            os.environ["TRANSLATOR_BACKEND"] = "google"
            backend = "google"

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    t = AutoTranslator.alloc().init()
    t.start_mouse_monitor()

    backend_name = "大模型" if backend == "llm" else "谷歌翻译"
    logging.info("翻译器已启动（%s），支持语言切换", backend_name)
    app.run()


if __name__ == "__main__":
    main()
