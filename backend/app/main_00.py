##!/usr/bin/env python3
#"""
#Auto Translate Selected Text on macOS
#选中任意文本后，自动弹出翻译通知（无需按任何键）
#需要：辅助功能权限 + pip install pyobjc-framework-Cocoa deep-translator
#"""
#
#import time
#import sys
#import Quartz
#import signal
#from Cocoa import NSObject, NSApplication, NSWorkspace
#from Foundation import NSRunLoop, NSTimer, NSDefaultRunLoopMode
#from ApplicationServices import (
#    AXUIElementCreateApplication,
#    AXUIElementCopyAttributeValue,
#    kAXSelectedTextAttribute,
#    kAXFocusedUIElementAttribute,
#    kAXValueAttribute,
#    AXIsProcessTrusted,         
#)
#from deep_translator import GoogleTranslator
#
## ---------- 配置 ----------
#TARGET_LANG = 'zh-CN'                # 要翻译成的语言
#CHECK_INTERVAL = 0.5              # 检测间隔（秒）
#MIN_TEXT_LENGTH = 2               # 最短翻译字符数（过滤无意义选中）
#MAX_TEXT_LENGTH = 500             # 最长翻译字符数
## -------------------------
#
#class AutoTranslator(NSObject):
#    def init(self):
#        #self = super().init()
#        if self is None:
#            return None
#        self.last_text = None
#        self.translator = GoogleTranslator(source='auto', target=TARGET_LANG)
#        self.active = True
#        return self
#
#    def startMonitoring(self):
#        """启动定时器，每 CHECK_INTERVAL 秒检查选中文本"""
#        timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
#            CHECK_INTERVAL, self, 'checkSelection:', None, True
#        )
#        NSRunLoop.currentRunLoop().addTimer_forMode_(timer, NSDefaultRunLoopMode)
#
#
#    def checkSelection_(self, timer):
#        if not self.active:
#            return
#        text = self.get_selected_text()
#        print(f"[获取文本] {repr(text)}")
#        if text is None:
#            return
#        if not (MIN_TEXT_LENGTH <= len(text) <= MAX_TEXT_LENGTH):
#            print(f"[过滤] 长度={len(text)}，跳过")
#            return
#        if text == self.last_text:
#            print("[重复] 与上次相同，跳过")
#            return
#    
#        self.last_text = text
#        try:
#            translated = self.translator.translate(text)
#            print(f"[翻译] {translated[:40]}")
#        except Exception as e:
#            print(f"[翻译失败] {e}")
#            translated = f"翻译出错：{e}"
#        self.show_notification(text, translated)
#
##    def checkSelection_(self, timer):
##        if not self.active:
##            return
##        text = self.get_selected_text()
##        if text is None:
##            return
##        # 过滤：太长太短或与上次相同都跳过
##        if not (MIN_TEXT_LENGTH <= len(text) <= MAX_TEXT_LENGTH):
##            return
##        if text == self.last_text:
##            return
##
##        self.last_text = text
##        # 翻译并弹通知
##        try:
##            translated = self.translator.translate(text)
##        except Exception as e:
##            translated = f"翻译出错：{e}"
##        self.show_notification(text, translated)
#
#    def get_selected_text(self):
#        """通过辅助功能获取当前选中的文本"""
#        # 获取最前方的应用
#        front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
#        pid = front_app.processIdentifier()
#        ref = AXUIElementCreateApplication(pid)
#
#        # 获取焦点元素
#        focused = None
#        err = AXUIElementCopyAttributeValue(ref, kAXFocusedUIElementAttribute, None)
#        if err == 0:
#            focused, _ = err   # err 返回 (result, element) 结构
#        if focused is None:
#            return None
#
#        # 读取选中文本
#        selected, error = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, None)
#        if error == 0:
#            return selected
#        return None
#
#    def show_notification(self, original, translated):
#        """弹出 macOS 原生通知"""
#        # 使用 osascript 可以完全无第三方依赖
#        import subprocess
#        title = "翻译结果"
#        # 截取显示，防止通知过长
#        preview_original = original if len(original) <= 40 else original[:40] + "..."
#        preview_trans = translated if len(translated) <= 60 else translated[:60] + "..."
#        script = f'''
#        display notification "{preview_trans}" with title "{title}" subtitle "{preview_original}"
#        '''
#        subprocess.run(["osascript", "-e", script], capture_output=True)
#
#
#def main():
#    # 检查辅助功能权限（用户可手动去 系统设置-隐私与安全性-辅助功能 添加终端/当前App）
#    if not AXIsProcessTrusted():
#        print("⚠️ 需要辅助功能权限，请将当前终端/Python 添加到「系统设置 > 隐私与安全性 > 辅助功能」")
#        sys.exit(1)
#    signal.signal(signal.SIGINT, lambda sig, frame: NSApplication.sharedApplication().terminate_(None))
#    app = NSApplication.sharedApplication()
#    translator = AutoTranslator.alloc().init()
#    translator.startMonitoring()
#    translator.show_notification("自动翻译已启动", f"选中任意英文后自动翻译为{TARGET_LANG}")
#
#    app.run()  # 保持运行，接收定时器事件
#
#
#if __name__ == '__main__':
#    main()



#!/usr/bin/env python3
"""
Auto Translate Selected Text on macOS
修正版：修复了 PyObjC 接口调用和通知转义问题
"""

import sys
import signal
import subprocess
from Cocoa import NSObject, NSApplication, NSWorkspace
from Foundation import NSRunLoop, NSTimer, NSDefaultRunLoopMode
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    kAXSelectedTextAttribute,
    kAXFocusedUIElementAttribute,
    AXIsProcessTrusted,         
)
from deep_translator import GoogleTranslator

# ---------- 配置 ----------
TARGET_LANG = 'zh-CN'        # 目标语言
CHECK_INTERVAL = 0.8         # 检测间隔（建议略微调高减少 CPU 占用）
MIN_TEXT_LENGTH = 2          # 最短翻译长度
MAX_TEXT_LENGTH = 500        # 最长翻译长度
# -------------------------

class AutoTranslator(NSObject):
    def init(self):
        #self = super().init()
        if self is None: return None
        self.last_text = ""
        self.translator = GoogleTranslator(source='auto', target=TARGET_LANG)
        self.active = True
        return self

    def startMonitoring(self):
        # 创建定时器
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            CHECK_INTERVAL, self, 'checkSelection:', None, True
        )
        NSRunLoop.currentRunLoop().addTimer_forMode_(self.timer, NSDefaultRunLoopMode)

    def checkSelection_(self, timer):
        if not self.active:
            return
            
        #TODO:始终获取不到文本
        text = self.get_selected_text()

        #text = 'You\'re welcome to call us warmongers'
        print(f"获取文本: {repr(text)}")
        
        if not text or not isinstance(text, str):
            return
            
        text = text.strip()
        
        # 过滤条件
        if not (MIN_TEXT_LENGTH <= len(text) <= MAX_TEXT_LENGTH):
            return
        if text == self.last_text:
            return

        self.last_text = text
        
        try:
            print(f"正在翻译: {text[:20]}...")
            translated = self.translator.translate(text)
            self.show_notification(text, translated)
        except Exception as e:
            print(f"翻译出错: {e}")

    def get_selected_text(self):
        """通过辅助功能获取选中的文本"""
        # 1. 获取当前活动 App
        front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if not front_app:
            return None
            
        pid = front_app.processIdentifier()
        app_ref = AXUIElementCreateApplication(pid)

        # 2. 获取焦点元素
        # 返回值是 (error_code, value)
        focused_element,error = AXUIElementCopyAttributeValue(app_ref, kAXFocusedUIElementAttribute, None)
        if error != 0 or not focused_element:
            return None

        # 3. 获取选中内容
        error, selected_text = AXUIElementCopyAttributeValue(focused_element, kAXSelectedTextAttribute, None)
        if error == 0 and selected_text:
            return selected_text
            
        return None

    def show_notification(self, original, translated):
        """发送系统通知，增加转义处理"""
        title = "翻译结果"
        # 转义双引号防止 osascript 崩溃
        clean_original = original.replace('"', '\"').replace('\n', ' ')
        clean_trans = translated.replace('"', '\"').replace('\n', ' ')
        
        preview_original = (clean_original[:40] + "..") if len(clean_original) > 40 else clean_original
        preview_trans = (clean_trans[:60] + "..") if len(clean_trans) > 60 else clean_trans

        script = f'display notification "{preview_trans}" with title "{title}" subtitle "{preview_original}"'
        subprocess.run(["osascript", "-e", script])

def main():
    # 检查权限
    if not AXIsProcessTrusted():
        print("❌ 错误：需要辅助功能权限！")
        print("请在「系统设置 > 隐私与安全性 > 辅助功能」中勾选你运行程序的终端（如 iTerm 或 Terminal）。")
        # 尝试触发权限弹窗
        AXUIElementCreateApplication(0) 
        sys.exit(1)

    app = NSApplication.sharedApplication()
    
    # 处理 Ctrl+C
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    
    monitor = AutoTranslator.alloc().init()
    monitor.startMonitoring()
    
    print(f"🚀 监听中... (目标语言: {TARGET_LANG})")
    print("提示：在任意位置选中一段文字，程序将自动翻译并弹出通知。")
    
    app.run()

if __name__ == '__main__':
    main()